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

    // Pre-buffered next track (protected by serial queue)
    var preloadedFile: AVAudioFile?
    var preloadedBuffer: AVAudioPCMBuffer?
    var preloadedURL: URL?
    let preloadQueue = DispatchQueue(label: "com.audioplayer.preload")

    var onPlaybackFinished: (() -> Void)?

    // Called on the main thread when the audio output device changes (e.g. AirPlay
    // selected). AVAudioEngine stops itself; the manager must restart playback.
    var onConfigurationChange: (() -> Void)?

    // CoreAudio property listener blocks — stored so we can remove them in deinit.
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    // Track which CoreAudio device the engine is currently pointed at so we
    // can skip no-op switches and detect when AirPlay is deselected.
    private var currentOutputDeviceID: AudioDeviceID = kAudioObjectUnknown

    // Prevents double-handling when both the CoreAudio listener and
    // AVAudioEngineConfigurationChangeNotification fire for the same event.
    private var isHandlingDeviceChange = false

    init() {
        setupEngine()
    }

    private func setupEngine() {
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        eqNode = AVAudioUnitEQ(numberOfBands: 2)

        guard let engine = engine,
              let player = playerNode,
              let eq = eqNode else { return }

        // Configure EQ bands
        // Band 0: Bass at 100 Hz
        let bassBand = eq.bands[0]
        bassBand.filterType = .parametric
        bassBand.frequency = 100
        bassBand.bandwidth = 1.0
        bassBand.gain = 0
        bassBand.bypass = false

        // Band 1: Treble at 10 kHz
        let trebleBand = eq.bands[1]
        trebleBand.filterType = .parametric
        trebleBand.frequency = 10000
        trebleBand.bandwidth = 1.0
        trebleBand.gain = 0
        trebleBand.bypass = false

        // EQ bypassed by default
        eq.bypass = true

        // Attach nodes
        engine.attach(player)
        engine.attach(eq)

        // AVAudioEngine stops itself when the system output device changes and
        // fires this notification. We restart playback on the new device.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )

        // CoreAudio-level monitoring catches device changes that the engine
        // notification misses — in particular, AVRoutePickerView selecting AirPlay
        // creates a virtual CoreAudio output device and becomes the system default.
        setupOutputDeviceMonitoring()
    }

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        // Skip if CoreAudio monitoring already triggered a switchover.
        guard !isHandlingDeviceChange else { return }
        connectedFormat = nil
        DispatchQueue.main.async { [weak self] in
            self?.onConfigurationChange?()
        }
    }

    // MARK: - CoreAudio output device monitoring

    private func setupOutputDeviceMonitoring() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        // Watch for AirPlay device appearing / disappearing (device-list change).
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleAudioDevicesChanged() }
        }
        devicesListenerBlock = devBlock
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(systemObject, &devAddr, nil, devBlock)

        // Watch for the system default output changing (covers Control-Centre
        // AirPlay toggle and route-picker selections that update the system default).
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleDefaultOutputDeviceChanged() }
        }
        defaultOutputListenerBlock = defaultBlock
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(systemObject, &defaultAddr, nil, defaultBlock)
    }

    private func handleAudioDevicesChanged() {
        // AirPlay device appeared → switch engine to it.
        // AirPlay device disappeared → fall back to system default.
        if let airPlayID = firstAirPlayOutputDeviceID() {
            guard airPlayID != currentOutputDeviceID else { return }
            switchEngineTo(deviceID: airPlayID)
        } else if isAirPlayDevice(currentOutputDeviceID) {
            // Our AirPlay device vanished; fall back to system default.
            let defaultID = systemDefaultOutputDeviceID()
            guard defaultID != kAudioObjectUnknown else { return }
            switchEngineTo(deviceID: defaultID)
        }
    }

    private func handleDefaultOutputDeviceChanged() {
        let newID = systemDefaultOutputDeviceID()
        guard newID != kAudioObjectUnknown, newID != currentOutputDeviceID else { return }
        switchEngineTo(deviceID: newID)
    }

    private func switchEngineTo(deviceID: AudioDeviceID) {
        guard !isHandlingDeviceChange else { return }
        isHandlingDeviceChange = true
        currentOutputDeviceID = deviceID

        // Stop the engine, point its output node at the new device, then
        // signal the manager to reconnect nodes and resume playback.
        engine?.stop()
        engine?.outputNode.auAudioUnit.deviceID = deviceID
        connectedFormat = nil

        DispatchQueue.main.async { [weak self] in
            self?.onConfigurationChange?()
            self?.isHandlingDeviceChange = false
        }
    }

    // MARK: - CoreAudio helpers

    private func firstAirPlayOutputDeviceID() -> AudioDeviceID? {
        allOutputDeviceIDs().first { isAirPlayDevice($0) }
    }

    private func isAirPlayDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &type)
        return type == 0x61697270 // 'airp' — kAudioDeviceTransportTypeAirPlay
    }

    private func systemDefaultOutputDeviceID() -> AudioDeviceID {
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private func allOutputDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        // Filter to devices that have output streams.
        return ids.filter { id in
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &outAddr, 0, nil, &outSize) == noErr && outSize > 0
        }
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
    }

    /// Soft stop: stops the player node but keeps the engine running for quick transitions.
    func stopPlayer() {
        playGeneration += 1
        playerNode?.stop()
        currentFramePosition = 0
    }

    /// Hard stop: stops both the player node and the audio engine.
    func stop() {
        // Increment generation to invalidate any pending completions
        playGeneration += 1
        playerNode?.stop()
        engine?.stop()
        currentFramePosition = 0
        connectedFormat = nil
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
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if let block = devicesListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObject, &addr, nil, block)
        }
        if let block = defaultOutputListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObject, &addr, nil, block)
        }
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
