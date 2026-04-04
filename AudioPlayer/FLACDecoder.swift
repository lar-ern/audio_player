import Foundation
import AVFoundation

class AudioEngine {
    private var audioFile: AVAudioFile?
    private var audioBuffer: AVAudioPCMBuffer?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eqNode: AVAudioUnitEQ?
    private var currentFramePosition: AVAudioFramePosition = 0
    private var connectedFormat: AVAudioFormat?

    // Generation counter to distinguish stale completion callbacks
    private var playGeneration: Int = 0
    // True when player was paused (as opposed to stopped); resume() just calls player.play()
    private var isPaused: Bool = false

    // Pre-buffered next track (protected by serial queue)
    var preloadedFile: AVAudioFile?
    var preloadedBuffer: AVAudioPCMBuffer?
    var preloadedURL: URL?
    let preloadQueue = DispatchQueue(label: "com.audioplayer.preload")

    var onPlaybackFinished: (() -> Void)?

    // Called on the main thread when the audio output device changes (e.g. AirPlay
    // selected). AVAudioEngine stops itself; the manager must restart playback.
    var onConfigurationChange: (() -> Void)?

    init() {
        setupEngine()
    }

    /// Configures EQ band parameters. Shared by setupEngine and rebuildEngineAfterConfigChange.
    private func configureEQNode(_ eq: AVAudioUnitEQ,
                                  bassGain: Float = 0,
                                  trebleGain: Float = 0,
                                  bypass: Bool = true) {
        let bassBand = eq.bands[0]
        bassBand.filterType = .parametric
        bassBand.frequency  = 100
        bassBand.bandwidth  = 1.0
        bassBand.gain       = bassGain
        bassBand.bypass     = false

        let trebleBand = eq.bands[1]
        trebleBand.filterType = .parametric
        trebleBand.frequency  = 10000
        trebleBand.bandwidth  = 1.0
        trebleBand.gain       = trebleGain
        trebleBand.bypass     = false

        eq.bypass = bypass
    }

