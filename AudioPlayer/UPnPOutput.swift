import Foundation
import Network
import Combine
import Darwin
import os.log

private let upnpLog = OSLog(subsystem: "com.audioplayer", category: "UPnP")

// MARK: - Data Models

struct UPnPDevice: Identifiable, Equatable {
    let id: String          // UDN
    let name: String        // friendlyName
    let location: URL       // device description URL
    let controlURL: URL     // AVTransport control URL
    let modelName: String

    static func == (lhs: UPnPDevice, rhs: UPnPDevice) -> Bool { lhs.id == rhs.id }
}

// MARK: - SSDP Discovery

final class UPnPDiscovery: @unchecked Sendable {

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 5
        session = URLSession(configuration: cfg)
    }

    /// Send M-SEARCH and collect responses for `timeout` seconds.
    /// Returns unique devices that advertise AVTransport.
    func discover(timeout: TimeInterval = 3.0) async -> [UPnPDevice] {
        let responses = await sendMSearch(timeout: timeout)
        var seen = Set<String>()
        var devices: [UPnPDevice] = []

        for location in responses {
            guard seen.insert(location.absoluteString).inserted else { continue }
            if let device = await fetchDeviceDescription(location: location) {
                devices.append(device)
            }
        }
        return devices
    }

    // MARK: - SSDP

    private func sendMSearch(timeout: TimeInterval) async -> [URL] {
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.audioplayer.ssdp")
            queue.async {
                var locations: [URL] = []

                // Create UDP socket
                let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard sock >= 0 else {
                    continuation.resume(returning: [])
                    return
                }
                defer { close(sock) }

                // Allow reuse
                var yes: Int32 = 1
                setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

                // Set receive timeout
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                // Bind to any local port
                var localAddr = sockaddr_in()
                localAddr.sin_family = sa_family_t(AF_INET)
                localAddr.sin_port = 0
                localAddr.sin_addr.s_addr = INADDR_ANY
                withUnsafeMutablePointer(to: &localAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }

                // Build M-SEARCH message
                let mx = Int(timeout)
                let msg = "M-SEARCH * HTTP/1.1\r\n" +
                          "HOST: 239.255.255.250:1900\r\n" +
                          "MAN: \"ssdp:discover\"\r\n" +
                          "MX: \(mx)\r\n" +
                          "ST: urn:schemas-upnp-org:service:AVTransport:1\r\n" +
                          "\r\n"
                let msgData = Array(msg.utf8)

                // Multicast destination
                var dest = sockaddr_in()
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = UInt16(1900).bigEndian
                dest.sin_addr.s_addr = inet_addr("239.255.255.250")

                // Send twice for reliability
                for _ in 0..<2 {
                    withUnsafeMutablePointer(to: &dest) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                            _ = sendto(sock, msgData, msgData.count, 0, destPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    usleep(100_000) // 100ms between sends
                }

                // Collect responses until timeout
                let deadline = Date().addingTimeInterval(timeout)
                var buf = [UInt8](repeating: 0, count: 4096)
                while Date() < deadline {
                    let n = recv(sock, &buf, buf.count, 0)
                    guard n > 0 else { break }
                    let response = String(bytes: buf.prefix(n), encoding: .utf8) ?? ""
                    if let url = self.extractLocation(from: response) {
                        locations.append(url)
                    }
                }
                continuation.resume(returning: locations)
            }
        }
    }

    private func extractLocation(from response: String) -> URL? {
        for line in response.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                return URL(string: value)
            }
        }
        return nil
    }

    // MARK: - Device Description

    private func fetchDeviceDescription(location: URL) async -> UPnPDevice? {
        guard let (data, _) = try? await session.data(from: location) else { return nil }
        guard let xml = String(data: data, encoding: .utf8) else { return nil }

        guard let udn          = xmlValue(xml, tag: "UDN"),
              let friendlyName = xmlValue(xml, tag: "friendlyName") else { return nil }

        let modelName = xmlValue(xml, tag: "modelName") ?? ""

        // Find AVTransport service controlURL
        guard let controlPath = avTransportControlURL(from: xml) else { return nil }

        // Resolve relative control URL against device description base URL
        let base = location.deletingLastPathComponent()
        let controlURL: URL
        if controlPath.hasPrefix("http") {
            controlURL = URL(string: controlPath) ?? base.appendingPathComponent(controlPath)
        } else {
            let stripped = controlPath.hasPrefix("/") ? String(controlPath.dropFirst()) : controlPath
            controlURL = base.appendingPathComponent(stripped)
        }

        return UPnPDevice(id: udn, name: friendlyName, location: location,
                          controlURL: controlURL, modelName: modelName)
    }

    private func avTransportControlURL(from xml: String) -> String? {
        // Find serviceType containing AVTransport, then the controlURL in the same serviceBlock
        let serviceBlocks = xml.components(separatedBy: "<service>").dropFirst()
        for block in serviceBlocks {
            let end = block.components(separatedBy: "</service>").first ?? block
            if end.contains("AVTransport") {
                return xmlValue(end, tag: "controlURL")
            }
        }
        return nil
    }

    private func xmlValue(_ xml: String, tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end   = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}

