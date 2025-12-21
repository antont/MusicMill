import Foundation
import AVFoundation

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
    private let minBufferedSamples = 48000  // 1 second minimum buffer
    
    // Available styles (from server)
    private(set) var availableStyles: [String] = []
    
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
    
    // MARK: - Playback Control
    
    /// Starts audio generation and playback
    func start() throws {
        guard isServerRunning else {
            throw RAVEError.bridgeNotStarted
        }
        
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        
        isPlaying = true
        
        // Start buffer fill loop
        startBufferFillLoop()
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
        
        bufferFillTask = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled && self.isPlaying {
                // Check if buffer needs filling
                if self.bridge.bufferedSamples < self.minBufferedSamples {
                    do {
                        let controls = self.getCurrentControls()
                        try await self.bridge.fillBuffer(controls: controls)
                    } catch {
                        print("RAVESynthesizer: Buffer fill error: \(error)")
                    }
                }
                
                // Small delay to prevent tight loop
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            }
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
}
