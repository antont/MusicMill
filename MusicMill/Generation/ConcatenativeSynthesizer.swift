import Foundation
import AVFoundation
import Accelerate

/// Concatenative synthesizer that plays longer coherent segments (2-8 seconds)
/// with intelligent crossfading based on spectral similarity and beat alignment.
/// 
/// Unlike granular synthesis which chops audio into tiny grains (10-100ms),
/// concatenative synthesis maintains musical continuity by using full phrases.
class ConcatenativeSynthesizer {
    
    // MARK: - Types
    
    struct Segment {
        let identifier: String
        let buffer: AVAudioPCMBuffer
        let features: FeatureExtractor.AudioFeatures
        let style: String?
    }
    
    struct PlaybackState {
        var currentSegment: Segment?
        var nextSegment: Segment?
        var playbackPosition: Int = 0 // Sample position in current segment
        var crossfadeProgress: Float = 0.0 // 0 = current only, 1 = next only
        var isCrossfading: Bool = false
    }
    
    struct Parameters {
        var crossfadeDuration: TimeInterval = 0.5 // Crossfade length in seconds
        var minSegmentDuration: TimeInterval = 2.0 // Minimum segment length
        var maxSegmentDuration: TimeInterval = 8.0 // Maximum segment length
        var similarityThreshold: Float = 0.5 // Minimum similarity for segment matching
        var beatAlign: Bool = true // Align crossfades to beats
        var masterVolume: Float = 1.0
    }
    
    // MARK: - Properties
    
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double = 44100.0
    
    private var segments: [Segment] = []
    private var state = PlaybackState()
    private var parameters = Parameters()
    
    private let stateL = NSLock()
    private var isPlaying = false
    
    private let featureExtractor = FeatureExtractor()
    
    // MARK: - Initialization
    
    init() {
        setupAudioEngine()
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
    
    // MARK: - Public Interface
    
    /// Loads a segment from a file
    func loadSegment(from url: URL, identifier: String, style: String? = nil) async throws {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ConcatenativeError.bufferCreationFailed
        }
        
        try file.read(into: buffer)
        
        // Extract features for similarity matching
        let features = featureExtractor.extractFeatures(from: buffer)
        
        let segment = Segment(
            identifier: identifier,
            buffer: buffer,
            features: features,
            style: style
        )
        
        stateL.lock()
        segments.append(segment)
        stateL.unlock()
    }
    
    /// Loads a segment from a buffer
    func loadSegment(from buffer: AVAudioPCMBuffer, identifier: String, style: String? = nil) {
        let features = featureExtractor.extractFeatures(from: buffer)
        
        let segment = Segment(
            identifier: identifier,
            buffer: buffer,
            features: features,
            style: style
        )
        
        stateL.lock()
        segments.append(segment)
        stateL.unlock()
    }
    
    /// Starts playback
    func start() throws {
        stateL.lock()
        guard !segments.isEmpty else {
            stateL.unlock()
            throw ConcatenativeError.noSegmentsLoaded
        }
        
        // Start with first segment
        if state.currentSegment == nil {
            state.currentSegment = segments.first
            state.playbackPosition = 0
        }
        
        // Pre-select next segment
        if state.nextSegment == nil, let current = state.currentSegment {
            state.nextSegment = selectNextSegment(after: current)
        }
        stateL.unlock()
        
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        isPlaying = true
    }
    
    /// Stops playback
    func stop() {
        isPlaying = false
        audioEngine.stop()
    }
    
    /// Updates synthesis parameters
    func setParameters(_ params: Parameters) {
        stateL.lock()
        parameters = params
        stateL.unlock()
    }
    
    /// Gets loaded segment count
    func getSegmentCount() -> Int {
        stateL.lock()
        defer { stateL.unlock() }
        return segments.count
    }
    
    /// Gets audio engine for external connections
    func getAudioEngine() -> AVAudioEngine {
        return audioEngine
    }
    
    // MARK: - Segment Selection
    
    /// Selects the next segment based on spectral similarity
    private func selectNextSegment(after current: Segment, targetStyle: String? = nil) -> Segment? {
        stateL.lock()
        defer { stateL.unlock() }
        
        guard segments.count > 1 else { return segments.first }
        
        // Find best matching segment
        var bestSegment: Segment?
        var bestScore: Float = -Float.infinity
        
        for candidate in segments {
            // Skip current segment
            if candidate.identifier == current.identifier { continue }
            
            // Skip if style doesn't match (when specified)
            if let style = targetStyle, candidate.style != style { continue }
            
            // Calculate similarity score
            let similarity = calculateSimilarity(from: current, to: candidate)
            
            // Prefer segments with compatible tempo
            var score = similarity
            if let currentTempo = current.features.tempo, let candidateTempo = candidate.features.tempo {
                let tempoRatio = min(currentTempo, candidateTempo) / max(currentTempo, candidateTempo)
                score *= Float(tempoRatio)
            }
            
            // Add some randomness to avoid always picking same segment
            score *= Float.random(in: 0.8...1.2)
            
            if score > bestScore && similarity >= parameters.similarityThreshold {
                bestScore = score
                bestSegment = candidate
            }
        }
        
        // Fallback to random if no good match
        if bestSegment == nil {
            let candidates = segments.filter { $0.identifier != current.identifier }
            if !candidates.isEmpty {
                bestSegment = candidates.randomElement()
            }
        }
        
        return bestSegment
    }
    
