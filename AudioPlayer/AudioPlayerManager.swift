import SwiftUI
import AVFoundation
import AppKit
import Combine

struct TrackMetadata {
    let title: String
    let artist: String
    let album: String
}

/// A single entry in the playlist.
struct PlaylistTrack {
    let url: URL
    init(url: URL) { self.url = url }
}

class AudioPlayerManager: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 1.0 {
        didSet {
            audioEngine.setVolume(Float(volume))
        }
    }
    @Published var currentTrackName = "No Track Loaded"
    @Published var currentArtist = "Unknown Artist"
    @Published var currentAlbum = "Unknown Album"
    @Published var copyright = ""
    @Published var sampleRate = ""
    @Published var bitDepth = ""
    // All artwork images for the current track: embedded first, then image
    // files found in the track's directory and its subdirectories.
    @Published var artworkImages: [NSImage] = []
    @Published var currentArtworkIndex: Int = 0
    @Published var isTrackLoaded = false
    @Published var isDownloadingCoverArt = false
    @Published var coverArtMessage: String = ""

    func cycleArtwork() {
        guard artworkImages.count > 1 else { return }
        currentArtworkIndex = (currentArtworkIndex + 1) % artworkImages.count
    }

    @Published var playlist: [PlaylistTrack] = []
    @Published var currentTrackIndex: Int = 0

    // UI state — stored here so views can access via @EnvironmentObject without
    // @Binding, avoiding the SwiftUI 4.6.3 assertion on macOS 13.7 that fires
    // when a view with @Binding properties has _ConditionalContent in its body.
    @Published var searchText: String = ""
    @Published var isWideLayout: Bool = true

    // EQ properties with UserDefaults persistence
    @Published var eqEnabled: Bool {
        didSet {
            UserDefaults.standard.set(eqEnabled, forKey: "eqEnabled")
            updateEQ()
        }
    }
    @Published var bassGain: Double {
        didSet {
            UserDefaults.standard.set(bassGain, forKey: "eqBassGain")
            updateEQ()
        }
    }
    @Published var trebleGain: Double {
        didSet {
            UserDefaults.standard.set(trebleGain, forKey: "eqTrebleGain")
            updateEQ()
        }
    }

    // Gap duration between tracks (0 to 3 seconds)
    @Published var gapDuration: Double {
        didSet {
            UserDefaults.standard.set(gapDuration, forKey: "gapDuration")
        }
    }

    private var audioEngine = AudioEngine()
    private var timer: Timer?
    private var trackGapTimer: Timer?
    private var playbackStartTime: Date?
    private var playbackStartPosition: Double = 0
    private var metadataCache: [URL: TrackMetadata] = [:]
    private var durationCache: [URL: TimeInterval] = [:]


    // Incremented on every loadTrack call so background loads from a
    // previous request are discarded when the user switches tracks quickly.
    private var loadGeneration = 0
    private let loadQueue = DispatchQueue(label: "com.audioplayer.load", qos: .userInitiated)

    override init() {
        // Load EQ settings from UserDefaults before super.init
        self.eqEnabled = UserDefaults.standard.bool(forKey: "eqEnabled")
        self.bassGain = UserDefaults.standard.double(forKey: "eqBassGain")
        self.trebleGain = UserDefaults.standard.double(forKey: "eqTrebleGain")

        // Load gap duration (default 2.0 seconds if not set)
        let savedGap = UserDefaults.standard.double(forKey: "gapDuration")
        self.gapDuration = savedGap == 0 && !UserDefaults.standard.dictionaryRepresentation().keys.contains("gapDuration") ? 2.0 : savedGap

        super.init()

        // Set up playback completion handler (only fires on natural end, not manual stop)
        audioEngine.onPlaybackFinished = { [weak self] in
            guard let self = self else { return }
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = self.duration

            let nextIndex = self.currentTrackIndex + 1
            guard nextIndex < self.playlist.count else { return }  // stop at end
            if self.gapDuration <= 0 {
                // No gap — start next track immediately
                self.loadTrack(at: nextIndex, autoPlay: true)
            } else {
                self.trackGapTimer = Timer.scheduledTimer(withTimeInterval: self.gapDuration, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.loadTrack(at: nextIndex, autoPlay: true)
                }
            }
        }

        // Apply initial EQ settings
        updateEQ()

        // When the audio output device changes (e.g. AirPlay device selected),
        // AVAudioEngine stops itself. Restart playback at the current position
        // so audio is routed to the newly selected device.
        audioEngine.onConfigurationChange = { [weak self] in
            guard let self = self, self.isPlaying else { return }
            let position = self.currentTime
            do {
                try self.audioEngine.prepareForPlayback()
                self.audioEngine.setVolume(Float(self.volume))
                self.updateEQ()
                try self.audioEngine.seek(to: position, forcePlay: true)
                self.playbackStartTime = Date()
                self.playbackStartPosition = position
            } catch {
                print("Audio route change: failed to resume — \(error.localizedDescription)")
                self.isPlaying = false
            }
        }
    }

    private func updateEQ() {
        audioEngine.setEQBypass(!eqEnabled)
        audioEngine.setEQ(bassGain: Float(bassGain), trebleGain: Float(trebleGain))
    }

    private func extractMetadata(from url: URL, generation: Int) {
        let asset = AVURLAsset(url: url)
        let fallbackName = url.deletingPathExtension().lastPathComponent

        Task {
            do {
                let metadata = try await asset.load(.metadata)

                let titleItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
                let artistItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist)
                let albumItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierAlbumName)
                let copyrightItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierCopyrights)
                let artworkItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)

                let title = try? await titleItems.first?.load(.stringValue)
                let artist = try? await artistItems.first?.load(.stringValue)
                let album = try? await albumItems.first?.load(.stringValue)
                let copyrightText = try? await copyrightItems.first?.load(.stringValue)
                let artworkData = try? await artworkItems.first?.load(.dataValue)

                var sampleRateText = ""
                var bitDepthText = ""

                if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
                   let audioTrack = audioTracks.first {
                    let formatDescriptions = try await audioTrack.load(.formatDescriptions)
                    for formatDescription in formatDescriptions {
                        if let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                            let rate = basicDescription.pointee.mSampleRate
                            sampleRateText = String(format: "%.1f kHz", rate / 1000.0)
                            let bitsPerChannel = basicDescription.pointee.mBitsPerChannel
                            if bitsPerChannel > 0 { bitDepthText = "\(bitsPerChannel)-bit" }
                        }
                    }
                }

                let finalSampleRate = sampleRateText
                let finalBitDepth = bitDepthText
                let dirFallback = Self.directoryFallback(for: url)
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.currentTrackName = (title != nil && !title!.isEmpty) ? title! : fallbackName
                    self.currentArtist = (artist != nil && !artist!.isEmpty) ? artist! : dirFallback.artist
                    self.currentAlbum = (album != nil && !album!.isEmpty) ? album! : dirFallback.album
                    self.copyright = copyrightText ?? ""
                    self.sampleRate = finalSampleRate
                    self.bitDepth = finalBitDepth
                    if let artworkData = artworkData, let image = NSImage(data: artworkData) {
                        // Embedded artwork goes first so it shows immediately.
                        // Directory images may be appended later by scanDirectoryArtworks.
                        self.artworkImages.insert(image, at: 0)
                        self.currentArtworkIndex = 0
                    }
                }
            } catch {
                print("Error loading metadata: \(error.localizedDescription)")
            }
        }
    }

    /// Scans the track's directory and one level of subdirectories for image
    /// files and appends them to artworkImages after any embedded artwork.
    private func scanDirectoryArtworks(for url: URL, generation: Int) {
        let directory = url.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, self.loadGeneration == generation else { return }
            let fm = FileManager.default
            var found: [NSImage] = []

            guard let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            let sorted = contents.sorted {
                let pa = Self.artworkPriority($0), pb = Self.artworkPriority($1)
                if pa != pb { return pa < pb }
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            for item in sorted {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    // One level into subdirectories
                    if let sub = try? fm.contentsOfDirectory(
                        at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                    ) {
                        for subItem in sub.sorted(by: {
                            let pa = Self.artworkPriority($0), pb = Self.artworkPriority($1)
                            if pa != pb { return pa < pb }
                            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                        }) {
                            if Self.imageExtensions.contains(subItem.pathExtension.lowercased()),
                               let img = NSImage(contentsOf: subItem) {
                                found.append(img)
                            }
                        }
                    }
                } else if Self.imageExtensions.contains(item.pathExtension.lowercased()),
                          let img = NSImage(contentsOf: item) {
                    found.append(img)
                }
            }

            guard !found.isEmpty, self.loadGeneration == generation else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.loadGeneration == generation else { return }
                self.artworkImages.append(contentsOf: found)
            }
        }
    }

    /// Returns 0 for exact "front"/"folder", 1 for names containing those words,
    /// 2 for everything else. Case-insensitive via lowercased name.
    private static func artworkPriority(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name == "front" || name == "folder" { return 0 }
        if name.contains("front") || name.contains("folder") { return 1 }
        return 2
    }

    /// Falls back to directory names when a file has no embedded artist/album tags.
    /// Assumes common layout: …/Artist/Album/track.flac
    private static func directoryFallback(for url: URL) -> (artist: String, album: String) {
        let parent = url.deletingLastPathComponent()
        return (artist: parent.deletingLastPathComponent().lastPathComponent,
                album: parent.lastPathComponent)
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "caf", "ogg", "wma"
    ]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "tiff", "tif", "bmp", "webp"
    ]

    func selectAudioFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // Do NOT include UTType.folder here — folder selection is handled by
        // canChooseDirectories = true. Mixing folder and file UTTypes in
        // allowedContentTypes silently prevents the panel from opening on macOS 26.
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.allowsOtherFileTypes = true   // lets M3U / FLAC / etc. through

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self = self else { return }

            var seen = Set(self.playlist.map { $0.url.standardizedFileURL })
            var newTracks: [PlaylistTrack] = []

            for url in panel.urls {
                let ext = url.pathExtension.lowercased()
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

                if isDir.boolValue {
                    for fileURL in self.audioFilesInDirectory(url) {
                        let key = fileURL.standardizedFileURL
                        guard !seen.contains(key) else { continue }
                        seen.insert(key)
                        newTracks.append(PlaylistTrack(url: fileURL))
                    }
                } else if ext == "m3u" || ext == "m3u8" {
                    for fileURL in self.parseM3U(at: url) {
                        let key = fileURL.standardizedFileURL
                        guard !seen.contains(key) else { continue }
                        seen.insert(key)
                        newTracks.append(PlaylistTrack(url: fileURL))
                    }
                } else if Self.audioExtensions.contains(ext) {
                    let key = url.standardizedFileURL
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    newTracks.append(PlaylistTrack(url: url))
                }
            }

            let sortedTracks = newTracks.sorted {
                $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }

            guard !sortedTracks.isEmpty else { return }

            let wasEmpty = self.playlist.isEmpty
            self.playlist.append(contentsOf: sortedTracks)

            for track in sortedTracks {
                let url = track.url
                guard self.durationCache[url] == nil else { continue }
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let file = try? AVAudioFile(forReading: url) else { return }
                    let d = Double(file.length) / file.processingFormat.sampleRate
                    DispatchQueue.main.async { self?.durationCache[url] = d }
                }
            }

            if wasEmpty {
                self.currentTrackIndex = 0
                self.loadTrack(at: 0)
            }
        }

        // Present as a sheet on the key window (preferred on macOS 14+/26).
        // Fall back to runModal() if there is no window yet.
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: - M3U parser

    private func parseM3U(at url: URL) -> [URL] {
        guard let raw = (try? String(contentsOf: url, encoding: .utf8))
                     ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return [] }
        let dir = url.deletingLastPathComponent()
        return raw.components(separatedBy: .newlines).compactMap { line -> URL? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
            let fileURL: URL
            if t.hasPrefix("file://") {
                fileURL = URL(string: t) ?? URL(fileURLWithPath: t)
            } else if t.hasPrefix("/") || t.hasPrefix("~") {
                fileURL = URL(fileURLWithPath: t)
            } else {
                fileURL = dir.appendingPathComponent(t)
            }
            return Self.audioExtensions.contains(fileURL.pathExtension.lowercased()) ? fileURL : nil
        }
    }

    /// Recursively find all audio files in a directory
    private func audioFilesInDirectory(_ directory: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let fileURL as URL in enumerator {
            if Self.audioExtensions.contains(fileURL.pathExtension.lowercased()) {
                results.append(fileURL)
            }
        }

        return results
    }

    private func loadTrack(at index: Int, autoPlay: Bool = false) {
        guard index >= 0 && index < playlist.count else { return }

        let track = playlist[index]
        let url = track.url
        currentTrackIndex = index

        loadGeneration += 1
        let generation = loadGeneration

        trackGapTimer?.invalidate()
        trackGapTimer = nil

        audioEngine.stopPlayer()
        stopTimer()
        isPlaying = false
        isTrackLoaded = false

        currentTrackName = url.deletingPathExtension().lastPathComponent
        currentArtist = "Unknown Artist"
        currentAlbum = "Unknown Album"
        copyright = ""
        sampleRate = ""
        bitDepth = ""
        artworkImages = []
        currentArtworkIndex = 0

        extractMetadata(from: url, generation: generation)
        scanDirectoryArtworks(for: url, generation: generation)

        loadQueue.async { [weak self] in
            guard let self = self, self.loadGeneration == generation else { return }

            do {
                var file: AVAudioFile
                var buffer: AVAudioPCMBuffer

                var preFile: AVAudioFile?
                var preBuf: AVAudioPCMBuffer?
                var preURL: URL?
                self.audioEngine.preloadQueue.sync {
                    preFile = self.audioEngine.preloadedFile
                    preBuf  = self.audioEngine.preloadedBuffer
                    preURL  = self.audioEngine.preloadedURL
                }

                if preURL == url, let pf = preFile, let pb = preBuf {
                    file   = pf
                    buffer = pb
                } else {
                    file   = try AVAudioFile(forReading: url)
                    buffer = try self.audioEngine.bufferFile(file)
                }

                guard self.loadGeneration == generation else { return }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.loadGeneration == generation else { return }
                    do {
                        self.audioEngine.setContent(file: file, buffer: buffer)
                        try self.audioEngine.prepareForPlayback()
                        self.audioEngine.setVolume(Float(self.volume))
                        self.updateEQ()

                        let d = self.audioEngine.duration
                        self.duration = d
                        self.durationCache[url] = d
                        self.currentTime = 0
                        self.playbackStartPosition = 0
                        self.isTrackLoaded = true

                        if autoPlay {
                            try self.audioEngine.play()
                            self.isPlaying = true
                            self.playbackStartTime = Date()
                        }

                        self.startTimer()
                        self.preloadNextTrack(after: index)
                    } catch {
                        print("Error preparing playback: \(error.localizedDescription)")
                        self.currentTrackName = "Error Loading Track"
                        self.isTrackLoaded = false
                        self.artworkImages = []
                    }
                }
            } catch {
                guard self.loadGeneration == generation else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.currentTrackName = "Error Loading Track"
                    self?.isTrackLoaded = false
                    self?.artworkImages = []
                }
            }
        }
    }

    private func preloadNextTrack(after index: Int) {
        guard playlist.count > 1 else { return }
        let nextIndex = (index + 1) % playlist.count
        audioEngine.preloadFile(url: playlist[nextIndex].url)
    }

    /// Always starts playback regardless of current play/pause state.
    func startTrack(at index: Int) {
        loadTrack(at: index, autoPlay: true)
    }

    // MARK: - Cover art download

    private struct CAAImage {
        let imageURL: String   // full-resolution or 1200px thumbnail
        let types: [String]    // e.g. ["Front"], ["Back"], ["Booklet"]
        let id: String
    }

    /// Searches MusicBrainz for the current release, then downloads every
    /// approved Front, Back, Booklet and Medium image from the Cover Art
    /// Archive into the album directory.
    func downloadCoverArt() {
        guard isTrackLoaded,
              currentTrackIndex < playlist.count else { return }
        let artist  = currentArtist
        let album   = currentAlbum
        let destDir = playlist[currentTrackIndex].url.deletingLastPathComponent()

        isDownloadingCoverArt = true
        coverArtMessage = "Searching MusicBrainz…"

        Task {
            // Swift 5.9: no await in defer, no var captured in @Sendable closures.
            // Use explicit finish helper and snapshot vars to let before closures.
            func finish(_ msg: String) async {
                await MainActor.run {
                    self.coverArtMessage = msg
                    self.isDownloadingCoverArt = false
                }
            }

            // 1. Find candidate release MBIDs (top-scoring results).
            let mbids = await searchMusicBrainzRelease(artist: artist, album: album)
            guard !mbids.isEmpty else {
                await finish("Release not found on MusicBrainz"); return
            }

            // 2. Fetch the image list from CAA, trying each MBID until we get one.
            var images: [CAAImage] = []
            for mbid in mbids {
                images = await fetchCAAImageList(mbid: mbid)
                if !images.isEmpty { break }
            }
            guard !images.isEmpty else {
                await finish("No cover art found in Cover Art Archive"); return
            }

            // Snapshot to let before use in @Sendable closure (Swift 5.9 requirement).
            let imageCount = images.count
            await MainActor.run { self.coverArtMessage = "Downloading \(imageCount) image(s)…" }

            // 3. Download and save each image.
            let typePriority: (String) -> Int = { t in
                switch t { case "Front": return 0; case "Back": return 1;
                            case "Booklet": return 2; case "Medium": return 3; default: return 4 }
            }
            let sorted = images.sorted {
                let pa = $0.types.map(typePriority).min() ?? 9
                let pb = $1.types.map(typePriority).min() ?? 9
                return pa != pb ? pa < pb : $0.id < $1.id
            }

            var bookletIndex = 0
            var collectedImages: [(NSImage, Int)] = []
            var skippedCount  = 0
            var failedCount   = 0

            for img in sorted {
                let primaryType = img.types.first(where: { typePriority($0) < 9 }) ?? img.types.first ?? "Other"
                let filename: String
                let priority: Int
                switch primaryType {
                case "Front":   filename = "front.jpg";  priority = 0
                case "Back":    filename = "back.jpg";   priority = 1
                case "Booklet":
                    bookletIndex += 1
                    filename = String(format: "booklet-%02d.jpg", bookletIndex); priority = 2
                case "Medium":  filename = "medium.jpg"; priority = 3
                default:        continue
                }

                let dest = destDir.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: dest.path) { skippedCount += 1; continue }

                guard let imgURL = URL(string: img.imageURL),
                      let data   = await downloadURL(imgURL) else { failedCount += 1; continue }

                // Write first; only add to display if the file landed on disk.
                do {
                    try data.write(to: dest, options: .atomic)
                    if let image = NSImage(data: data) {
                        collectedImages.append((image, priority))
                    }
                } catch {
                    failedCount += 1
                    print("Cover art write failed (\(filename)): \(error.localizedDescription)")
                }
            }

            let finalImages   = collectedImages
            let finalSkipped  = skippedCount
            let finalFailed   = failedCount
            let finalDestPath = destDir.path
            await MainActor.run {
                if !finalImages.isEmpty {
                    for (image, _) in finalImages.sorted(by: { $0.1 > $1.1 }) {
                        self.artworkImages.insert(image, at: 0)
                    }
                    self.currentArtworkIndex = 0
                    var msg = "Saved \(finalImages.count) image\(finalImages.count == 1 ? "" : "s")"
                    if finalSkipped > 0 { msg += ", \(finalSkipped) already existed" }
                    if finalFailed  > 0 { msg += ", \(finalFailed) failed" }
                    self.coverArtMessage = msg
                } else if finalSkipped > 0 && finalFailed == 0 {
                    self.coverArtMessage = "Already in folder: \(finalDestPath)"
                } else {
                    // All downloads failed — show the destination path to help diagnose.
                    self.coverArtMessage = "Download failed — saving to: \(finalDestPath)"
                }
                self.isDownloadingCoverArt = false
            }
        }
    }

    /// Strips parenthesised/bracketed tokens (year, bit depth, format, etc.)
    /// and leading "Artist - " prefixes that appear in directory-derived names.
    /// Examples:
    ///   "Lou Reed - Ecstasy (2000)(24bit)" → album "Ecstasy", stripped of artist prefix
    ///   "Paris 1919 [24bit FLAC]"          → "Paris 1919"
    private func cleanForMusicBrainz(album: String, artist: String) -> (artist: String, album: String) {
        func strip(_ s: String) -> String {
            var r = s
            // Remove anything inside ( … ) or [ … ], e.g. (2000), (24bit), [FLAC]
            for pattern in [#"\s*\([^)]*\)"#, #"\s*\[[^\]]*\]"#] {
                while let range = r.range(of: pattern, options: .regularExpression) {
                    r.removeSubrange(range)
                }
            }
            return r.trimmingCharacters(in: CharacterSet.whitespaces
                .union(CharacterSet(charactersIn: "-–—")))
        }

        let cleanArtist = strip(artist)

        // If album is "Artist - Title …", remove the artist prefix first.
        var albumWork = album
        let prefix = cleanArtist + " - "
        if albumWork.lowercased().hasPrefix(prefix.lowercased()) {
            albumWork = String(albumWork.dropFirst(prefix.count))
        }
        let cleanAlbum = strip(albumWork)

        return (cleanArtist, cleanAlbum)
    }

    /// Returns up to 5 release MBIDs from MusicBrainz, sorted best-score first.
    private func searchMusicBrainzRelease(artist: String, album: String) async -> [String] {
        let clean = cleanForMusicBrainz(album: album, artist: artist)
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
        comps.queryItems = [
            URLQueryItem(name: "query",
                         value: "artist:\"\(clean.artist)\" AND release:\"\(clean.album)\""),
            URLQueryItem(name: "fmt",   value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("AudioPlayer/1.0 (https://github.com/lar-ern/audio_player)",
                     forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = json["releases"] as? [[String: Any]] else { return [] }

        return releases
            .compactMap { r -> (String, Int)? in
                guard let id    = r["id"]    as? String,
                      let score = r["score"] as? Int,
                      score >= 70 else { return nil }
                return (id, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Fetches the CAA image list for a release MBID and returns approved
    /// Front, Back, Booklet and Medium entries with their best-quality URLs.
    private func fetchCAAImageList(mbid: String) async -> [CAAImage] {
        guard let url = URL(string: "https://coverartarchive.org/release/\(mbid)/") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("AudioPlayer/1.0 (https://github.com/lar-ern/audio_player)",
                     forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]] else { return [] }

        let wanted: Set<String> = ["Front", "Back", "Booklet", "Medium"]

        return images.compactMap { img -> CAAImage? in
            // Only approved images.
            if let approved = img["approved"] as? Bool, !approved { return nil }

            // types can arrive as [String] or [Any] depending on the JSON parser.
            let types: [String]
            if let t = img["types"] as? [String] {
                types = t
            } else if let t = img["types"] as? [Any] {
                types = t.compactMap { $0 as? String }
            } else {
                return nil
            }
            guard types.contains(where: { wanted.contains($0) }),
                  let fullURL = img["image"] as? String else { return nil }

            // Thumbnail URLs in the CAA JSON sometimes use http:// (blocked by ATS).
            // Build the 1200px URL by looking in thumbnails, but only accept https://.
            // Fall back to the full-resolution image URL which is always https://.
            var bestURL = fullURL
            if let thumbs = img["thumbnails"] as? [String: Any] {
                let t1200 = (thumbs["1200"] as? String) ?? (thumbs["large"] as? String)
                if let t = t1200, t.hasPrefix("https://") {
                    bestURL = t
                }
            }

            let id = (img["id"] as? Int).map(String.init)
                  ?? (img["id"] as? String)
                  ?? fullURL
            return CAAImage(imageURL: bestURL, types: types, id: id)
        }
    }

    /// Downloads raw data from a URL, following redirects.
    /// Upgrades http:// to https:// to satisfy App Transport Security.
    private func downloadURL(_ url: URL) async -> Data? {
        // Ensure HTTPS — CAA/IA sometimes serves http:// URLs which ATS blocks.
        var finalURL = url
        if url.scheme == "http",
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.scheme = "https"
            finalURL = comps.url ?? url
        }
        var req = URLRequest(url: finalURL, timeoutInterval: 30)
        req.setValue("AudioPlayer/1.0 (https://github.com/lar-ern/audio_player)",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        return data
    }

    func getTrackDuration(at index: Int) -> TimeInterval {
        return getTrackDuration(for: playlist[index].url)
    }

    func getTrackMetadata(for track: PlaylistTrack) -> TrackMetadata {
        return getTrackMetadata(for: track.url)
    }

    private func stopCurrentTrack() {
        trackGapTimer?.invalidate()
        trackGapTimer = nil
        audioEngine.stop()
        stopTimer()
        isPlaying = false
        artworkImages = []
        currentArtworkIndex = 0
        copyright = ""
        sampleRate = ""
        bitDepth = ""
    }

    func togglePlayPause() {
        do {
            if isPlaying {
                // Save current position before pausing
                if let startTime = playbackStartTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    playbackStartPosition = min(playbackStartPosition + elapsed, duration)
                }
                audioEngine.pause()
                isPlaying = false
                stopTimer()
            } else {
                // Resume from the paused position — don't reschedule the buffer from the start.
                try audioEngine.resume()
                isPlaying = true
                playbackStartTime = Date()
                startTimer()
            }
        } catch {
            print("Error toggling playback: \(error.localizedDescription)")
        }
    }

    func seek(to time: Double) {
        do {
            try audioEngine.seek(to: time)
            currentTime = time
            playbackStartPosition = time
            playbackStartTime = Date()
        } catch {
            print("Error seeking: \(error.localizedDescription)")
        }
    }

    func nextTrack() {
        guard !playlist.isEmpty else { return }
        let wasPlaying = isPlaying
        let nextIndex = (currentTrackIndex + 1) % playlist.count
        loadTrack(at: nextIndex, autoPlay: wasPlaying)
    }

    func previousTrack() {
        guard !playlist.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
        } else {
            let wasPlaying = isPlaying
            let prevIndex = (currentTrackIndex - 1 + playlist.count) % playlist.count
            loadTrack(at: prevIndex, autoPlay: wasPlaying)
        }
    }

    func selectTrack(at index: Int) {
        guard index >= 0 && index < playlist.count else { return }
        let wasPlaying = isPlaying
        loadTrack(at: index, autoPlay: wasPlaying)
    }

    func clearPlaylist() {
        stopCurrentTrack()
        playlist.removeAll()
        metadataCache.removeAll()
        durationCache.removeAll()
        artworkImages = []
        currentArtworkIndex = 0
        currentTrackIndex = 0
        currentTrackName = "No Track Loaded"
        currentArtist = "Unknown Artist"
        currentAlbum = "Unknown Album"
        isTrackLoaded = false
        duration = 0
        currentTime = 0
    }

    func getTrackDuration(for url: URL) -> TimeInterval {
        if let cached = durationCache[url] { return cached }
        // Not yet cached — read on a background thread and refresh the UI when done.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let file = try? AVAudioFile(forReading: url) else { return }
            let d = Double(file.length) / file.processingFormat.sampleRate
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.durationCache[url] = d
                self.objectWillChange.send()
            }
        }
        return 0
    }

    func getTrackMetadata(for url: URL) -> TrackMetadata {
        if let cached = metadataCache[url] {
            return cached
        }

        let dirFallback = Self.directoryFallback(for: url)
        let result = TrackMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            artist: dirFallback.artist,
            album: dirFallback.album
        )
        metadataCache[url] = result

        // Load async and update cache
        let asset = AVURLAsset(url: url)
        Task {
            guard let metadata = try? await asset.load(.metadata) else { return }

            let titleItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
            let artistItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist)
            let albumItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierAlbumName)

            let title = try? await titleItems.first?.load(.stringValue)
            let artist = try? await artistItems.first?.load(.stringValue)
            let album = try? await albumItems.first?.load(.stringValue)

            let loaded = TrackMetadata(
                title: (title != nil && !title!.isEmpty) ? title! : url.deletingPathExtension().lastPathComponent,
                artist: (artist != nil && !artist!.isEmpty) ? artist! : dirFallback.artist,
                album: (album != nil && !album!.isEmpty) ? album! : dirFallback.album
            )

            await MainActor.run {
                self.metadataCache[url] = loaded
                // Trigger UI refresh
                self.objectWillChange.send()
            }
        }

        return result
    }

    private func startTimer() {
        timer?.invalidate()
        playbackStartTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            if self.isPlaying, let startTime = self.playbackStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                self.currentTime = min(self.playbackStartPosition + elapsed, self.duration)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        stopTimer()
        trackGapTimer?.invalidate()
    }
}
