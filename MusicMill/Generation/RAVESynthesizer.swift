import Foundation
import AVFoundation
import AVFAudio

/// RAVE (Realtime Audio Variational autoEncoder) synthesizer
/// Uses Python bridge for neural audio generation via PyTorch MPS
class RAVESynthesizer {
    
    // MARK: - Types
    
    struct Parameters {
        var masterVolume: Float = 1.0
        var energy: Float = 0.5
        var tempoFactor: Float = 1.0
        var variation: Float = 0.5
        var styleBlend: [String: Float]? = nil
        var interpolationRate: Float = 0.1
    }
    
    enum RAVEError: LocalizedError {
        case bridgeNotStarted
        case generationFailed(String)
        case audioEngineError(String)
        
        var errorDescription: String? {
            switch self {
            case .bridgeNotStarted:
                return "RAVE server not started"
            case .generationFailed(let msg):
                return "Generation failed: \(msg)"
            case .audioEngineError(let msg):
                return "Audio engine error: \(msg)"
            }
        }
    }
    
    // MARK: - Properties
    
    private let bridge: RAVEBridge
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double = 48000.0
    
    private var parameters = Parameters()
    private var isPlaying = false
    private let parametersLock = NSLock()
    
    // Buffer management
    private var bufferFillTask: Task<Void, Never>?
    private let minBufferedSamples = 96000  // 2 seconds minimum buffer for smoother playback
    
    // Available styles (from server)
    private(set) var availableStyles: [String] = []
    
    // Microphone input for style transfer
    private var micInputEnabled = false
    private var micInputBuffer: [Float] = []
    private let micInputLock = NSLock()
    private let micChunkSize = 8192  // ~170ms chunks for responsive style transfer (multiple of RAVE frame size)
    private var micProcessingTask: Task<Void, Never>?
    private(set) var micInputLevel: Float = 0  // For UI level meter
    var micInputGain: Float = 3.0  // Boost input signal (adjustable)
    var micOutputGain: Float = 2.0  // Boost output signal
    var micNoiseExcitation: Float = 0.5  // RAVE needs noise to respond well!
    
    // Current model name
    var currentModel: String {
        return bridge.modelName
    }
    
    // MARK: - Initialization
    
    init(modelName: String = "percussion", anchorsPath: String? = nil) {
        let defaultAnchors = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MusicMill/RAVE/anchors.json").path
        
        bridge = RAVEBridge(
            modelName: modelName,
            anchorsPath: anchorsPath ?? (FileManager.default.fileExists(atPath: defaultAnchors) ? defaultAnchors : nil)
        )
        
        setupAudioEngine()
    }
    
    deinit {
        stop()
        bridge.stop()
    }
    
