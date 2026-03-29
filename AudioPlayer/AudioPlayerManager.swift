import SwiftUI
import AVFoundation
import AppKit
import Combine

struct TrackMetadata {
    let title: String
    let artist: String
    let album: String
}

/// A single playable entry in the playlist.
/// Normal files have startTime = 0 and endTime = nil.
/// CUE-sheet tracks carry the time range within a shared audio file.
struct PlaylistTrack {
    let url: URL
    let startTime: TimeInterval    // 0 for whole-file tracks
    let endTime: TimeInterval?     // nil = play to end of file
    let knownDuration: TimeInterval? // pre-computed for non-last CUE tracks
    let cueTitle: String?
    let cueArtist: String?

    init(url: URL, startTime: TimeInterval = 0, endTime: TimeInterval? = nil,
         knownDuration: TimeInterval? = nil, cueTitle: String? = nil, cueArtist: String? = nil) {
        self.url = url
        self.startTime = startTime
        self.endTime = endTime
        self.knownDuration = knownDuration
        self.cueTitle = cueTitle
        self.cueArtist = cueArtist
    }

    var isCUETrack: Bool { startTime > 0 || endTime != nil }
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
    @Published var isWideLayout: Bool = false

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

    // Cache the fully-decoded buffer for CUE/single-file albums so consecutive
    // tracks from the same file don't re-read from disk.
    private var wholeFileCache: (url: URL, file: AVAudioFile, buffer: AVAudioPCMBuffer)?

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

