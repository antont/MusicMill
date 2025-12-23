import Foundation
import AVFoundation
import Accelerate

/// PhrasePlayer: Beat-aligned musical segment playback
///
/// Unlike granular synthesis which chops audio into tiny grains,
/// PhrasePlayer maintains musical continuity by:
/// - Playing full phrases (8-30 seconds)
/// - Crossfading only on beat boundaries (downbeats)
/// - Matching segments by energy/style for natural flow
/// - Using beat grids from librosa analysis
class PhrasePlayer {
    
    // MARK: - Types
    
    struct Phrase {
        let id: String
        let buffer: AVAudioPCMBuffer
        let beats: [TimeInterval]       // Beat positions within this phrase
        let downbeats: [TimeInterval]   // Bar boundaries (every 4 beats)
        let tempo: Double
        let energy: Double
        let segmentType: String         // intro, verse, chorus, etc.
        let style: String?
    }
    
    struct PlaybackState {
        var currentPhrase: Phrase?
        var nextPhrase: Phrase?
        var playbackPosition: Int = 0   // Sample position in current phrase
        var crossfadeProgress: Float = 0.0
        var isCrossfading: Bool = false
        var crossfadeStartSample: Int = 0
        var crossfadeLengthSamples: Int = 0
    }
    
    struct Parameters {
        var crossfadeBars: Int = 2              // Crossfade over N musical bars
        var minPhraseDuration: TimeInterval = 8.0
        var maxPhraseDuration: TimeInterval = 30.0
        var energyMatchWeight: Float = 0.5      // How much to weight energy matching
        var styleMatchWeight: Float = 0.8       // How much to weight style matching
        var masterVolume: Float = 1.0
        var targetTempo: Double? = nil          // Optional tempo target for matching
        var targetEnergy: Double? = nil         // Optional energy target
        var targetStyle: String? = nil          // Optional style filter
    }
    
    // MARK: - Properties
    
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double = 44100.0
    
    private var phrases: [Phrase] = []
    private var state = PlaybackState()
    private var _parameters = Parameters()
    private let stateLock = NSLock()
    private let parametersLock = NSLock()
    private var isPlaying = false
    
    var parameters: Parameters {
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
        audioEngine.prepare()
    }
    
    // MARK: - Public Interface
    
    /// Loads a phrase from audio buffer with beat/phrase analysis
    func loadPhrase(
        id: String,
        buffer: AVAudioPCMBuffer,
        beats: [TimeInterval],
        downbeats: [TimeInterval],
        tempo: Double,
        energy: Double,
        segmentType: String,
        style: String?
    ) {
        let phrase = Phrase(
            id: id,
            buffer: buffer,
            beats: beats,
            downbeats: downbeats,
            tempo: tempo,
            energy: energy,
            segmentType: segmentType,
            style: style
        )
        
        stateLock.lock()
        phrases.append(phrase)
        stateLock.unlock()
        
        #if DEBUG
        print("[PhrasePlayer] Loaded '\(id)': \(tempo)BPM, \(segmentType), \(beats.count) beats")
        #endif
    }
    
    /// Loads a phrase from a URL with analysis data
    func loadPhrase(
        from url: URL,
        id: String,
        analysis: AnalysisStorage.AudioFeaturesInfo
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PhraseError.bufferCreationFailed
        }
        
        try file.read(into: buffer)
        
        // Extract beat info relative to this segment
        let segmentBeats = analysis.beats ?? []
        let segmentDownbeats = analysis.downbeats ?? []
        
        // Get segment type from first segment or default
        let segmentType = analysis.segments?.first?.type ?? "verse"
        