    private func setupAudioEngine() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.renderAudio(frameCount: frameCount, audioBufferList: audioBufferList)
        }
        
        guard let sourceNode = sourceNode else { return }
        
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
    }
    
    // MARK: - Server Management
    
    /// Starts the RAVE server
    func startServer() async throws {
        try await bridge.start()
        availableStyles = bridge.getStyles()
        print("RAVESynthesizer: Server started, styles: \(availableStyles)")
    }
    
    /// Stops the RAVE server
    func stopServer() {
        stop()
        bridge.stop()
    }
    
    /// Server status
    var serverStatus: RAVEBridge.Status {
        return bridge.status
    }
    
    /// Whether server is running
    var isServerRunning: Bool {
        if case .running = bridge.status {
            return true
        }
        return false
    }
    
    /// Gets list of available RAVE models
    static func getAvailableModels() -> [String] {
        return RAVEBridge.getAvailableModels()
    }
    
    /// Gets diagnostics for debugging path issues
    func getDiagnostics() -> [String: String] {
        return bridge.getDiagnostics()
    }
    
    /// Switches to a different RAVE model (restarts server)
    func switchModel(to newModel: String) async throws {
        let wasPlaying = isPlaying
        if wasPlaying {
            stop()
        }
        
        try await bridge.switchModel(to: newModel)
        availableStyles = bridge.getStyles()
        
        print("RAVESynthesizer: Switched to model: \(newModel)")
        
        if wasPlaying {
            try start()
        }
    }
    
    // MARK: - Playback Control
    
    /// Starts audio generation and playback
    func start() throws {
        guard isServerRunning else {
            print("RAVESynthesizer: Cannot start - server not running")
            throw RAVEError.bridgeNotStarted
        }
        
        print("RAVESynthesizer: Starting audio playback...")
        
        if !audioEngine.isRunning {
            try audioEngine.start()
            print("RAVESynthesizer: Audio engine started")
        }
        
        isPlaying = true
        print("RAVESynthesizer: isPlaying = true")
        
        // Start buffer fill loop
        startBufferFillLoop()
        print("RAVESynthesizer: Buffer fill loop started")
    }
    
    /// Stops audio generation and playback
    func stop() {
        isPlaying = false
        bufferFillTask?.cancel()
        bufferFillTask = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        bridge.clearBuffer()
    }
    
    /// Pauses playback without stopping server
    func pause() {
        isPlaying = false
        bufferFillTask?.cancel()
        bufferFillTask = nil
    }
    
    /// Resumes playback
    func resume() throws {
        guard isServerRunning else {
            throw RAVEError.bridgeNotStarted
        }
        
        isPlaying = true
        
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        
        startBufferFillLoop()
    }
    
    // MARK: - Parameter Control
    
    /// Sets style by name (single style, full weight)
    func setStyle(_ style: String) {
        parametersLock.lock()
        parameters.styleBlend = [style: 1.0]
        parametersLock.unlock()
    }
    
    /// Sets style blend (multiple styles with weights)
    func setStyleBlend(_ blend: [String: Float]) {
        parametersLock.lock()
        parameters.styleBlend = blend
        parametersLock.unlock()
    }
    
    /// Sets energy level (0-1)
    func setEnergy(_ energy: Float) {
        parametersLock.lock()
        parameters.energy = max(0, min(1, energy))
        parametersLock.unlock()
    }
    
    /// Sets tempo factor (0.5-2.0)
    func setTempoFactor(_ tempo: Float) {
        parametersLock.lock()
        parameters.tempoFactor = max(0.5, min(2.0, tempo))
        parametersLock.unlock()
    }
    
    /// Sets variation amount (0-1)
    func setVariation(_ variation: Float) {
        parametersLock.lock()
        parameters.variation = max(0, min(1, variation))
        parametersLock.unlock()
    }
    
    /// Sets master volume (0-1)
    func setVolume(_ volume: Float) {
        parametersLock.lock()
        parameters.masterVolume = max(0, min(1, volume))
        parametersLock.unlock()
    }
    
    /// Sets all parameters from Performance controls
    func setParameters(style: String?, tempo: Double, energy: Double) {
        parametersLock.lock()
        
        if let style = style {
            parameters.styleBlend = [style: 1.0]
        }
        
        // Map tempo BPM to tempo factor (assuming base tempo of 120 BPM)
        parameters.tempoFactor = Float(tempo / 120.0)
        parameters.energy = Float(energy)
        
        parametersLock.unlock()
    }
    
    /// Gets current parameters
    func getParameters() -> Parameters {
        parametersLock.lock()
        defer { parametersLock.unlock() }
        return parameters
    }
    
    // MARK: - Buffer Management
    
    private func startBufferFillLoop() {
        bufferFillTask?.cancel()
        print("RAVESynthesizer: Starting buffer fill loop")
        
        bufferFillTask = Task { [weak self] in
            guard let self = self else { return }
            var fillCount = 0
            var errorCount = 0
            
            while !Task.isCancelled && self.isPlaying {
                let buffered = self.bridge.bufferedSamples
                
                // Check if buffer needs filling
                if buffered < self.minBufferedSamples {
                    do {
                        let controls = self.getCurrentControls()
                        try await self.bridge.fillBuffer(controls: controls)
                        fillCount += 1
                        errorCount = 0  // Reset error count on success
                        
                        let newBuffered = self.bridge.bufferedSamples
                        print("RAVESynthesizer: Buffer fill #\(fillCount): \(buffered) -> \(newBuffered) samples")
                    } catch {
                        errorCount += 1
                        print("RAVESynthesizer: Buffer fill error #\(errorCount): \(error)")
                        
                        // If we get repeated errors, try reconnecting
                        if errorCount >= 3 {
                            print("RAVESynthesizer: Too many errors, resetting connection...")
                            self.bridge.resetConnection()
                            errorCount = 0
                            try? await Task.sleep(nanoseconds: 500_000_000)  // Wait 500ms before retry
                        }
                    }
                }
                
                // Small delay to prevent tight loop
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
            print("RAVESynthesizer: Buffer fill loop ended")
        }
    }
    
    private func getCurrentControls() -> RAVEBridge.Controls {
        parametersLock.lock()
        let params = parameters
        parametersLock.unlock()
        
        return RAVEBridge.Controls(
            styleBlend: params.styleBlend,
            energy: params.energy,
            tempoFactor: params.tempoFactor,
            variation: params.variation
        )
    }
    
    // MARK: - Audio Rendering
    
    private func renderAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard ablPointer.count >= 2 else { return noErr }
        
        let leftOut = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let rightOut = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        guard isPlaying else {
            // Fill with silence
            for i in 0..<Int(frameCount) {
                leftOut?[i] = 0
                rightOut?[i] = 0
            }
            return noErr
        }
        
        // Get volume
        parametersLock.lock()
        let volume = parameters.masterVolume
        parametersLock.unlock()
        
        // Read from bridge buffer
        let samples = bridge.readSamples(count: Int(frameCount))
        
        for i in 0..<Int(frameCount) {
            let sample = samples[i] * volume
            leftOut?[i] = sample
            rightOut?[i] = sample
        }
        
        return noErr
    }
    
    // MARK: - Utility
    
    /// Gets audio engine for external connections
    func getAudioEngine() -> AVAudioEngine {
        return audioEngine
    }
    
    /// Generates audio to a buffer (for testing/export)
    func generateToBuffer(duration: TimeInterval, controls: RAVEBridge.Controls? = nil) async throws -> AVAudioPCMBuffer {
        guard isServerRunning else {
            throw RAVEError.bridgeNotStarted
        }
        
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RAVEError.audioEngineError("Failed to create buffer")
        }
        
        let effectiveControls = controls ?? getCurrentControls()
        
        // Calculate frames needed (RAVE generates ~2048 samples per frame)
        let samplesPerFrame = 2048
        let framesNeeded = Int(ceil(Double(frameCount) / Double(samplesPerFrame)))
        
        // Generate audio
        var allSamples: [Float] = []
        let chunkSize = 50  // Generate in chunks
        
        for start in stride(from: 0, to: framesNeeded, by: chunkSize) {
            let frames = min(chunkSize, framesNeeded - start)
            let audio = try await bridge.generate(controls: effectiveControls, frames: frames)
            allSamples.append(contentsOf: audio)
        }
        
        // Copy to buffer
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData else {
            throw RAVEError.audioEngineError("Failed to get channel data")
        }
        
        let volume = getParameters().masterVolume
        for i in 0..<Int(frameCount) {
            let sample = i < allSamples.count ? allSamples[i] * volume : 0
            channelData[0][i] = sample
        }
        
        return buffer
    }
    
    // MARK: - Microphone Input (Voice Control)
    
    enum MicError: LocalizedError {
        case permissionDenied
        case noInputDevice
        case setupFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone permission denied. Please allow in System Settings > Privacy & Security > Microphone."
            case .noInputDevice:
                return "No audio input device found."
            case .setupFailed(let msg):
                return "Microphone setup failed: \(msg)"
            }
        }
    }
    
    /// Requests microphone permission and enables input
    func enableMicInputAsync() async throws {
        // Request microphone permission
        #if os(macOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("RAVESynthesizer: Current mic permission status: \(status.rawValue)")
        
        switch status {
        case .authorized:
            print("RAVESynthesizer: Mic already authorized")
            try enableMicInput()
        case .notDetermined:
            print("RAVESynthesizer: Requesting mic permission...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                print("RAVESynthesizer: Mic permission granted")
                try enableMicInput()
            } else {
                print("RAVESynthesizer: Mic permission denied by user")
                throw MicError.permissionDenied
            }
        case .denied, .restricted:
            print("RAVESynthesizer: Mic permission denied/restricted")
            throw MicError.permissionDenied
        @unknown default:
            print("RAVESynthesizer: Unknown permission status")
            throw MicError.permissionDenied
        }
        #else
        try enableMicInput()
        #endif
    }
    
    /// Enables microphone input for style transfer
    /// Voice/humming will be transformed through RAVE's learned timbre
    func enableMicInput() throws {
        guard isServerRunning else {
            throw RAVEError.bridgeNotStarted
        }
        
        // Check if we have an input device
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        print("RAVESynthesizer: Input format: \(inputFormat)")
        print("RAVESynthesizer: Input channels: \(inputFormat.channelCount)")
        print("RAVESynthesizer: Input sample rate: \(inputFormat.sampleRate)")
        
        // Check if format is valid (0 channels means no input device)
        guard inputFormat.channelCount > 0 else {
            print("RAVESynthesizer: No input channels available!")
            throw MicError.noInputDevice
        }
        
        guard inputFormat.sampleRate > 0 else {
            print("RAVESynthesizer: Invalid sample rate!")
            throw MicError.noInputDevice
        }
        
        print("RAVESynthesizer: Enabling mic input, format: \(inputFormat)")
        
        do {
            // Install tap on input
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processMicInput(buffer: buffer)
            }
            
            micInputEnabled = true
            startMicProcessingLoop()
            
            print("RAVESynthesizer: Mic input enabled successfully")
        } catch {
            print("RAVESynthesizer: Failed to install tap: \(error)")
            throw MicError.setupFailed(error.localizedDescription)
        }
    }
    
    /// Disables microphone input
    func disableMicInput() {
        micInputEnabled = false
        micProcessingTask?.cancel()
        micProcessingTask = nil
        
        audioEngine.inputNode.removeTap(onBus: 0)
        
        micInputLock.lock()
        micInputBuffer.removeAll()
        micInputLock.unlock()
        
        print("RAVESynthesizer: Mic input disabled")
    }
    
    /// Whether mic input is currently enabled
    var isMicInputEnabled: Bool {
        return micInputEnabled
    }
    
    private func processMicInput(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let frameCount = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: frameCount)
        
        // Copy samples (mono) with input gain
        let gain = micInputGain
        for i in 0..<frameCount {
            samples[i] = channelData[0][i] * gain
        }
        
        // Update input level for UI (post-gain)
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(frameCount))
        micInputLevel = rms
        
        // Debug: print level occasionally
        if Int.random(in: 0..<50) == 0 {
            print("RAVESynthesizer: Mic RMS level: \(rms), samples: \(frameCount)")
        }
        
        // Resample if needed (input might not be 48kHz)
        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        if inputFormat.sampleRate != sampleRate {
            // Simple linear resampling
            let ratio = sampleRate / inputFormat.sampleRate
            let newCount = Int(Double(frameCount) * ratio)
            var resampled = [Float](repeating: 0, count: newCount)
            for i in 0..<newCount {
                let srcIdx = Double(i) / ratio
                let idx0 = Int(srcIdx)
                let idx1 = min(idx0 + 1, frameCount - 1)
                let frac = Float(srcIdx - Double(idx0))
                resampled[i] = samples[idx0] * (1 - frac) + samples[idx1] * frac
            }
            samples = resampled
        }
        
        // Add to buffer
        micInputLock.lock()
        micInputBuffer.append(contentsOf: samples)
        
        // Limit buffer size (max 2 seconds)
        let maxBufferSize = Int(sampleRate * 2)
        if micInputBuffer.count > maxBufferSize {
            micInputBuffer.removeFirst(micInputBuffer.count - maxBufferSize)
        }
        micInputLock.unlock()
    }
    
    private func startMicProcessingLoop() {
        micProcessingTask?.cancel()
        
        micProcessingTask = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled && self.micInputEnabled {
                // Check if we have enough audio to process
                self.micInputLock.lock()
                let hasEnoughAudio = self.micInputBuffer.count >= self.micChunkSize
                var chunk: [Float] = []
                if hasEnoughAudio {
                    chunk = Array(self.micInputBuffer.prefix(self.micChunkSize))
                    self.micInputBuffer.removeFirst(self.micChunkSize)
                }
                self.micInputLock.unlock()
                
                if hasEnoughAudio && !chunk.isEmpty {
                    do {
                        // Send to RAVE for style transfer with noise excitation
                        let noiseExcitation = self.micNoiseExcitation
                        var transformed = try await self.bridge.styleTransfer(
                            inputAudio: chunk,
                            noiseExcitation: noiseExcitation
                        )
                        
                        // Apply output gain
                        let outputGain = self.micOutputGain
                        for i in 0..<transformed.count {
                            transformed[i] *= outputGain
                        }
                        
                        // Add transformed audio to output buffer
                        self.bridge.appendToBuffer(transformed)
                        
                        print("RAVESynthesizer: Style transfer \(chunk.count) samples, noise=\(noiseExcitation)")
                        
                    } catch {
                        print("RAVESynthesizer: Style transfer error: \(error)")
                    }
                }
                
                // Short delay for responsive processing
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            }
        }
    }
}