// MARK: - Local HTTP Audio Server

/// Minimal HTTP/1.1 server that streams a single audio file with Range support.
/// The Linn (and most UPnP renderers) sends a Range request to seek without
/// stopping playback, so Range is essential for gapless transport control.
final class LocalAudioServer: @unchecked Sendable {

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var currentFileURL: URL?
    private let queue = DispatchQueue(label: "com.audioplayer.httpserver")

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener?.port?.rawValue {
                self?.port = port
            }
        }
        self.listener = listener
        listener.start(queue: queue)

        // Wait for listener to be ready (max 2s)
        let deadline = Date().addingTimeInterval(2)
        while listener.state != .ready && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func serveFile(_ url: URL) {
        currentFileURL = url
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn)
    }

    private func receiveRequest(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self = self, let data = data, !data.isEmpty else {
                conn.cancel(); return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            self.serveResponse(for: request, on: conn)
        }
    }

    private func serveResponse(for request: String, on conn: NWConnection) {
        guard let fileURL = currentFileURL,
              let fileHandle = try? FileHandle(forReadingFrom: fileURL),
              let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else {
            send(conn: conn, status: "404 Not Found", headers: [:], body: Data())
            return
        }
        defer { try? fileHandle.close() }

        let mime = mimeType(for: fileURL)
        var rangeStart: Int = 0
        var rangeEnd: Int = fileSize - 1

        // Parse Range header
        if let rangeLine = request.components(separatedBy: "\r\n").first(where: {
            $0.lowercased().hasPrefix("range:")
        }) {
            let value = rangeLine.dropFirst("Range:".count).trimmingCharacters(in: .whitespaces)
            // e.g. "bytes=0-" or "bytes=1024-2047"
            if value.lowercased().hasPrefix("bytes=") {
                let spec = value.dropFirst("bytes=".count)
                let parts = spec.components(separatedBy: "-")
                if parts.count == 2 {
                    rangeStart = Int(parts[0]) ?? 0
                    rangeEnd   = Int(parts[1]) ?? (fileSize - 1)
                }
            }
        }

        let length = rangeEnd - rangeStart + 1
        try? fileHandle.seek(toOffset: UInt64(rangeStart))
        let body = fileHandle.readData(ofLength: length)

        let isPartial = rangeStart > 0 || rangeEnd < fileSize - 1
        let status = isPartial ? "206 Partial Content" : "200 OK"
        var headers: [String: String] = [
            "Content-Type":   mime,
            "Content-Length": "\(body.count)",
            "Accept-Ranges":  "bytes",
            "Connection":     "close",
        ]
        if isPartial {
            headers["Content-Range"] = "bytes \(rangeStart)-\(rangeEnd)/\(fileSize)"
        }

        send(conn: conn, status: status, headers: headers, body: body)
    }

    private func send(conn: NWConnection, status: String, headers: [String: String], body: Data) {
        var headerLines = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { headerLines += "\(k): \(v)\r\n" }
        headerLines += "\r\n"
        var response = headerLines.data(using: .utf8)!
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "flac": return "audio/flac"
        case "mp3":  return "audio/mpeg"
        case "m4a":  return "audio/mp4"
        case "aac":  return "audio/aac"
        case "wav":  return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "ogg":  return "audio/ogg"
        default:     return "application/octet-stream"
        }
    }
}

// MARK: - Local IP detection

func localIPAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }

    var ptr = ifaddr
    while let current = ptr {
        let iface = current.pointee
        if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
            let flags = Int32(iface.ifa_flags)
            guard flags & IFF_LOOPBACK == 0 else { ptr = iface.ifa_next; continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let addr = String(cString: hostname)
                // Prefer private ranges
                if addr.hasPrefix("192.168.") || addr.hasPrefix("10.") ||
                   addr.hasPrefix("172.16.")  || addr.hasPrefix("172.17.") {
                    return addr
                }
            }
        }
        ptr = iface.ifa_next
    }
    return nil
}

// MARK: - UPnP AVTransport SOAP

final class UPnPAVTransport: @unchecked Sendable {

    private let session: URLSession
    var controlURL: URL

    init(controlURL: URL) {
        self.controlURL = controlURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        session = URLSession(configuration: cfg)
    }