            guard self.playlist.count > 1 || self.currentTrackIndex < self.playlist.count - 1 else { return }
            let nextIndex = (self.currentTrackIndex + 1) % self.playlist.count
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
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.currentTrackName = (title != nil && !title!.isEmpty) ? title! : fallbackName
                    self.currentArtist = (artist != nil && !artist!.isEmpty) ? artist! : "Unknown Artist"
                    self.currentAlbum = (album != nil && !album!.isEmpty) ? album! : "Unknown Album"
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
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio, .folder]
        panel.allowsOtherFileTypes = true

        panel.begin { [weak self] response in
            guard response == .OK, let self = self else { return }

            // Existing URLs in the playlist for de-duplication.
            var seen = Set(self.playlist.map { $0.url.standardizedFileURL })

            var newTracks: [PlaylistTrack] = []

            for url in panel.urls {
                let ext = url.pathExtension.lowercased()
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

                if isDir.boolValue {
                    // Directory: if it contains CUE sheets, expand them into tracks.
                    // Audio files already covered by a CUE sheet are skipped so the
                    // large FLAC isn't also added as a plain whole-file entry.
                    for track in self.tracksInDirectory(url) {
                        let key = track.url.standardizedFileURL
                        if track.isCUETrack {
                            newTracks.append(track)   // CUE tracks: always include
                        } else if !seen.contains(key) {
                            seen.insert(key)
                            newTracks.append(track)
                        }
                    }
                } else if ext == "cue" {
                    // CUE sheet: expand to individual tracks.
                    for track in self.parseCUESheet(at: url) {
                        let key = track.url.standardizedFileURL
                        // CUE tracks from the same file are distinct — don't dedupe by URL alone.
                        // But skip if an identical non-CUE entry for the same file exists.
                        if !track.isCUETrack, seen.contains(key) { continue }
                        if !track.isCUETrack { seen.insert(key) }
                        newTracks.append(track)
                    }
                } else if ext == "m3u" || ext == "m3u8" {
                    // M3U playlist: expand to audio file URLs.
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

            // Sort whole-file tracks by path; CUE tracks keep their sheet order.
            let sortedTracks = newTracks.sorted {
                // CUE tracks that share a file stay in parsed order relative to each other.
                if $0.isCUETrack && $1.isCUETrack && $0.url == $1.url {
                    return $0.startTime < $1.startTime
                }
                return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }

            guard !sortedTracks.isEmpty else { return }

            let wasEmpty = self.playlist.isEmpty
            self.playlist.append(contentsOf: sortedTracks)

            // Pre-warm duration cache for whole-file tracks.
            for track in sortedTracks where !track.isCUETrack {
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
    }

    // MARK: - CUE sheet parser

    private func parseCUESheet(at cueURL: URL) -> [PlaylistTrack] {
        guard let raw = (try? String(contentsOf: cueURL, encoding: .utf8))
                     ?? (try? String(contentsOf: cueURL, encoding: .isoLatin1)) else { return [] }

        let dir = cueURL.deletingLastPathComponent()
        var audioFileURL: URL?
        var globalArtist: String?

        struct RawTrack {
            var title: String?
            var artist: String?
            var startTime: TimeInterval = 0
        }
        var tracks: [RawTrack] = []
        var current = RawTrack()
        var inTrack = false

        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let up = t.uppercased()

            if up.hasPrefix("FILE ") {
                let parts = t.components(separatedBy: "\"")
                if parts.count >= 2 {
                    audioFileURL = dir.appendingPathComponent(parts[1])
                }
            } else if up.hasPrefix("TRACK ") && up.contains("AUDIO") {
                if inTrack { tracks.append(current) }
                current = RawTrack()
                inTrack = true
            } else if up.hasPrefix("TITLE ") {
                let v = t.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
                if inTrack { current.title = v } // else ignore disc title
            } else if up.hasPrefix("PERFORMER ") {
                let v = t.dropFirst(10).trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
                if inTrack { current.artist = v } else { globalArtist = v }
            } else if up.hasPrefix("INDEX 01 ") {
                current.startTime = parseCUETimestamp(String(t.dropFirst(9)))
            }
        }
        if inTrack { tracks.append(current) }

        guard let audioURL = audioFileURL, !tracks.isEmpty else { return [] }

        return tracks.enumerated().map { i, raw in
            let endTime: TimeInterval? = i + 1 < tracks.count ? tracks[i + 1].startTime : nil
            return PlaylistTrack(
                url: audioURL,
                startTime: raw.startTime,
                endTime: endTime,
                knownDuration: endTime.map { $0 - raw.startTime },
                cueTitle: raw.title,
                cueArtist: raw.artist ?? globalArtist
            )
        }
    }

    /// Parse a CUE timestamp of the form MM:SS:FF (75 frames/sec).
    private func parseCUETimestamp(_ s: String) -> TimeInterval {
        let parts = s.components(separatedBy: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return 0 }
        return TimeInterval(parts[0] * 60 + parts[1]) + TimeInterval(parts[2]) / 75.0
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

    // MARK: - Directory scanner

    /// Returns tracks for a directory, preferring CUE-sheet expansion over raw audio files.
    /// Audio files referenced by a CUE sheet are not added as plain whole-file entries.
    private func tracksInDirectory(_ directory: URL) -> [PlaylistTrack] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Find CUE sheets at the top level of the directory.
        let cueFiles = contents.filter { $0.pathExtension.lowercased() == "cue" }

        var cueTracks: [PlaylistTrack] = []
        var coveredAudioURLs = Set<URL>()   // audio files claimed by a CUE sheet

        for cue in cueFiles {
            let parsed = parseCUESheet(at: cue)
            cueTracks.append(contentsOf: parsed)
            if let first = parsed.first { coveredAudioURLs.insert(first.url.standardizedFileURL) }
        }

        // Collect audio files not already covered by a CUE sheet, recursing into subdirs.
        let plainTracks = audioFilesInDirectory(directory)
            .filter { !coveredAudioURLs.contains($0.standardizedFileURL) }
            .map { PlaylistTrack(url: $0) }

        // CUE tracks first (in sheet order), then remaining plain files sorted by path.
        return cueTracks + plainTracks
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

        // Immediate UI update — CUE titles override file-based metadata.
        currentTrackName = track.cueTitle ?? url.deletingPathExtension().lastPathComponent
        currentArtist = track.cueArtist ?? "Unknown Artist"
        currentAlbum = "Unknown Album"
        copyright = ""
        sampleRate = ""
        bitDepth = ""
        artworkImages = []
        currentArtworkIndex = 0

        // Only read file-level metadata when not supplied by the CUE sheet.
        if !track.isCUETrack {
            extractMetadata(from: url, generation: generation)
        }
        scanDirectoryArtworks(for: url, generation: generation)

        loadQueue.async { [weak self] in
            guard let self = self, self.loadGeneration == generation else { return }

            do {
                var file: AVAudioFile
                var buffer: AVAudioPCMBuffer

                if track.isCUETrack {
                    // Reuse the whole-file cache when consecutive CUE tracks share
                    // the same audio file, avoiding a re-read from disk.
                    if self.wholeFileCache?.url != url {
                        let fullFile = try AVAudioFile(forReading: url)
                        let fullBuf  = try self.audioEngine.bufferFile(fullFile)
                        self.wholeFileCache = (url, fullFile, fullBuf)
                    }
                    let cache = self.wholeFileCache!
                    file = cache.file
                    guard let trackBuf = self.extractTrackBuffer(
                            from: cache.buffer,
                            format: cache.file.processingFormat,
                            startTime: track.startTime,
                            endTime: track.endTime) else {
                        throw AudioEngineError.decodingFailed
                    }
                    buffer = trackBuf
                } else {
                    // Normal track: prefer preloaded buffer, otherwise read fresh.
                    self.wholeFileCache = nil
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
                        // Only cache duration by URL for whole-file tracks.
                        if !track.isCUETrack { self.durationCache[url] = d }
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

    /// Slice a sub-buffer for one CUE track from the whole-file buffer.
    private func extractTrackBuffer(from fullBuffer: AVAudioPCMBuffer,
                                     format: AVAudioFormat,
                                     startTime: TimeInterval,
                                     endTime: TimeInterval?) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let startFrame = Int(startTime * rate)
        let totalFrames = Int(fullBuffer.frameLength)
        let endFrame = endTime.map { min(Int($0 * rate), totalFrames) } ?? totalFrames
        let frameCount = endFrame - startFrame
        guard frameCount > 0, startFrame < totalFrames else { return nil }

        guard let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        for ch in 0..<Int(format.channelCount) {
            if let src = fullBuffer.floatChannelData?[ch],
               let dst = out.floatChannelData?[ch] {
                dst.update(from: src.advanced(by: startFrame), count: frameCount)
            }
        }
        out.frameLength = AVAudioFrameCount(frameCount)
        return out
    }

    private func preloadNextTrack(after index: Int) {
        guard playlist.count > 1 else { return }
        let nextIndex = (index + 1) % playlist.count
        let next = playlist[nextIndex]
        // CUE tracks from the same file will use wholeFileCache — no disk read needed.
        guard !next.isCUETrack || next.url != playlist[index].url else { return }
        audioEngine.preloadFile(url: next.url)
    }

    /// Always starts playback regardless of current play/pause state.
    func startTrack(at index: Int) {
        loadTrack(at: index, autoPlay: true)
    }

    /// Duration for a playlist entry, using the CUE-derived value when available.
    func getTrackDuration(at index: Int) -> TimeInterval {
        let track = playlist[index]
        if let d = track.knownDuration { return d }
        // For the last CUE track (endTime == nil) or normal tracks, use file-level cache.
        let fileDuration = getTrackDuration(for: track.url)
        if track.isCUETrack && fileDuration > 0 { return fileDuration - track.startTime }
        return fileDuration
    }

    /// Metadata for a playlist entry, with CUE title/artist taking priority.
    func getTrackMetadata(for track: PlaylistTrack) -> TrackMetadata {
        if let title = track.cueTitle {
            // For CUE tracks, album comes from the file-level metadata cache if available.
            let album = metadataCache[track.url]?.album ?? ""
            return TrackMetadata(title: title, artist: track.cueArtist ?? "", album: album)
        }
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
                try audioEngine.play()
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
        wholeFileCache = nil
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

        let result = TrackMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            artist: "Unknown Artist",
            album: "Unknown Album"
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
                artist: (artist != nil && !artist!.isEmpty) ? artist! : "Unknown Artist",
                album: (album != nil && !album!.isEmpty) ? album! : "Unknown Album"
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
