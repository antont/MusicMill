import Foundation
import AVFoundation
import Accelerate

/// Core granular synthesis engine for real-time audio generation
/// Uses AVAudioSourceNode with render callback for sample-accurate synthesis
class GranularSynthesizer {
    
    // MARK: - Types
    
    enum EnvelopeType {
        case hann
        case hamming
        case blackman
        case triangle
    }
    
    struct GrainParameters {
        var grainSize: TimeInterval = 0.05 // 50ms default
        var grainDensity: Double = 20.0 // Grains per second
        var pitch: Float = 1.0 // Playback rate
        var pan: Float = 0.0 // -1 to 1
        var amplitude: Float = 0.8
        var envelopeType: EnvelopeType = .hann
        var positionJitter: Float = 0.1 // Random position variation (0-1)
        var pitchJitter: Float = 0.02 // Random pitch variation
    }
    
    /// Internal grain representation for scheduling
    private struct ScheduledGrain {
        var sourceBufferIndex: Int
        var sourcePosition: Int // Sample position in source
        var grainSamples: Int // Grain length in samples
        var pitch: Float
        var pan: Float
        var amplitude: Float
        var envelope: [Float]
        var playbackPosition: Int = 0 // Current position within grain
        var isActive: Bool = true
    }
    
    // MARK: - Properties
    
    private var audioEngine: AVAudioEngine
    private var sourceNode: AVAudioSourceNode?
    private let format: AVAudioFormat
    private let sampleRate: Double = 44100.0
    
    // Source buffers (loaded samples)
    private var sourceBuffers: [(identifier: String, buffer: AVAudioPCMBuffer)] = []
    private var sourceBuffersLock = NSLock()
    
    // Active grains (rendered in audio thread)
    private var activeGrains: [ScheduledGrain] = []
    private var grainsLock = NSLock()
    private let maxActiveGrains = 64
    
    // Pre-computed envelopes
    private var hannWindow: [Float] = []
    private var hammingWindow: [Float] = []
    private var blackmanWindow: [Float] = []
    private var triangleWindow: [Float] = []
    private let maxGrainSamples = 8820 // 200ms at 44100 Hz
    
    // Parameters (can be changed in real-time)
    private var _parameters = GrainParameters()
    private var parametersLock = NSLock()
    var parameters: GrainParameters {
        get {
            parametersLock.lock()
            defer { parametersLock.unlock() }
            return _parameters
        }
        set {
            parametersLock.lock()
            _parameters = newValue
            parametersLock.unlock()
        }
    }
    
    // Grain scheduling
    private var samplesSinceLastGrain: Int = 0
    private var isPlaying = false
    private var currentSourceIndex: Int = 0
    private var currentPosition: Float = 0.0 // 0-1 position in current source
    
    // MARK: - Initialization
    
    init() {
        audioEngine = AVAudioEngine()
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        // Pre-compute envelope windows
        precomputeEnvelopes()
        
        // Create source node with render callback
        setupSourceNode()
    }
    
    /// Pre-computes envelope windows for different sizes
    private func precomputeEnvelopes() {
        hannWindow = createWindow(type: .hann, size: maxGrainSamples)
        hammingWindow = createWindow(type: .hamming, size: maxGrainSamples)
        blackmanWindow = createWindow(type: .blackman, size: maxGrainSamples)
        triangleWindow = createWindow(type: .triangle, size: maxGrainSamples)
    }
    