    // MARK: - Transport commands

    func setAVTransportURI(uri: String, metadata: String) async throws {
        let body = soapBody(action: "SetAVTransportURI", args: [
            ("InstanceID", "0"),
            ("CurrentURI", escapeXML(uri)),
            ("CurrentURIMetaData", escapeXML(metadata)),
        ])
        try await soapRequest(action: "SetAVTransportURI", body: body)
    }

    func play(speed: String = "1") async throws {
        let body = soapBody(action: "Play", args: [
            ("InstanceID", "0"),
            ("Speed", speed),
        ])
        try await soapRequest(action: "Play", body: body)
    }

    func pause() async throws {
        let body = soapBody(action: "Pause", args: [("InstanceID", "0")])
        try await soapRequest(action: "Pause", body: body)
    }

    func stop() async throws {
        let body = soapBody(action: "Stop", args: [("InstanceID", "0")])
        try await soapRequest(action: "Stop", body: body)
    }

    func seek(to seconds: TimeInterval) async throws {
        let timeStr = formatTime(seconds)
        let body = soapBody(action: "Seek", args: [
            ("InstanceID", "0"),
            ("Unit", "REL_TIME"),
            ("Target", timeStr),
        ])
        try await soapRequest(action: "Seek", body: body)
    }

    func getPositionInfo() async throws -> UPnPPositionInfo {
        let body = soapBody(action: "GetPositionInfo", args: [("InstanceID", "0")])
        let response = try await soapRequest(action: "GetPositionInfo", body: body)
        return parsePositionInfo(response)
    }

    func getTransportInfo() async throws -> String {
        let body = soapBody(action: "GetTransportInfo", args: [("InstanceID", "0")])
        let response = try await soapRequest(action: "GetTransportInfo", body: body)
        return xmlValue(response, tag: "CurrentTransportState") ?? "UNKNOWN"
    }

    // MARK: - SOAP

    @discardableResult
    private func soapRequest(action: String, body: String) async throws -> String {
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"",
                         forHTTPHeaderField: "SOAPAction")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UPnPError.soapFault(http.statusCode, body)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func soapBody(action: String, args: [(String, String)]) -> String {
        let argXML = args.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              \(argXML)
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """
    }

    // MARK: - DIDL-Lite metadata

    static func didlMetadata(title: String, artist: String, album: String,
                              uri: String, mime: String) -> String {
        let safeTitle  = escapeXML(title)
        let safeArtist = escapeXML(artist)
        let safeAlbum  = escapeXML(album)
        let safeURI    = escapeXML(uri)
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
                   xmlns:dc="http://purl.org/dc/elements/1.1/"
                   xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="0" parentID="-1" restricted="1">
            <dc:title>\(safeTitle)</dc:title>
            <dc:creator>\(safeArtist)</dc:creator>
            <upnp:album>\(safeAlbum)</upnp:album>
            <upnp:class>object.item.audioItem.musicTrack</upnp:class>
            <res protocolInfo="http-get:*:\(mime):*">\(safeURI)</res>
          </item>
        </DIDL-Lite>
        """
    }

    // MARK: - Helpers

    private func parsePositionInfo(_ xml: String) -> UPnPPositionInfo {
        let track    = xmlValue(xml, tag: "Track").flatMap(Int.init) ?? 0
        let duration = parseTime(xmlValue(xml, tag: "TrackDuration") ?? "0:00:00")
        let position = parseTime(xmlValue(xml, tag: "RelTime") ?? "0:00:00")
        return UPnPPositionInfo(track: track, duration: duration, position: position)
    }

