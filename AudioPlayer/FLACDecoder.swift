import Foundation
import AVFoundation

class FLACDecoder {
    private var audioFile: AVAudioFile?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    init() {
        setupAudioEngine()
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let engine = audioEngine, let player = playerNode else { return }

        engine.attach(player)
    }

    func loadFLACFile(url: URL) throws -> AVAudioFile {
        // Try to load FLAC file using AVAudioFile
        // macOS 10.13+ has native FLAC support through Core Audio
        do {
            let file = try AVAudioFile(forReading: url)
            self.audioFile = file
            return file
        } catch {
            throw FLACError.unableToLoadFile(error.localizedDescription)
        }
    }

    func prepareForPlayback() throws {
        guard let file = audioFile,
              let engine = audioEngine,
              let player = playerNode else {
            throw FLACError.notInitialized
        }

        // Connect player to engine's main mixer
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)

        // Prepare the engine
        engine.prepare()
    }

    func play() throws {
        guard let engine = audioEngine,
              let player = playerNode,
              let file = audioFile else {
            throw FLACError.notInitialized
        }

        // Start the engine if not already running
        if !engine.isRunning {
            try engine.start()
        }

        // Schedule the file for playback
        player.scheduleFile(file, at: nil)
        player.play()
    }

    func pause() {
        playerNode?.pause()
    }

    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
    }

    func seek(to time: TimeInterval) throws {
        guard let file = audioFile,
              let player = playerNode else {
            throw FLACError.notInitialized
        }

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * sampleRate)

        // Stop current playback
        player.stop()

        // Calculate frames to play from the seek position
        let frameCount = AVAudioFrameCount(file.length - startFrame)

        guard startFrame >= 0 && startFrame < file.length else {
            throw FLACError.invalidSeekPosition
        }

        // Schedule playback from the new position
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)

        // Resume playback if it was playing
        player.play()
    }

    var duration: TimeInterval {
        guard let file = audioFile else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var isPlaying: Bool {
        return playerNode?.isPlaying ?? false
    }

    func setVolume(_ volume: Float) {
        audioEngine?.mainMixerNode.outputVolume = volume
    }

    deinit {
        stop()
    }
}

enum FLACError: Error, LocalizedError {
    case unableToLoadFile(String)
    case notInitialized
    case invalidSeekPosition
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .unableToLoadFile(let details):
            return "Unable to load FLAC file: \\(details)"
        case .notInitialized:
            return "FLAC decoder not properly initialized"
        case .invalidSeekPosition:
            return "Invalid seek position"
        case .decodingFailed:
            return "FLAC decoding failed"
        }
    }
}