        loadPhrase(
            id: id,
            buffer: buffer,
            beats: segmentBeats,
            downbeats: segmentDownbeats,
            tempo: analysis.tempo ?? 120.0,
            energy: analysis.energy,
            segmentType: segmentType,
            style: nil
        )
    }
    
    /// Starts playback
    func start() throws {
        stateLock.lock()
        guard !phrases.isEmpty else {
            stateLock.unlock()
            throw PhraseError.noPhrasesLoaded
        }
        
        // Start with best matching phrase
        if state.currentPhrase == nil {
            state.currentPhrase = selectBestPhrase(afterType: nil)
            state.playbackPosition = 0
        }
        
        // Pre-select next phrase
        if state.nextPhrase == nil, let current = state.currentPhrase {
            state.nextPhrase = selectNextPhrase(after: current)
        }
        stateLock.unlock()
        
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
    
    /// Gets phrase count
    var phraseCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return phrases.count
    }
    
    // MARK: - Phrase Selection
    
    /// Selects the best initial phrase based on parameters
    private func selectBestPhrase(afterType: String?) -> Phrase? {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard !phrases.isEmpty else { return nil }
        
        parametersLock.lock()
        let params = _parameters
        parametersLock.unlock()
        
        var candidates = phrases
        
        // Filter by style if specified
        if let style = params.targetStyle {
            let styleCandidates = candidates.filter { $0.style == style }
            if !styleCandidates.isEmpty {
                candidates = styleCandidates
            }
        }
        
        // Score candidates
        var bestPhrase: Phrase?
        var bestScore: Float = -Float.infinity
        
        for phrase in candidates {
            var score: Float = 0
            
            // Tempo matching
            if let targetTempo = params.targetTempo {
                let tempoRatio = min(phrase.tempo, targetTempo) / max(phrase.tempo, targetTempo)
                score += Float(tempoRatio) * 0.3
            }
            
            // Energy matching
            if let targetEnergy = params.targetEnergy {
                let energyDiff = abs(phrase.energy - targetEnergy)
                score += (1.0 - Float(energyDiff)) * params.energyMatchWeight
            }
            
            // Prefer intros at start
            if afterType == nil && phrase.segmentType == "intro" {
                score += 0.5
            }
            
            // Add randomness
            score += Float.random(in: 0...0.2)
            
            if score > bestScore {
                bestScore = score
                bestPhrase = phrase
            }
        }
        
        return bestPhrase ?? phrases.first
    }
    
    /// Selects the next phrase to play after the current one
    private func selectNextPhrase(after current: Phrase) -> Phrase? {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard phrases.count > 1 else { return phrases.first }
        
        parametersLock.lock()
        let params = _parameters
        parametersLock.unlock()
        
        var bestPhrase: Phrase?
        var bestScore: Float = -Float.infinity
        
        for candidate in phrases {
            // Skip current phrase
            if candidate.id == current.id { continue }
            
            var score: Float = 0
            
            // Style matching
            if let style = params.targetStyle {
                if candidate.style == style {
                    score += params.styleMatchWeight
                }
            } else if candidate.style == current.style {
                score += params.styleMatchWeight * 0.5
            }
            
            // Energy continuity (prefer similar or slightly different)
            let energyDiff = abs(candidate.energy - current.energy)
            score += (1.0 - Float(energyDiff)) * params.energyMatchWeight
            
            // Tempo compatibility (within 20%)
            let tempoRatio = min(candidate.tempo, current.tempo) / max(candidate.tempo, current.tempo)
            if tempoRatio >= 0.8 {
                score += Float(tempoRatio) * 0.3
            } else {
                score -= 0.5 // Penalize large tempo changes
            }
            
            // Segment type flow (musical progression)
            score += segmentTypeFlowScore(from: current.segmentType, to: candidate.segmentType)
            
            // Add randomness
            score += Float.random(in: 0...0.3)
            
            if score > bestScore {
                bestScore = score
                bestPhrase = candidate
            }
        }
        
        return bestPhrase ?? phrases.first
    }
    
    /// Scores how well one segment type flows into another
    private func segmentTypeFlowScore(from: String, to: String) -> Float {
        // Natural flow patterns in electronic music
        let flows: [String: [String: Float]] = [
            "intro": ["verse": 0.8, "breakdown": 0.6, "intro": 0.2],
            "verse": ["chorus": 0.9, "breakdown": 0.6, "verse": 0.4, "drop": 0.7],
            "chorus": ["verse": 0.6, "breakdown": 0.8, "drop": 0.9, "chorus": 0.3],
            "breakdown": ["drop": 0.95, "chorus": 0.7, "verse": 0.5],
            "drop": ["breakdown": 0.7, "verse": 0.5, "chorus": 0.4, "drop": 0.3],
            "outro": ["outro": 0.2]
        ]
        
        return flows[from]?[to] ?? 0.2
    }
    
    /// Finds the next downbeat position in the current phrase
    private func findNextDownbeat(afterSample: Int, in phrase: Phrase) -> Int? {
        let afterTime = Double(afterSample) / sampleRate
        
        for downbeat in phrase.downbeats {
            if downbeat > afterTime {
                return Int(downbeat * sampleRate)
            }
        }
        
        return nil
    }
    
    // MARK: - Audio Rendering
    
    private func renderAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard isPlaying else {
            fillSilence(audioBufferList: audioBufferList, frameCount: frameCount)
            return noErr
        }
        
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard let currentPhrase = state.currentPhrase,
              let currentBuffer = currentPhrase.buffer.floatChannelData else {
            fillSilence(audioBufferList: audioBufferList, frameCount: frameCount)
            return noErr
        }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard ablPointer.count >= 2 else { return noErr }
        
        let leftOut = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let rightOut = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        let currentLength = Int(currentPhrase.buffer.frameLength)
        
        parametersLock.lock()
        let params = _parameters
        parametersLock.unlock()
        
        // Calculate crossfade length from bars
        let beatsPerBar = 4
        let secondsPerBeat = 60.0 / currentPhrase.tempo
        let crossfadeSeconds = Double(params.crossfadeBars * beatsPerBar) * secondsPerBeat
        let crossfadeSamples = Int(crossfadeSeconds * sampleRate)
        
        // Determine when to start crossfading (at a downbeat near the end)
        let crossfadeStartThreshold = currentLength - crossfadeSamples * 2
        
        for sample in 0..<Int(frameCount) {
            var leftSample: Float = 0
            var rightSample: Float = 0
            
            // Check if we should start crossfading
            if !state.isCrossfading && state.playbackPosition >= crossfadeStartThreshold {
                // Find next downbeat to start crossfade
                if let nextDownbeat = findNextDownbeat(afterSample: state.playbackPosition, in: currentPhrase) {
                    state.isCrossfading = true
                    state.crossfadeStartSample = nextDownbeat
                    state.crossfadeLengthSamples = crossfadeSamples
                    state.crossfadeProgress = 0
                    
                    // Ensure next phrase is ready
                    if state.nextPhrase == nil {
                        state.nextPhrase = selectNextPhrase(after: currentPhrase)
                    }
                }
            }
            
            // Get sample from current phrase
            if state.playbackPosition < currentLength {
                let channelCount = Int(currentPhrase.buffer.format.channelCount)
                if channelCount >= 2 {
                    leftSample = currentBuffer[0][state.playbackPosition]
                    rightSample = currentBuffer[1][state.playbackPosition]
                } else {
                    leftSample = currentBuffer[0][state.playbackPosition]
                    rightSample = leftSample
                }
            }
            
            // Apply crossfade if active
            if state.isCrossfading,
               state.playbackPosition >= state.crossfadeStartSample,
               let nextPhrase = state.nextPhrase,
               let nextBuffer = nextPhrase.buffer.floatChannelData {
                
                let crossfadePosition = state.playbackPosition - state.crossfadeStartSample
                let nextPosition = crossfadePosition // Start next phrase at beginning during crossfade
                let nextLength = Int(nextPhrase.buffer.frameLength)
                
                if nextPosition >= 0 && nextPosition < nextLength && crossfadePosition < state.crossfadeLengthSamples {
                    // Get next phrase sample
                    let nextChannelCount = Int(nextPhrase.buffer.format.channelCount)
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
                    let progress = Float(crossfadePosition) / Float(state.crossfadeLengthSamples)
                    let fadeOut = cos(progress * Float.pi / 2)
                    let fadeIn = sin(progress * Float.pi / 2)
                    
                    leftSample = leftSample * fadeOut + nextLeft * fadeIn
                    rightSample = rightSample * fadeOut + nextRight * fadeIn
                    
                    state.crossfadeProgress = progress
                }
                
                // Check if crossfade is complete
                if crossfadePosition >= state.crossfadeLengthSamples {
                    // Transition to next phrase
                    state.currentPhrase = nextPhrase
                    state.playbackPosition = state.crossfadeLengthSamples
                    state.nextPhrase = selectNextPhrase(after: nextPhrase)
                    state.isCrossfading = false
                    state.crossfadeProgress = 0
                    continue
                }
            }
            
            // Apply master volume
            leftSample *= params.masterVolume
            rightSample *= params.masterVolume
            
            // Write output
            leftOut?[sample] = leftSample
            rightOut?[sample] = rightSample
            
            state.playbackPosition += 1
            
            // Handle end of phrase without crossfade
            if state.playbackPosition >= currentLength && !state.isCrossfading {
                if let next = state.nextPhrase {
                    state.currentPhrase = next
                    state.playbackPosition = 0
                    state.nextPhrase = selectNextPhrase(after: next)
                } else {
                    // Loop current phrase
                    state.playbackPosition = 0
                }
            }
        }
        
        return noErr
    }
    
    private func fillSilence(audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in ablPointer {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
    }
    
    // MARK: - Errors
    
    enum PhraseError: LocalizedError {
        case noPhrasesLoaded
        case bufferCreationFailed
        
        var errorDescription: String? {
            switch self {
            case .noPhrasesLoaded:
                return "No phrases loaded for playback"
            case .bufferCreationFailed:
                return "Failed to create audio buffer"
            }
        }
    }
}