    /// Calculates similarity between two segments using spectral embeddings
    private func calculateSimilarity(from: Segment, to: Segment) -> Float {
        // Use end spectrum of 'from' and start spectrum of 'to'
        // This ensures smooth crossfade transition
        let endProfile = from.features.endSpectrum
        let startProfile = to.features.startSpectrum
        
        guard !endProfile.isEmpty && !startProfile.isEmpty else {
            // Fall back to embedding similarity
            return cosineSimilarity(from.features.spectralEmbedding, to.features.spectralEmbedding)
        }
        
        // Combine embedding similarity and transition compatibility
        let embeddingSimilarity = cosineSimilarity(
            from.features.spectralEmbedding,
            to.features.spectralEmbedding
        )
        let transitionCompatibility = cosineSimilarity(endProfile, startProfile)
        
        return 0.5 * embeddingSimilarity + 0.5 * transitionCompatibility
    }
    
    /// Computes cosine similarity between two vectors
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count && !a.isEmpty else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        
        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }
    
    // MARK: - Audio Rendering
    
    private func renderAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard isPlaying else {
            // Fill with silence
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
        
        stateL.lock()
        defer { stateL.unlock() }
        
        guard let currentSegment = state.currentSegment,
              let currentBuffer = currentSegment.buffer.floatChannelData else {
            // Fill with silence
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard ablPointer.count >= 2 else { return noErr }
        
        let leftOut = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let rightOut = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        let currentLength = Int(currentSegment.buffer.frameLength)
        let crossfadeSamples = Int(parameters.crossfadeDuration * sampleRate)
        let crossfadeStartPosition = max(0, currentLength - crossfadeSamples)
        
        for sample in 0..<Int(frameCount) {
            var leftSample: Float = 0
            var rightSample: Float = 0
            
            // Check if we should start crossfading
            if state.playbackPosition >= crossfadeStartPosition && !state.isCrossfading {
                state.isCrossfading = true
                state.crossfadeProgress = 0
                
                // Ensure we have a next segment
                if state.nextSegment == nil {
                    state.nextSegment = selectNextSegment(after: currentSegment)
                }
            }
            
            // Get samples from current segment
            if state.playbackPosition < currentLength {
                let channelCount = Int(currentSegment.buffer.format.channelCount)
                if channelCount >= 2 {
                    leftSample = currentBuffer[0][state.playbackPosition]
                    rightSample = currentBuffer[1][state.playbackPosition]
                } else {
                    leftSample = currentBuffer[0][state.playbackPosition]
                    rightSample = leftSample
                }
            }
            
            // Apply crossfade if active
            if state.isCrossfading, let nextSegment = state.nextSegment,
               let nextBuffer = nextSegment.buffer.floatChannelData {
                
                let nextLength = Int(nextSegment.buffer.frameLength)
                let nextPosition = Int(state.crossfadeProgress * Float(crossfadeSamples))
                
                if nextPosition < nextLength {
                    let nextChannelCount = Int(nextSegment.buffer.format.channelCount)
                    var nextLeft: Float = 0
                    var nextRight: Float = 0
                    
                    if nextChannelCount >= 2 {
                        nextLeft = nextBuffer[0][nextPosition]
                        nextRight = nextBuffer[1][nextPosition]
                    } else {
                        nextLeft = nextBuffer[0][nextPosition]
                        nextRight = nextLeft
                    }
                    
                    // Equal-power crossfade
                    let fadeOut = cos(state.crossfadeProgress * Float.pi / 2)
                    let fadeIn = sin(state.crossfadeProgress * Float.pi / 2)
                    
                    leftSample = leftSample * fadeOut + nextLeft * fadeIn
                    rightSample = rightSample * fadeOut + nextRight * fadeIn
                    
                    // Update crossfade progress
                    state.crossfadeProgress += 1.0 / Float(crossfadeSamples)
                }
                
                // Check if crossfade is complete
                if state.crossfadeProgress >= 1.0 {
                    // Transition to next segment
                    state.currentSegment = nextSegment
                    state.playbackPosition = Int(Float(crossfadeSamples) * state.crossfadeProgress)
                    state.nextSegment = selectNextSegment(after: nextSegment)
                    state.isCrossfading = false
                    state.crossfadeProgress = 0
                }
            }
            
            // Apply master volume
            leftSample *= parameters.masterVolume
            rightSample *= parameters.masterVolume
            
            // Write output
            leftOut?[sample] = leftSample
            rightOut?[sample] = rightSample
            
            state.playbackPosition += 1
            
            // Handle end of current segment without next
            if state.playbackPosition >= currentLength && state.nextSegment == nil {
                // Loop back to start of current segment
                state.playbackPosition = 0
            }
        }
        
        return noErr
    }
    
    // MARK: - Errors
    
    enum ConcatenativeError: LocalizedError {
        case bufferCreationFailed
        case noSegmentsLoaded
        case audioEngineError
        
        var errorDescription: String? {
            switch self {
            case .bufferCreationFailed:
                return "Failed to create audio buffer"
            case .noSegmentsLoaded:
                return "No segments loaded for playback"
            case .audioEngineError:
                return "Audio engine error"
            }
        }
    }
}


