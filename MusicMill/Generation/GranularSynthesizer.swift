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
    
    enum EvolutionMode {
        case forward    // Scan forward through source
        case backward   // Scan backward
        case pingPong   // Back and forth
        case random     // Jump to random positions periodically
    }
    
    struct GrainParameters {
        var grainSize: TimeInterval = 0.10 // 100ms default (optimal for quality)
        var grainDensity: Double = 15.0 // Grains per second
        var pitch: Float = 1.0 // Playback rate
        var pan: Float = 0.0 // -1 to 1
        var amplitude: Float = 1.2 // Boost to compensate for windowing
        var envelopeType: EnvelopeType = .blackman // Less spectral leakage
        var positionJitter: Float = 0.05 // Moderate jitter
        var pitchJitter: Float = 0.01 // Moderate pitch variation
        
        // Rhythm alignment parameters
        var rhythmAlignment: Float = 0.8 // 0 = random, 1 = snap to onsets
        var tempoSync: Bool = true // Sync grain rate to detected tempo
        
        // Position evolution - scan through source over time
        var positionEvolution: Float = 0.1 // Speed of position change (0=static, 1=fast)
        var evolutionMode: EvolutionMode = .pingPong // How position evolves
    }
    
    /// Source buffer with analyzed onset positions for rhythmic alignment
    struct SourceBufferInfo {
        let identifier: String
        let buffer: AVAudioPCMBuffer
        let onsets: [Int] // Sample positions of detected onsets
        let tempo: Double? // Detected tempo in BPM
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
    
    // Source buffers (loaded samples with onset analysis)
    private var sourceBuffers: [SourceBufferInfo] = []
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
    
    // Low-pass filter state (one-pole IIR) - reduces grain artifacts
    private var lpfLeftState: Float = 0.0
    private var lpfRightState: Float = 0.0
    private let lpfCutoff: Float = 10000.0 // Hz - balanced cutoff
    
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
    
    // Position evolution state
    private var evolutionDirection: Float = 1.0 // 1 = forward, -1 = backward (for pingPong)
    private var samplesSinceRandomJump: Int = 0 // Timer for random mode
    
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
        
        // Get effective grain density (optionally tempo-synced) - BEFORE sample loop
        var effectiveGrainDensity = params.grainDensity
        if params.tempoSync {
            sourceBuffersLock.lock()
            let tempoValue: Double? = !sourceBuffers.isEmpty ? 
                sourceBuffers[currentSourceIndex % sourceBuffers.count].tempo : nil
            sourceBuffersLock.unlock()
            
            if let tempo = tempoValue {
                // Sync grain rate to tempo: 4 grains per beat (16th notes)
                // Use at least 8 grains/sec for sufficient coverage
                effectiveGrainDensity = max(8.0, tempo / 60.0 * 4.0)
            }
        }
        
        // Evolve position over time (creates variety instead of static loop)
        if params.positionEvolution > 0 {
            // Evolution speed: at 1.0, scan full source in ~10 seconds
            let evolutionSpeed = params.positionEvolution * 0.0001
            let frameDelta = evolutionSpeed * Float(frameCount)
            
            switch params.evolutionMode {
            case .forward:
                currentPosition += frameDelta
                if currentPosition >= 1.0 { currentPosition = 0.0 }
                
            case .backward:
                currentPosition -= frameDelta
                if currentPosition <= 0.0 { currentPosition = 1.0 }
                
            case .pingPong:
                currentPosition += frameDelta * evolutionDirection
                if currentPosition >= 0.95 {
                    evolutionDirection = -1.0
                    currentPosition = 0.95
                } else if currentPosition <= 0.05 {
                    evolutionDirection = 1.0
                    currentPosition = 0.05
                }
                
            case .random:
                // Jump to random position every ~2 seconds
                samplesSinceRandomJump += Int(frameCount)
                let jumpIntervalSamples = Int(sampleRate * 2.0)
                if samplesSinceRandomJump >= jumpIntervalSamples {
                    currentPosition = Float.random(in: 0.1...0.9)
                    samplesSinceRandomJump = 0
                }
            }
        }
        
        // Process each sample
        for sample in 0..<Int(frameCount) {
            // Schedule new grains based on density
            samplesSinceLastGrain += 1
            let samplesPerGrain = Int(sampleRate / effectiveGrainDensity)
            
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
            
            // Apply low-pass filter to reduce grain artifacts
            let (filteredLeft, filteredRight) = lowPassFilter(left: leftSample, right: rightSample)
            
            // Soft clip to prevent harsh clipping
            leftData[sample] = softClip(filteredLeft)
            rightData[sample] = softClip(filteredRight)
        }
        
        return noErr
    }
    
    /// Schedules a new grain for playback with rhythm alignment
    private func scheduleNewGrain(params: GrainParameters) {
        sourceBuffersLock.lock()
        guard !sourceBuffers.isEmpty else {
            sourceBuffersLock.unlock()
            return
        }
        
        // Select source buffer
        let bufferIndex = currentSourceIndex % sourceBuffers.count
        let sourceInfo = sourceBuffers[bufferIndex]
        let sourceBuffer = sourceInfo.buffer
        let onsets = sourceInfo.onsets
        sourceBuffersLock.unlock()
        
        guard sourceBuffer.floatChannelData != nil else { return }
        let sourceLength = Int(sourceBuffer.frameLength)
        guard sourceLength > 0 else { return }
        
        // Calculate grain size
        let grainSamples = min(Int(params.grainSize * sampleRate), maxGrainSamples)
        
        // Calculate base position with jitter
        let positionJitter = (Float.random(in: -1...1) * params.positionJitter)
        let basePosition = max(0, min(1, currentPosition + positionJitter))
        var sourcePosition = Int(basePosition * Float(sourceLength - grainSamples))
        
        // Apply rhythm alignment: blend between random and onset-aligned position
        if params.rhythmAlignment > 0 && !onsets.isEmpty {
            if let nearestOnset = findNearestOnset(to: sourcePosition, in: onsets) {
                // Blend between random position and nearest onset
                let alignedPosition = max(0, min(sourceLength - grainSamples, nearestOnset))
                let blend = params.rhythmAlignment
                sourcePosition = Int(Float(sourcePosition) * (1.0 - blend) + Float(alignedPosition) * blend)
            }
        }
        
        // Apply pitch jitter
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
    
    /// One-pole low-pass filter coefficient
    private var lpfAlpha: Float {
        let rc = 1.0 / (2.0 * Float.pi * lpfCutoff)
        let dt = 1.0 / Float(sampleRate)
        return dt / (rc + dt)
    }
    
    /// Apply low-pass filter to reduce grain artifacts
    private func lowPassFilter(left: Float, right: Float) -> (Float, Float) {
        let alpha = lpfAlpha
        lpfLeftState = lpfLeftState + alpha * (left - lpfLeftState)
        lpfRightState = lpfRightState + alpha * (right - lpfRightState)
        return (lpfLeftState, lpfRightState)
    }
    
    // MARK: - Onset Detection for Rhythm Alignment
    
    /// Detects onset positions in audio buffer for rhythm alignment
    private func detectOnsets(in buffer: AVAudioPCMBuffer) -> [Int] {
        guard let channelData = buffer.floatChannelData else { return [] }
        
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0 else { return [] }
        
        // Convert to mono
        var mono = [Float](repeating: 0, count: frameLength)
        if channelCount >= 2 {
            for i in 0..<frameLength {
                mono[i] = (channelData[0][i] + channelData[1][i]) / 2.0
            }
        } else {
            for i in 0..<frameLength {
                mono[i] = channelData[0][i]
            }
        }
        
        // Calculate onset strength using spectral flux
        let hopSize = 512
        let windowSize = 2048
        let frameCount = (frameLength - windowSize) / hopSize
        guard frameCount > 0 else { return [] }
        
        var onsetStrength = [Float](repeating: 0, count: frameCount)
        var previousEnergy: Float = 0.0
        
        for frame in 0..<frameCount {
            let startIdx = frame * hopSize
            
            // Calculate frame energy
            var energy: Float = 0.0
            for i in 0..<windowSize {
                if startIdx + i < frameLength {
                    energy += mono[startIdx + i] * mono[startIdx + i]
                }
            }
            energy = sqrt(energy / Float(windowSize))
            
            // Onset = positive energy difference (half-wave rectified)
            let diff = energy - previousEnergy
            onsetStrength[frame] = max(0, diff)
            previousEnergy = energy
        }
        
        // Find peaks in onset strength
        var onsets: [Int] = []
        let threshold = calculateAdaptiveThreshold(onsetStrength)
        let minOnsetDistanceSamples = Int(0.05 * sampleRate) // Min 50ms between onsets in samples
        
        for i in 1..<(onsetStrength.count - 1) {
            if onsetStrength[i] > onsetStrength[i-1] &&
               onsetStrength[i] > onsetStrength[i+1] &&
               onsetStrength[i] > threshold {
                let samplePosition = i * hopSize
                
                // Check minimum distance from last onset (in samples)
                if onsets.isEmpty || (samplePosition - onsets.last!) >= minOnsetDistanceSamples {
                    onsets.append(samplePosition)
                }
            }
        }
        
        return onsets
    }
    
    /// Calculates adaptive threshold for onset detection
    private func calculateAdaptiveThreshold(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0.0 }
        
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let mad = values.map { abs($0 - median) }.sorted()[values.count / 2]
        
        return median + 1.5 * mad
    }
    
    /// Estimates tempo from onset positions
    private func estimateTempo(from onsets: [Int]) -> Double? {
        guard onsets.count >= 3 else { return nil }
        
        // Calculate inter-onset intervals
        var intervals: [Int] = []
        for i in 1..<onsets.count {
            intervals.append(onsets[i] - onsets[i-1])
        }
        
        guard !intervals.isEmpty else { return nil }
        
        // Find most common interval (histogram approach)
        let sortedIntervals = intervals.sorted()
        let medianInterval = sortedIntervals[sortedIntervals.count / 2]
        
        // Convert to BPM
        let secondsPerBeat = Double(medianInterval) / sampleRate
        guard secondsPerBeat > 0 else { return nil }
        
        var bpm = 60.0 / secondsPerBeat
        
        // Adjust to reasonable range (60-180 BPM)
        while bpm < 60 { bpm *= 2 }
        while bpm > 180 { bpm /= 2 }
        
        return bpm
    }
    
    /// Finds the nearest onset position to a given sample position
    private func findNearestOnset(to position: Int, in onsets: [Int]) -> Int? {
        guard !onsets.isEmpty else { return nil }
        
        var nearestOnset = onsets[0]
        var nearestDistance = abs(position - onsets[0])
        
        for onset in onsets {
            let distance = abs(position - onset)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestOnset = onset
            }
        }
        
        return nearestOnset
    }
    
    // MARK: - Public API
    
    /// Loads a source audio buffer for granular synthesis with onset detection
    func loadSourceBuffer(_ buffer: AVAudioPCMBuffer, identifier: String) {
        // Detect onsets for rhythm alignment
        let onsets = detectOnsets(in: buffer)
        let tempo = estimateTempo(from: onsets)
        
        let sourceInfo = SourceBufferInfo(
            identifier: identifier,
            buffer: buffer,
            onsets: onsets,
            tempo: tempo
        )
        
        sourceBuffersLock.lock()
        // Remove existing buffer with same identifier
        sourceBuffers.removeAll { $0.identifier == identifier }
        sourceBuffers.append(sourceInfo)
        sourceBuffersLock.unlock()
        
        #if DEBUG
        print("[GranularSynth] Loaded '\(identifier)': \(onsets.count) onsets, tempo: \(tempo.map { String(format: "%.1f BPM", $0) } ?? "unknown")")
        #endif
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