    private func setupEngine() {
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        eqNode = AVAudioUnitEQ(numberOfBands: 2)

        guard let engine = engine,
              let player = playerNode,
              let eq = eqNode else { return }

        configureEQNode(eq)

        // Attach nodes
        engine.attach(player)
        engine.attach(eq)

        // AVAudioEngine natively follows the system default output device.
        // When the default changes (AirPlay, Bluetooth, etc.) the engine stops
        // itself and posts this notification. We restart playback on the new device.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        // On macOS 26+, after a hardware configuration change the engine's
        // internal graph is reset. Attempting to connect nodes on that engine
        // throws inside AVAudioEngineGraph::UpdateGraphAfterReconfig (an
        // NSException that Swift cannot catch). Rebuild the engine and nodes
        // on the main thread before calling onConfigurationChange, so that
        // the subsequent prepareForPlayback() starts from a clean graph.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rebuildEngineAfterConfigChange()
            self.onConfigurationChange?()
        }
    }

    /// Tears down the current AVAudioEngine and creates a fresh one with the
    /// same EQ settings. Called after a hardware configuration change.
    private func rebuildEngineAfterConfigChange() {
        // Capture current EQ state before we replace the nodes.
        let bypass     = eqNode?.bypass           ?? true
        let bassGain   = eqNode?.bands[0].gain    ?? 0
        let trebleGain = eqNode?.bands[1].gain    ?? 0

        // Remove observer from the old engine and stop it.
        if let old = engine {
            NotificationCenter.default.removeObserver(
                self, name: .AVAudioEngineConfigurationChange, object: old)
            old.stop()
        }

        // Fresh engine + fresh nodes.
        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        let newEQ     = AVAudioUnitEQ(numberOfBands: 2)

        configureEQNode(newEQ, bassGain: bassGain, trebleGain: trebleGain, bypass: bypass)

        newEngine.attach(newPlayer)
        newEngine.attach(newEQ)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: newEngine)

        engine        = newEngine
        playerNode    = newPlayer
        eqNode        = newEQ
        connectedFormat = nil
    }

    func bufferFile(_ file: AVAudioFile) throws -> AVAudioPCMBuffer {
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioEngineError.decodingFailed
        }
        file.framePosition = 0
        try file.read(into: buffer)
        return buffer
    }

    func loadFile(url: URL) throws -> AVAudioFile {
        // Check if this file was preloaded (thread-safe access)
        var preFile: AVAudioFile?
        var preBuf: AVAudioPCMBuffer?
        var preURL: URL?
        preloadQueue.sync {
            preFile = self.preloadedFile
            preBuf = self.preloadedBuffer
            preURL = self.preloadedURL
        }

        if let preURL = preURL, preURL == url,
           let file = preFile, let buf = preBuf {
            self.audioFile = file
            self.audioBuffer = buf
            preloadQueue.sync {
                self.preloadedFile = nil
                self.preloadedBuffer = nil
                self.preloadedURL = nil
            }
            return file
        }

        do {
            let file = try AVAudioFile(forReading: url)
            self.audioFile = file
            self.audioBuffer = try bufferFile(file)
            // Clear preload since we loaded a different track
            preloadQueue.sync {
                self.preloadedFile = nil
                self.preloadedBuffer = nil
                self.preloadedURL = nil
            }
            return file
        } catch {
            throw AudioEngineError.unableToLoadFile(error.localizedDescription)
        }
    }

    /// Set already-buffered content directly, bypassing the preload cache.
    /// Call this from the main thread after background buffering is complete.
    func setContent(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        audioFile = file
        audioBuffer = buffer
        preloadQueue.sync {
            preloadedFile = nil
            preloadedBuffer = nil
            preloadedURL = nil
        }
    }

    func preloadFile(url: URL) {
        preloadQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let file = try AVAudioFile(forReading: url)
                let buffer = try self.bufferFile(file)
                self.preloadedFile = file
                self.preloadedBuffer = buffer
                self.preloadedURL = url
            } catch {
                print("Error preloading next track: \(error.localizedDescription)")
            }
        }
    }

    /// Prepare audio graph for playback. Only reconnects nodes if the format has changed.
    /// Also starts the engine eagerly so the audio hardware is warm before the user
    /// presses play — avoids a synchronous engine.start() on the main thread later.
    func prepareForPlayback() throws {
        guard let file = audioFile,
              let engine = engine,
              let player = playerNode,
              let eq = eqNode else {
            throw AudioEngineError.notInitialized
        }

        let newFormat = file.processingFormat

        // Only reconnect nodes if the format has changed (avoids click/pop)
        if connectedFormat == nil || connectedFormat != newFormat {
            // Disconnect existing connections
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(eq)

            // Connect: playerNode → eqNode → mainMixer
            engine.connect(player, to: eq, format: newFormat)
            engine.connect(eq, to: engine.mainMixerNode, format: newFormat)

            connectedFormat = newFormat
        }

        engine.prepare()

        // Start the engine now so the audio hardware is ready.
        // play() / resume() won't need to call engine.start() when the button is pressed.
        if !engine.isRunning {
            try engine.start()
        }

        currentFramePosition = 0
    }

    private func scheduleBufferWithCompletion(_ buffer: AVAudioPCMBuffer) {
        guard let player = playerNode else { return }
        let generation = self.playGeneration
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.playGeneration == generation {
                    self.onPlaybackFinished?()
                }
            }
        }
    }

    func play() throws {
        guard let engine = engine,
              let player = playerNode,
              let buffer = audioBuffer else {
            throw AudioEngineError.notInitialized
        }

        if !engine.isRunning {
            try engine.start()
        }

        scheduleBufferWithCompletion(buffer)
        player.play()
    }

    func pause() {
        playerNode?.pause()
        isPaused = true
    }

    /// Play or resume. If the player was paused, resumes from the paused position
    /// without rescheduling the buffer. If the player was stopped (first play or after
    /// a track switch), schedules the full buffer and starts the player.
    func resume() throws {
        guard let engine = engine, let player = playerNode else {
            throw AudioEngineError.notInitialized
        }
        if !engine.isRunning {
            // prepareForPlayback() starts the engine eagerly, so this path is only
            // hit if the engine stopped unexpectedly (e.g. config change while paused).
            try engine.start()
        }
        if isPaused {
            // Buffer is still scheduled mid-stream — just unpause the player.
            player.play()
        } else {
            // First play after load, or after a stop — schedule the buffer then play.
            guard let buffer = audioBuffer else { throw AudioEngineError.notInitialized }
            scheduleBufferWithCompletion(buffer)
            player.play()
        }
        isPaused = false
    }

    /// Soft stop: stops the player node but keeps the engine running for quick transitions.
    func stopPlayer() {
        playGeneration += 1
        playerNode?.stop()
        currentFramePosition = 0
        isPaused = false
    }

    /// Hard stop: stops both the player node and the audio engine.
    func stop() {
        // Increment generation to invalidate any pending completions
        playGeneration += 1
        playerNode?.stop()
        engine?.stop()
        currentFramePosition = 0
        connectedFormat = nil
        isPaused = false
    }

    func seek(to time: TimeInterval, forcePlay: Bool = false) throws {
        guard let file = audioFile,
              let buffer = audioBuffer,
              let player = playerNode,
              let engine = engine else {
            throw AudioEngineError.notInitialized
        }

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * sampleRate)
        let totalFrames = AVAudioFramePosition(buffer.frameLength)

        guard startFrame >= 0 && startFrame < totalFrames else {
            throw AudioEngineError.invalidSeekPosition
        }

        let wasPlaying = player.isPlaying

        // Increment generation to invalidate the old completion
        playGeneration += 1
        player.stop()

        // Create a sub-buffer from the seek position to the end
        let remainingFrames = AVAudioFrameCount(totalFrames - startFrame)
        guard let seekBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: remainingFrames) else {
            throw AudioEngineError.decodingFailed
        }

        // Copy audio data from startFrame onwards
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            if let src = buffer.floatChannelData?[channel],
               let dst = seekBuffer.floatChannelData?[channel] {
                let srcOffset = src.advanced(by: Int(startFrame))
                dst.update(from: srcOffset, count: Int(remainingFrames))
            }
        }
        seekBuffer.frameLength = remainingFrames

        scheduleBufferWithCompletion(seekBuffer)

        currentFramePosition = startFrame

        if !engine.isRunning {
            try engine.start()
        }

        if wasPlaying || forcePlay {
            player.play()
        }
    }

    var duration: TimeInterval {
        guard let file = audioFile else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var isPlaying: Bool {
        return playerNode?.isPlaying ?? false
    }

    func setVolume(_ volume: Float) {
        engine?.mainMixerNode.outputVolume = volume
    }

    // MARK: - EQ Controls

    func setEQ(bassGain: Float, trebleGain: Float) {
        guard let eq = eqNode else { return }
        eq.bands[0].gain = bassGain
        eq.bands[1].gain = trebleGain
    }

    func setEQBypass(_ bypass: Bool) {
        eqNode?.bypass = bypass
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }
}

enum AudioEngineError: Error, LocalizedError {
    case unableToLoadFile(String)
    case notInitialized
    case invalidSeekPosition
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .unableToLoadFile(let details):
            return "Unable to load audio file: \(details)"
        case .notInitialized:
            return "Audio engine not properly initialized"
        case .invalidSeekPosition:
            return "Invalid seek position"
        case .decodingFailed:
            return "Audio decoding failed"
        }
    }
}