    private func xmlValue(_ xml: String, tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end   = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    private func parseTime(_ time: String) -> TimeInterval {
        let parts = time.components(separatedBy: ":").compactMap(Double.init)
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }
}

private func escapeXML(_ s: String) -> String {
    s.replacingOccurrences(of: "&",  with: "&amp;")
     .replacingOccurrences(of: "<",  with: "&lt;")
     .replacingOccurrences(of: ">",  with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'",  with: "&apos;")
}

struct UPnPPositionInfo {
    let track: Int
    let duration: TimeInterval
    let position: TimeInterval
}

enum UPnPError: Error, LocalizedError {
    case noDeviceSelected
    case serverNotRunning
    case soapFault(Int, String)
    case transportError(String)

    var errorDescription: String? {
        switch self {
        case .noDeviceSelected:       return "No UPnP renderer selected"
        case .serverNotRunning:       return "Local audio server is not running"
        case .soapFault(let code, let body): return "SOAP fault \(code): \(body)"
        case .transportError(let msg):       return "Transport error: \(msg)"
        }
    }
}

// MARK: - UPnPOutputManager

final class UPnPOutputManager: ObservableObject {

    @Published var discoveredDevices: [UPnPDevice] = []
    @Published var selectedDevice: UPnPDevice? = nil
    @Published var isDiscovering: Bool = false
    @Published var isActive: Bool = false  // true when UPnP output is selected

    private let discovery   = UPnPDiscovery()
    private let httpServer  = LocalAudioServer()
    private var transport:    UPnPAVTransport?
    private var serverStarted = false

    // Current track info for metadata
    private var currentFileURL: URL?
    private var currentTitle:   String = ""
    private var currentArtist:  String = ""
    private var currentAlbum:   String = ""

    // Position polling
    private var positionTimer: Timer?
    @Published var rendererPosition: TimeInterval = 0
    @Published var rendererDuration: TimeInterval = 0

    // Completion callback (mirrors AudioEngine)
    var onPlaybackFinished: (() -> Void)?

    // MARK: - Discovery

    func discover() {
        guard !isDiscovering else { return }
        isDiscovering = true
        Task {
            let devices = await self.discovery.discover(timeout: 3.0)
            DispatchQueue.main.async { [weak self] in
                self?.discoveredDevices = devices
                self?.isDiscovering = false
            }
        }
    }

    func selectDevice(_ device: UPnPDevice?) {
        selectedDevice = device
        isActive = (device != nil)
        if let device = device {
            transport = UPnPAVTransport(controlURL: device.controlURL)
            startServerIfNeeded()
        } else {
            transport = nil
            stopPositionPolling()
        }
    }

    // MARK: - Server

    private func startServerIfNeeded() {
        guard !serverStarted else { return }
        do {
            try httpServer.start()
            serverStarted = true
        } catch {
            os_log("HTTP server start failed: %{public}@", log: upnpLog, type: .error, error.localizedDescription)
        }
    }

    // MARK: - Playback control

    func play(fileURL: URL, title: String, artist: String, album: String) async throws {
        guard let transport = transport else { throw UPnPError.noDeviceSelected }
        guard serverStarted else { throw UPnPError.serverNotRunning }

        currentFileURL = fileURL
        currentTitle   = title
        currentArtist  = artist
        currentAlbum   = album

        httpServer.serveFile(fileURL)

        guard let ip = localIPAddress() else {
            throw UPnPError.transportError("Cannot determine local IP address")
        }
        let trackURI = "http://\(ip):\(httpServer.port)/track\(fileURL.pathExtension.isEmpty ? "" : "." + fileURL.pathExtension)"
        let mime = mimeForExtension(fileURL.pathExtension)
        let metadata = UPnPAVTransport.didlMetadata(title: title, artist: artist,
                                                     album: album, uri: trackURI, mime: mime)

        try await transport.setAVTransportURI(uri: trackURI, metadata: metadata)
        try await transport.play()
        DispatchQueue.main.async { [weak self] in self?.startPositionPolling() }
    }

    func resume() async throws {
        guard let transport = transport else { throw UPnPError.noDeviceSelected }
        try await transport.play()
    }

    func pause() async throws {
        guard let transport = transport else { throw UPnPError.noDeviceSelected }
        try await transport.pause()
    }

    func stop() async throws {
        guard let transport = transport else { throw UPnPError.noDeviceSelected }
        try await transport.stop()
        DispatchQueue.main.async { [weak self] in self?.stopPositionPolling() }
    }

    func seek(to seconds: TimeInterval) async throws {
        guard let transport = transport else { throw UPnPError.noDeviceSelected }
        try await transport.seek(to: seconds)
    }

    // MARK: - Position polling

    private func startPositionPolling() {
        stopPositionPolling()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                await self?.pollPosition()
            }
        }
    }

    private func stopPositionPolling() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    @MainActor private func pollPosition() async {
        guard let transport = transport else { return }
        do {
            let info = try await transport.getPositionInfo()
            rendererPosition = info.position
            if info.duration > 0 { rendererDuration = info.duration }

            // Detect natural end-of-track
            if info.duration > 0 && info.position >= info.duration - 1.0 {
                // Double-check transport state
                let state = (try? await transport.getTransportInfo()) ?? ""
                if state == "STOPPED" || state == "NO_MEDIA_PRESENT" {
                    stopPositionPolling()
                    onPlaybackFinished?()
                }
            }
        } catch {
            // Transport errors during polling are non-fatal
        }
    }

    // MARK: - Helpers

    private func mimeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "flac": return "audio/flac"
        case "mp3":  return "audio/mpeg"
        case "m4a":  return "audio/mp4"
        case "aac":  return "audio/aac"
        case "wav":  return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        default:     return "application/octet-stream"
        }
    }
}
