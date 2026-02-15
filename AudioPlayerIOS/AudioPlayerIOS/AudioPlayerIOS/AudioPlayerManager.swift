import SwiftUI
import AVFoundation
import UIKit
import Combine

struct TrackMetadata {
    let title: String
    let artist: String
    let album: String
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
    @Published var albumArtwork: UIImage?
    @Published var isTrackLoaded = false

    @Published var playlist: [URL] = []
    @Published var currentTrackIndex: Int = 0

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

    override init() {
        // Load EQ settings from UserDefaults before super.init
        self.eqEnabled = UserDefaults.standard.bool(forKey: "eqEnabled")
        self.bassGain = UserDefaults.standard.double(forKey: "eqBassGain")
        self.trebleGain = UserDefaults.standard.double(forKey: "eqTrebleGain")

        // Load gap duration (default 2.0 seconds if not set)
        let savedGap = UserDefaults.standard.double(forKey: "gapDuration")
        self.gapDuration = savedGap == 0 && !UserDefaults.standard.dictionaryRepresentation().keys.contains("gapDuration") ? 2.0 : savedGap

        super.init()

        configureAudioSession()

        // Set up playback completion handler (only fires on natural end, not manual stop)
        audioEngine.onPlaybackFinished = { [weak self] in
            guard let self = self else { return }
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = self.duration

            // Gap before next track (next track is already pre-buffered)
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
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    private func updateEQ() {
        audioEngine.setEQBypass(!eqEnabled)
        audioEngine.setEQ(bassGain: Float(bassGain), trebleGain: Float(trebleGain))
    }

    private func extractMetadata(from url: URL) {
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

                // Extract technical audio format information
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
                            if bitsPerChannel > 0 {
                                bitDepthText = "\(bitsPerChannel)-bit"
                            }
                        }
                    }
                }

                await MainActor.run {
                    self.currentTrackName = (title != nil && !title!.isEmpty) ? title! : fallbackName
                    self.currentArtist = (artist != nil && !artist!.isEmpty) ? artist! : "Unknown Artist"
                    self.currentAlbum = (album != nil && !album!.isEmpty) ? album! : "Unknown Album"
                    self.copyright = copyrightText ?? ""
                    self.sampleRate = sampleRateText
                    self.bitDepth = bitDepthText
                    if let artworkData = artworkData {
                        self.albumArtwork = UIImage(data: artworkData)
                    } else {
                        self.albumArtwork = nil
                    }
                }
            } catch {
                print("Error loading metadata: \(error.localizedDescription)")
            }
        }
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "caf", "ogg", "wma"
    ]

    func addFiles(_ urls: [URL]) {
        var audioURLs: [URL] = []

        for url in urls {
            // Start accessing security-scoped resource for iOS file access
            guard url.startAccessingSecurityScopedResource() else { continue }

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                audioURLs.append(contentsOf: audioFilesInDirectory(url))
            } else if Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                audioURLs.append(url)
            }
        }

        // Sort by path for natural album/track ordering
        audioURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        guard !audioURLs.isEmpty else { return }

        let wasEmpty = playlist.isEmpty
        playlist.append(contentsOf: audioURLs)

        if wasEmpty {
            currentTrackIndex = 0
            loadTrack(at: 0)
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

        let url = playlist[index]
        currentTrackIndex = index

        // Cancel any pending gap timer
        trackGapTimer?.invalidate()
        trackGapTimer = nil

        // Soft-stop current playback (keep engine running for smooth transition)
        audioEngine.stopPlayer()
        stopTimer()
        isPlaying = false

        // Set fallback display name immediately (keep previous artwork until new metadata loads)
        currentTrackName = url.deletingPathExtension().lastPathComponent
        currentArtist = "Unknown Artist"
        currentAlbum = "Unknown Album"
        copyright = ""
        sampleRate = ""
        bitDepth = ""
        // Note: albumArtwork is NOT cleared here — extractMetadata will update it
        // This prevents the UI from flashing to the placeholder between tracks

        extractMetadata(from: url)

        do {
            _ = try audioEngine.loadFile(url: url)
            try audioEngine.prepareForPlayback()
            audioEngine.setVolume(Float(volume))
            updateEQ()

            duration = audioEngine.duration
            currentTime = 0
            playbackStartPosition = 0
            isTrackLoaded = true

            if autoPlay {
                try audioEngine.play()
                isPlaying = true
                playbackStartTime = Date()
            }

            startTimer()

            // Preload the next track into memory
            preloadNextTrack(after: index)
        } catch {
            print("Error loading audio file: \(error.localizedDescription)")
            currentTrackName = "Error Loading Track"
            isTrackLoaded = false
            albumArtwork = nil
        }
    }

    private func preloadNextTrack(after index: Int) {
        guard playlist.count > 1 else { return }
        let nextIndex = (index + 1) % playlist.count
        let nextURL = playlist[nextIndex]
        audioEngine.preloadFile(url: nextURL)
    }

    private func stopCurrentTrack() {
        trackGapTimer?.invalidate()
        trackGapTimer = nil
        audioEngine.stop()
        stopTimer()
        isPlaying = false
        albumArtwork = nil
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
        // Stop accessing security-scoped resources
        for url in playlist {
            url.stopAccessingSecurityScopedResource()
        }

        stopCurrentTrack()
        playlist.removeAll()
        metadataCache.removeAll()
        currentTrackIndex = 0
        currentTrackName = "No Track Loaded"
        currentArtist = "Unknown Artist"
        currentAlbum = "Unknown Album"
        isTrackLoaded = false
        duration = 0
        currentTime = 0
    }

    func getTrackDuration(for url: URL) -> TimeInterval {
        // Use AVAudioFile for synchronous duration — no deprecated APIs
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
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
        // Clean up security-scoped resources
        for url in playlist {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