    /// Creates a window function of specified type and size
    private func createWindow(type: EnvelopeType, size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        
        switch type {
        case .hann:
            for i in 0..<size {
                window[i] = Float(0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(size - 1))))
            }
        case .hamming:
            for i in 0..<size {
                window[i] = Float(0.54 - 0.46 * cos(2.0 * Double.pi * Double(i) / Double(size - 1)))
            }
        case .blackman:
            for i in 0..<size {
                let a0: Double = 0.42
                let a1: Double = 0.5
                let a2: Double = 0.08
                let n = Double(i) / Double(size - 1)
                window[i] = Float(a0 - a1 * cos(2.0 * Double.pi * n) + a2 * cos(4.0 * Double.pi * n))
            }
        case .triangle:
            for i in 0..<size {
                if i < size / 2 {
                    window[i] = Float(i) / Float(size / 2)
                } else {
                    window[i] = 1.0 - Float(i - size / 2) / Float(size / 2)
                }
            }
        }
        
        return window
    }
    
    /// Sets up the audio source node with render callback
    private func setupSourceNode() {
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.renderAudio(frameCount: frameCount, audioBufferList: audioBufferList)
        }
        
        guard let sourceNode = sourceNode else { return }
        
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()
    }
    
    // MARK: - Audio Render Callback
    
    /// Main render callback - called from audio thread
    private func renderAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard isPlaying else {
            // Output silence
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard ablPointer.count >= 2 else { return noErr }
        
        let leftBuffer = ablPointer[0]
        let rightBuffer = ablPointer[1]
        
        guard let leftData = leftBuffer.mData?.assumingMemoryBound(to: Float.self),
              let rightData = rightBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        
        // Clear output buffers
        memset(leftBuffer.mData, 0, Int(leftBuffer.mDataByteSize))
        memset(rightBuffer.mData, 0, Int(rightBuffer.mDataByteSize))
        
        // Get current parameters (minimize lock time)
        parametersLock.lock()
        let params = _parameters
        parametersLock.unlock()
        
        // Process each sample
        for sample in 0..<Int(frameCount) {
            // Schedule new grains based on density
            samplesSinceLastGrain += 1
            let samplesPerGrain = Int(sampleRate / params.grainDensity)
            
            if samplesSinceLastGrain >= samplesPerGrain {
                scheduleNewGrain(params: params)
                samplesSinceLastGrain = 0
            }
            
            // Mix all active grains
            var leftSample: Float = 0.0
            var rightSample: Float = 0.0
            
            grainsLock.lock()
            for i in 0..<activeGrains.count {
                guard activeGrains[i].isActive else { continue }
                
                let (left, right) = renderGrainSample(&activeGrains[i])
                leftSample += left
                rightSample += right
            }
            
            // Remove completed grains
            activeGrains.removeAll { !$0.isActive }
            grainsLock.unlock()
            
            // Soft clip to prevent harsh clipping
            leftData[sample] = softClip(leftSample)
            rightData[sample] = softClip(rightSample)
        }
        
        return noErr
    }
    
    /// Schedules a new grain for playback
    private func scheduleNewGrain(params: GrainParameters) {
        sourceBuffersLock.lock()
        guard !sourceBuffers.isEmpty else {
            sourceBuffersLock.unlock()
            return
        }
        
        // Select source buffer
        let bufferIndex = currentSourceIndex % sourceBuffers.count
        let sourceBuffer = sourceBuffers[bufferIndex].buffer
        sourceBuffersLock.unlock()
        
        guard let channelData = sourceBuffer.floatChannelData else { return }
        let sourceLength = Int(sourceBuffer.frameLength)
        guard sourceLength > 0 else { return }
        
        // Calculate grain parameters with jitter
        let grainSamples = min(Int(params.grainSize * sampleRate), maxGrainSamples)
        let positionJitter = (Float.random(in: -1...1) * params.positionJitter)
        let position = max(0, min(1, currentPosition + positionJitter))
        let sourcePosition = Int(position * Float(sourceLength - grainSamples))
        
        let pitchJitter = 1.0 + (Float.random(in: -1...1) * params.pitchJitter)
        let pitch = params.pitch * pitchJitter
        
        // Get envelope for this grain size
        let envelope = getEnvelope(type: params.envelopeType, size: grainSamples)
        
        let grain = ScheduledGrain(
            sourceBufferIndex: bufferIndex,
            sourcePosition: max(0, sourcePosition),
            grainSamples: grainSamples,
            pitch: pitch,
            pan: params.pan,
            amplitude: params.amplitude,
            envelope: envelope,
            playbackPosition: 0,
            isActive: true
        )
        
        grainsLock.lock()
        if activeGrains.count < maxActiveGrains {
            activeGrains.append(grain)
        }
        grainsLock.unlock()
    }
    
    /// Renders a single sample from a grain
    private func renderGrainSample(_ grain: inout ScheduledGrain) -> (Float, Float) {
        guard grain.playbackPosition < grain.grainSamples else {
            grain.isActive = false
            return (0, 0)
        }
        
        sourceBuffersLock.lock()
        guard grain.sourceBufferIndex < sourceBuffers.count else {
            sourceBuffersLock.unlock()
            grain.isActive = false
            return (0, 0)
        }
        
        let sourceBuffer = sourceBuffers[grain.sourceBufferIndex].buffer
        guard let channelData = sourceBuffer.floatChannelData else {
            sourceBuffersLock.unlock()
            grain.isActive = false
            return (0, 0)
        }
        
        let sourceLength = Int(sourceBuffer.frameLength)
        let channelCount = Int(sourceBuffer.format.channelCount)
        sourceBuffersLock.unlock()
        
        // Calculate source position with pitch shifting
        let sourcePos = grain.sourcePosition + Int(Float(grain.playbackPosition) * grain.pitch)
        guard sourcePos >= 0 && sourcePos < sourceLength else {
            grain.isActive = false
            return (0, 0)
        }
        
        // Get sample from source (mono or stereo)
        var sample: Float = 0.0
        if channelCount >= 2 {
            sample = (channelData[0][sourcePos] + channelData[1][sourcePos]) / 2.0
        } else {
            sample = channelData[0][sourcePos]
        }
        
        // Apply envelope
        let envelopeIndex = min(grain.playbackPosition, grain.envelope.count - 1)
        let envelopeValue = grain.envelope[envelopeIndex]
        sample *= envelopeValue * grain.amplitude
        
        // Apply panning (constant power)
        let panAngle = (grain.pan + 1.0) * Float.pi / 4.0 // 0 to pi/2
        let leftGain = cos(panAngle)
        let rightGain = sin(panAngle)
        
        grain.playbackPosition += 1
        
        return (sample * leftGain, sample * rightGain)
    }
    
    /// Gets envelope for specified type and size
    private func getEnvelope(type: EnvelopeType, size: Int) -> [Float] {
        let fullWindow: [Float]
        switch type {
        case .hann: fullWindow = hannWindow
        case .hamming: fullWindow = hammingWindow
        case .blackman: fullWindow = blackmanWindow
        case .triangle: fullWindow = triangleWindow
        }
        
        // Resample window to requested size
        if size >= fullWindow.count {
            return fullWindow
        }
        
        var resampled = [Float](repeating: 0, count: size)
        let ratio = Float(fullWindow.count) / Float(size)
        for i in 0..<size {
            let sourceIndex = Int(Float(i) * ratio)
            resampled[i] = fullWindow[min(sourceIndex, fullWindow.count - 1)]
        }
        return resampled
    }
    
    /// Soft clip to prevent harsh distortion
    private func softClip(_ x: Float) -> Float {
        if x > 1.0 {
            return 1.0 - exp(1.0 - x)
        } else if x < -1.0 {
            return -1.0 + exp(1.0 + x)
        }
        return x
    }
    
    // MARK: - Public API
    
    /// Loads a source audio buffer for granular synthesis
    func loadSourceBuffer(_ buffer: AVAudioPCMBuffer, identifier: String) {
        sourceBuffersLock.lock()
        // Remove existing buffer with same identifier
        sourceBuffers.removeAll { $0.identifier == identifier }
        sourceBuffers.append((identifier, buffer))
        sourceBuffersLock.unlock()
    }
    
    /// Loads audio from a URL
    func loadSource(from url: URL, identifier: String) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, 
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw GranularError.bufferCreationFailed
        }
        try file.read(into: buffer)
        
        // Convert to standard format if needed
        if let convertedBuffer = convertToStandardFormat(buffer) {
            loadSourceBuffer(convertedBuffer, identifier: identifier)
        } else {
            loadSourceBuffer(buffer, identifier: identifier)
        }
    }
    
    /// Converts buffer to standard format (44100 Hz, stereo, float)
    private func convertToStandardFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format != format else { return nil }
        
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }
        
        let ratio = format.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCapacity) else {
            return nil
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        return error == nil ? outputBuffer : nil
    }
    
    /// Sets the playback position (0-1) within current source
    func setPosition(_ position: Float) {
        currentPosition = max(0, min(1, position))
    }
    
    /// Sets which source buffer to use
    func setSourceIndex(_ index: Int) {
        sourceBuffersLock.lock()
        if index < sourceBuffers.count {
            currentSourceIndex = index
        }
        sourceBuffersLock.unlock()
    }
    
    /// Starts granular synthesis
    func start() throws {
        guard !isPlaying else { return }
        
        sourceBuffersLock.lock()
        let hasBuffers = !sourceBuffers.isEmpty
        sourceBuffersLock.unlock()
        
        guard hasBuffers else {
            throw GranularError.noSourceBuffers
        }
        
        try audioEngine.start()
        isPlaying = true
    }
    
    /// Stops granular synthesis
    func stop() {
        isPlaying = false
        audioEngine.stop()
        
        grainsLock.lock()
        activeGrains.removeAll()
        grainsLock.unlock()
    }
    
    /// Gets the audio engine for external connections
    func getAudioEngine() -> AVAudioEngine {
        return audioEngine
    }
    
    /// Gets output node for connecting to mixers
    func getOutputNode() -> AVAudioNode {
        return audioEngine.mainMixerNode
    }
    
    /// Returns list of loaded source identifiers
    func getSourceIdentifiers() -> [String] {
        sourceBuffersLock.lock()
        let identifiers = sourceBuffers.map { $0.identifier }
        sourceBuffersLock.unlock()
        return identifiers
    }
    
    // MARK: - Errors
    
    enum GranularError: LocalizedError {
        case noSourceBuffers
        case bufferCreationFailed
        
        var errorDescription: String? {
            switch self {
            case .noSourceBuffers:
                return "No source buffers loaded for granular synthesis"
            case .bufferCreationFailed:
                return "Failed to create audio buffer"
            }
        }
    }
}
