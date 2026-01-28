import SwiftUI
import AVFoundation
import AppKit
import Combine

class AudioPlayerManager: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.5 {
        didSet {
            updateVolume()
        }
    }
    @Published var currentTrackName = "No Track Loaded"
    @Published var currentArtist = "Unknown Artist"
    @Published var currentAlbum = "Unknown Album"
    @Published var copyright = ""
    @Published var sampleRate = ""
    @Published var bitDepth = ""
    @Published var albumArtwork: NSImage?
    @Published var isTrackLoaded = false

    private var audioPlayer: AVAudioPlayer?
    private var flacDecoder: FLACDecoder?
    private var timer: Timer?
    private var playlist: [URL] = []
    private var currentTrackIndex: Int = 0
    private var isFLACTrack = false
    private var flacStartTime: Date?

    override init() {
        super.init()
    }

    private func updateVolume() {
        audioPlayer?.volume = Float(volume)
        flacDecoder?.setVolume(Float(volume))
    }

    private func extractMetadata(from url: URL) {
        let asset = AVAsset(url: url)

        // Extract metadata
        let metadata = asset.metadata

        var title: String?
        var artist: String?
        var album: String?
        var copyrightText: String?
        var artwork: NSImage?

        for item in metadata {
            guard let commonKey = item.commonKey else { continue }

            switch commonKey {
            case .commonKeyTitle:
                title = item.stringValue
            case .commonKeyArtist:
                artist = item.stringValue
            case .commonKeyAlbumName:
                album = item.stringValue
            case .commonKeyCopyrights:
                copyrightText = item.stringValue
            case .commonKeyArtwork:
                if let data = item.dataValue {
                    artwork = NSImage(data: data)
                }
            default:
                break
            }
        }

        // Extract technical audio format information
        var sampleRateText = ""
        var bitDepthText = ""

        if let tracks = asset.tracks(withMediaType: .audio).first {
            if let formatDescriptions = tracks.formatDescriptions as? [CMFormatDescription] {
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
        }

        // Update published properties
        currentTrackName = title ?? url.deletingPathExtension().lastPathComponent
        currentArtist = artist ?? "Unknown Artist"
        currentAlbum = album ?? "Unknown Album"
        copyright = copyrightText ?? ""
        sampleRate = sampleRateText
        bitDepth = bitDepthText
        albumArtwork = artwork
    }

    func selectAudioFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        // Include FLAC files along with other audio formats
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.allowsOtherFileTypes = true

        panel.begin { [weak self] response in
            if response == .OK {
                self?.playlist = panel.urls
                if !panel.urls.isEmpty {
                    self?.currentTrackIndex = 0
                    self?.loadTrack(at: 0)
                }
            }
        }
    }

    private func loadTrack(at index: Int) {
        guard index >= 0 && index < playlist.count else { return }

        let url = playlist[index]
        currentTrackIndex = index

        // Stop any currently playing track
        stopCurrentTrack()

        // Check if the file is FLAC
        let fileExtension = url.pathExtension.lowercased()
        isFLACTrack = (fileExtension == "flac")

        // Extract metadata first
        extractMetadata(from: url)

        do {
            if isFLACTrack {
                // Use FLAC decoder for FLAC files
                flacDecoder = FLACDecoder()
                _ = try flacDecoder?.loadFLACFile(url: url)
                try flacDecoder?.prepareForPlayback()
                flacDecoder?.setVolume(Float(volume))

                duration = flacDecoder?.duration ?? 0
                currentTime = 0
                isTrackLoaded = true
            } else {
                // Use AVAudioPlayer for other formats
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.delegate = self
                audioPlayer?.prepareToPlay()
                audioPlayer?.volume = Float(volume)

                duration = audioPlayer?.duration ?? 0
                currentTime = 0
                isTrackLoaded = true
            }

            startTimer()
        } catch {
            print("Error loading audio file: \(error.localizedDescription)")
            currentTrackName = "Error Loading Track"
            isTrackLoaded = false
        }
    }

    private func stopCurrentTrack() {
        audioPlayer?.stop()
        audioPlayer = nil
        flacDecoder?.stop()
        flacDecoder = nil
        stopTimer()
        isPlaying = false
        albumArtwork = nil
        copyright = ""
        sampleRate = ""
        bitDepth = ""
    }

    func togglePlayPause() {
        do {
            if isFLACTrack {
                guard let decoder = flacDecoder else { return }

                if isPlaying {
                    decoder.pause()
                    isPlaying = false
                    stopTimer()
                } else {
                    try decoder.play()
                    isPlaying = true
                    flacStartTime = Date()
                    startTimer()
                }
            } else {
                guard let player = audioPlayer else { return }

                if player.isPlaying {
                    player.pause()
                    isPlaying = false
                    stopTimer()
                } else {
                    player.play()
                    isPlaying = true
                    startTimer()
                }
            }
        } catch {
            print("Error toggling playback: \(error.localizedDescription)")
        }
    }

    func seek(to time: Double) {
        do {
            if isFLACTrack {
                try flacDecoder?.seek(to: time)
                currentTime = time
                flacStartTime = Date()
            } else {
                audioPlayer?.currentTime = time
            }
        } catch {
            print("Error seeking: \(error.localizedDescription)")
        }
    }

    func nextTrack() {
        guard !playlist.isEmpty else { return }
        let wasPlaying = isPlaying
        let nextIndex = (currentTrackIndex + 1) % playlist.count
        loadTrack(at: nextIndex)
        if wasPlaying {
            togglePlayPause()
        }
    }

    func previousTrack() {
        guard !playlist.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
        } else {
            let wasPlaying = isPlaying
            let prevIndex = (currentTrackIndex - 1 + playlist.count) % playlist.count
            loadTrack(at: prevIndex)
            if wasPlaying {
                togglePlayPause()
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            if self.isFLACTrack {
                // For FLAC, calculate time based on elapsed time since play started
                if self.isPlaying, let startTime = self.flacStartTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    self.currentTime = min(self.currentTime + elapsed, self.duration)
                    self.flacStartTime = Date()

                    // Check if playback has finished
                    if self.currentTime >= self.duration - 0.1 {
                        self.stopTimer()
                        self.nextTrack()
                    }
                }
            } else {
                // For regular audio, use AVAudioPlayer's currentTime
                if let player = self.audioPlayer {
                    self.currentTime = player.currentTime
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        stopTimer()
    }
}

extension AudioPlayerManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            nextTrack()
        } else {
            isPlaying = false
            stopTimer()
        }
    }
}
