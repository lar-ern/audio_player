import Foundation
import AVFoundation

class AudioEngine {
    private var audioFile: AVAudioFile?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eqNode: AVAudioUnitEQ?
    private var connectedFormat: AVAudioFormat?

    // Generation counter to distinguish stale completion callbacks
    private var playGeneration: Int = 0
    // True when player was paused mid-stream; resume() can just call player.play()
    private var isPaused: Bool = false

    // Pre-opened next track file (no buffer — AVAudioEngine streams from disk)
    var preloadedFile: AVAudioFile?
    var preloadedURL: URL?
    let preloadQueue = DispatchQueue(label: "com.audioplayer.preload")

    var onPlaybackFinished: (() -> Void)?

    // Called on the main thread when the audio output device changes.
    var onConfigurationChange: (() -> Void)?

    init() {
        setupEngine()
    }

    // MARK: - Engine setup

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
        engine.attach(player)
        engine.attach(eq)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine)
    }

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        // On macOS 26+, the engine's graph is reset after a hardware change.
        // Rebuild everything before calling onConfigurationChange so that
        // the subsequent prepareForPlayback() starts from a clean state.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.rebuildEngineAfterConfigChange()
            self.onConfigurationChange?()
        }
    }

    private func rebuildEngineAfterConfigChange() {
        let bypass     = eqNode?.bypass        ?? true
        let bassGain   = eqNode?.bands[0].gain ?? 0
        let trebleGain = eqNode?.bands[1].gain ?? 0

        if let old = engine {
            NotificationCenter.default.removeObserver(
                self, name: .AVAudioEngineConfigurationChange, object: old)
            old.stop()
        }

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
        isPaused = false
    }

    // MARK: - Content

    /// Store the file to play. AVAudioEngine will stream it from disk — no
    /// PCM buffer is allocated, so memory use is constant regardless of file size.
    func setContent(file: AVAudioFile) {
        audioFile = file
        preloadQueue.sync {
            preloadedFile = nil
            preloadedURL  = nil
        }
        isPaused = false
    }

    /// Open the next track's file in the background so the filesystem lookup
    /// is already done before the track is needed.
    func preloadFile(url: URL) {
        preloadQueue.async { [weak self] in
            guard let self = self else { return }
            guard let file = try? AVAudioFile(forReading: url) else { return }
            self.preloadedFile = file
            self.preloadedURL  = url
        }
    }

    // MARK: - Playback preparation

    /// Connects nodes (only when the format changes), starts the engine, and
    /// pre-schedules the file so the I/O pipeline is primed before the user
    /// presses play — resume() then just calls player.play() with zero latency.
    func prepareForPlayback() throws {
        guard let file = audioFile,
              let engine = engine,
              let player = playerNode,
              let eq = eqNode else {
            throw AudioEngineError.notInitialized
        }

        let newFormat = file.processingFormat
        let graphChanged = (connectedFormat == nil || connectedFormat != newFormat)

        if graphChanged {
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(eq)
            engine.connect(player, to: eq, format: newFormat)
            engine.connect(eq, to: engine.mainMixerNode, format: newFormat)
            connectedFormat = newFormat
        }

        // engine.prepare() pre-allocates buffers; only call when the graph changed
        // or the engine hasn't started yet — skipping it on every load saves ~10ms.
        if graphChanged || !engine.isRunning {
            engine.prepare()
        }

        if !engine.isRunning {
            try engine.start()
        }

        // Pre-schedule the file now so resume() = player.play() with no added latency.
        // player.stop() first to clear any leftover schedule from the previous track.
        player.stop()
        scheduleFileFromStart()
        isPaused = false
    }

    // MARK: - Transport

    private func scheduleFileFromStart() {
        guard let player = playerNode, let file = audioFile else { return }
        let generation = self.playGeneration
        player.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.playGeneration == generation else { return }
                self.onPlaybackFinished?()
            }
        }
    }

    /// Start or resume playback. In all normal cases this is just player.play():
    /// - First play after load: file was pre-scheduled in prepareForPlayback()
    /// - Resume after pause:    player resumes from its paused position
    /// - After seek:            segment was re-scheduled in seek(to:)
    func resume() throws {
        guard let engine = engine, let player = playerNode else {
            throw AudioEngineError.notInitialized
        }
        // Engine should already be running (started in prepareForPlayback).
        // Re-start only if it stopped unexpectedly (e.g. config change while paused).
        if !engine.isRunning {
            try engine.start()
            // Fresh engine after unexpected stop: re-schedule so there is something to play.
            if !isPaused { scheduleFileFromStart() }
        }
        player.play()
        isPaused = false
    }

    func pause() {
        playerNode?.pause()
        isPaused = true
    }

    /// Soft stop: halts the player node but keeps the engine running.
    func stopPlayer() {
        playGeneration += 1
        playerNode?.stop()
        isPaused = false
    }

    /// Hard stop: halts both the player node and the engine.
    func stop() {
        playGeneration += 1
        playerNode?.stop()
        engine?.stop()
        connectedFormat = nil
        isPaused = false
    }

    /// Seek to a position by scheduling a file segment — no PCM copy needed.
    func seek(to time: TimeInterval, forcePlay: Bool = false) throws {
        guard let file = audioFile,
              let player = playerNode,
              let engine = engine else {
            throw AudioEngineError.notInitialized
        }

        let sampleRate   = file.processingFormat.sampleRate
        let startFrame   = AVAudioFramePosition(time * sampleRate)
        let totalFrames  = AVAudioFramePosition(file.length)

        guard startFrame >= 0 && startFrame < totalFrames else {
            throw AudioEngineError.invalidSeekPosition
        }

        let remainingFrames = AVAudioFrameCount(totalFrames - startFrame)
        let wasPlaying = player.isPlaying || forcePlay

        playGeneration += 1
        let generation = self.playGeneration
        player.stop()
        isPaused = false

        // scheduleSegment reads directly from the file — no memory copy.
        player.scheduleSegment(file,
                               startingFrame: startFrame,
                               frameCount: remainingFrames,
                               at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.playGeneration == generation else { return }
                self.onPlaybackFinished?()
            }
        }

        if !engine.isRunning { try engine.start() }
        if wasPlaying { player.play() }
    }

    // MARK: - Properties

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
        case .unableToLoadFile(let details): return "Unable to load audio file: \(details)"
        case .notInitialized:               return "Audio engine not properly initialized"
        case .invalidSeekPosition:          return "Invalid seek position"
        case .decodingFailed:               return "Audio decoding failed"
        }
    }
}
