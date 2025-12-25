import Foundation
import AVFoundation
import Combine

/// HyperPhrasePlayer - Graph-aware musical phrase playback
///
/// Navigates through a phrase graph, allowing smooth DJ-style transitions
/// between phrases from different songs based on musical compatibility.
class HyperPhrasePlayer: ObservableObject {
    
    // MARK: - Types
    
    struct PlaybackState {
        var currentPhrase: PhraseNode?
        var nextPhrase: PhraseNode?
        var playbackPosition: Int = 0       // Sample position in current phrase
        var isTransitioning: Bool = false
        var transitionProgress: Float = 0.0
    }
    
    struct Settings {
        var masterVolume: Float = 1.0
        var transitionBars: Int = 2         // Bars for transition
        var autoAdvance: Bool = true        // Automatically select next phrase
        var preferSameTrack: Bool = false   // Prefer staying on same track
    }
    
    // MARK: - Published Properties (for UI)
    
    @Published private(set) var currentPhrase: PhraseNode?
    @Published private(set) var nextPhrase: PhraseNode?
    @Published private(set) var availableLinks: [PhraseLink] = []
    @Published private(set) var alternativePhrases: [PhraseNode] = []
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var transitionProgress: Float = 0.0
    @Published private(set) var loadingError: String?
    
    // MARK: - Properties
    
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double = 44100.0
    
    private let database = PhraseDatabase()
    private let transitionEngine = TransitionEngine()
    
    private var state = PlaybackState()
    private var settings = Settings()
    private let stateLock = NSLock()
    
    // Audio buffers for current and next phrases
    private var currentBuffer: AVAudioPCMBuffer?
    private var nextBuffer: AVAudioPCMBuffer?
    
    // Transition mixing buffers
    private var transitionOutLeft: [Float] = []
    private var transitionOutRight: [Float] = []
    private var transitionInLeft: [Float] = []
    private var transitionInRight: [Float] = []
    
    // MARK: - Initialization
    
    init() {
        setupAudioEngine()
        setupTransitionEngine()
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
    
    private func setupTransitionEngine() {
        transitionEngine.setProgressCallback { [weak self] progress in
            DispatchQueue.main.async {
                self?.transitionProgress = progress
            }
        }
    }
    
    // MARK: - Graph Loading
    
    /// Load the phrase graph from disk
    func loadGraph() throws {
        try database.load()
        
        #if DEBUG
        print("[HyperPhrasePlayer] Loaded graph: \(database.nodeCount) nodes, \(database.linkCount) links")
        #endif
        
        // Select initial phrase
        if let startPhrase = database.getRandomStart() {
            selectPhrase(startPhrase)
        }
    }
    
    /// Check if graph is loaded
    var hasGraph: Bool {
        database.hasGraph
    }
    
    /// Get graph statistics
    var graphStats: (nodes: Int, links: Int, tracks: Int) {
        (database.nodeCount, database.linkCount, database.trackCount)
    }
    
    // MARK: - Phrase Selection
    
    /// Select a phrase to play
    func selectPhrase(_ phrase: PhraseNode) {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        state.currentPhrase = phrase
        state.playbackPosition = 0
        state.isTransitioning = false
        
        // Load audio buffer
        loadBuffer(for: phrase) { [weak self] buffer in
            self?.stateLock.lock()
            self?.currentBuffer = buffer
            self?.stateLock.unlock()
        }
        
        // Update available links
        let links = database.getLinks(for: phrase.id)
        let alternatives = database.getAlternatives(for: phrase.id, limit: 8)
        
        // Auto-select next phrase if enabled
        let next: PhraseNode?
        if settings.preferSameTrack, let seqNext = database.getNextInSequence(for: phrase.id) {
            next = seqNext
        } else {
            next = links.first.flatMap { database.getPhrase(id: $0.targetId) }
        }
        
        if let nextPhrase = next {
            state.nextPhrase = nextPhrase
            loadBuffer(for: nextPhrase) { [weak self] buffer in
                self?.stateLock.lock()
                self?.nextBuffer = buffer
                self?.stateLock.unlock()
            }
        }
        
        // Update published properties
        DispatchQueue.main.async {
            self.currentPhrase = phrase
            self.nextPhrase = next
            self.availableLinks = links
            self.alternativePhrases = alternatives
        }
    }
    
    /// Queue a specific phrase as next (user selection)
    func queueNext(_ phrase: PhraseNode) {
        stateLock.lock()
        state.nextPhrase = phrase
        stateLock.unlock()
        
        // Load buffer
        loadBuffer(for: phrase) { [weak self] buffer in
            self?.stateLock.lock()
            self?.nextBuffer = buffer
            self?.stateLock.unlock()
        }
        
        DispatchQueue.main.async {
            self.nextPhrase = phrase
        }
    }
    
    /// Queue a phrase by ID
    func queueNext(id: String) {
        guard let phrase = database.getPhrase(id: id) else { return }
        queueNext(phrase)
    }
    
    /// Get phrases with higher energy
    func getHigherEnergyPhrases(limit: Int = 5) -> [PhraseNode] {
        guard let current = currentPhrase else { return [] }
        return database.getPhrasesSortedByEnergy(around: current.id, higherEnergy: true, limit: limit)
    }
    
    /// Get phrases with lower energy
    func getLowerEnergyPhrases(limit: Int = 5) -> [PhraseNode] {
        guard let current = currentPhrase else { return [] }
        return database.getPhrasesSortedByEnergy(around: current.id, higherEnergy: false, limit: limit)
    }
    
    /// Get the next phrase in the original song sequence
    func getNextInSequence() -> PhraseNode? {
        guard let current = currentPhrase else { return nil }
        return database.getNextInSequence(for: current.id)
    }
    
    /// Get all phrases from the current track (in order)
    func getCurrentTrackPhrases() -> [PhraseNode] {
        guard let current = currentPhrase else { return [] }
        return database.getPhrasesForTrack(current.sourceTrack)
    }
    
    /// Get branch options for a specific phrase (alternatives from other tracks)
    func getBranchOptions(for phrase: PhraseNode, limit: Int = 5) -> [PhraseNode] {
        let links = database.getLinks(for: phrase.id)
        return links
            .filter { !$0.isOriginalSequence }  // Exclude same-track sequence
            .prefix(limit)
            .compactMap { database.getPhrase(id: $0.targetId) }
    }
    
    // MARK: - Playback Control
    
    /// Start playback
    func start() throws {
        guard currentBuffer != nil else {
            throw HyperPlayerError.noPhrasesLoaded
        }
        
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        
        isPlaying = true
    }
    
    /// Stop playback
    func stop() {
        isPlaying = false
        audioEngine.stop()
    }
    
    /// Trigger transition to next phrase now
    func triggerTransition() {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard state.nextPhrase != nil, nextBuffer != nil else { return }
        
        state.isTransitioning = true
        
        // Configure transition
        var config = TransitionEngine.TransitionConfig()
        config.tempo = state.currentPhrase?.tempo ?? 120.0
        config.durationBars = settings.transitionBars
        
        // Use suggested transition type from link if available
        if let currentId = state.currentPhrase?.id,
           let nextId = state.nextPhrase?.id,
           let link = database.getLinks(for: currentId).first(where: { $0.targetId == nextId }) {
            // Convert PhraseLink's TransitionType to TransitionEngine.TransitionType
            switch link.suggestedTransition {
            case .crossfade: config.type = .crossfade
            case .eqSwap: config.type = .eqSwap
            case .filter: config.type = .filter
            case .cut: config.type = .cut
            }
        }
        
        transitionEngine.configure(config)
        transitionEngine.start()
        
        // Prepare transition buffers
        let bufferSize = 4096
        transitionOutLeft = [Float](repeating: 0, count: bufferSize)
        transitionOutRight = [Float](repeating: 0, count: bufferSize)
        transitionInLeft = [Float](repeating: 0, count: bufferSize)
        transitionInRight = [Float](repeating: 0, count: bufferSize)
    }
    
    // MARK: - Settings
    
    func setMasterVolume(_ volume: Float) {
        settings.masterVolume = volume
    }
    
    func setTransitionBars(_ bars: Int) {
        settings.transitionBars = max(1, min(8, bars))
    }
    
    func setAutoAdvance(_ enabled: Bool) {
        settings.autoAdvance = enabled
    }
    
    func setPreferSameTrack(_ prefer: Bool) {
        settings.preferSameTrack = prefer
    }
    
    // MARK: - Audio Rendering
    
    private func renderAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard isPlaying else {
            fillSilence(audioBufferList: audioBufferList, frameCount: frameCount)
            return noErr
        }
        
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard let buffer = currentBuffer,
              let channelData = buffer.floatChannelData else {
            fillSilence(audioBufferList: audioBufferList, frameCount: frameCount)
            return noErr
        }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard ablPointer.count >= 2 else { return noErr }
        
        let leftOut = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let rightOut = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        let bufferLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        if state.isTransitioning, let nextBuf = nextBuffer, let nextChannelData = nextBuf.floatChannelData {
            // Transitioning between phrases
            renderTransition(
                frameCount: Int(frameCount),
                currentBuffer: channelData,
                currentLength: bufferLength,
                currentChannels: channelCount,
                nextBuffer: nextChannelData,
                nextLength: Int(nextBuf.frameLength),
                nextChannels: Int(nextBuf.format.channelCount),
                leftOut: leftOut,
                rightOut: rightOut
            )
        } else {
            // Normal playback
            for i in 0..<Int(frameCount) {
                if state.playbackPosition < bufferLength {
                    let leftSample: Float
                    let rightSample: Float
                    
                    if channelCount >= 2 {
                        leftSample = channelData[0][state.playbackPosition]
                        rightSample = channelData[1][state.playbackPosition]
                    } else {
                        leftSample = channelData[0][state.playbackPosition]
                        rightSample = leftSample
                    }
                    
                    leftOut?[i] = leftSample * settings.masterVolume
                    rightOut?[i] = rightSample * settings.masterVolume
                    state.playbackPosition += 1
                } else {
                    // End of current phrase
                    if settings.autoAdvance && state.nextPhrase != nil && nextBuffer != nil {
                        // Check if this is a sequential same-track transition
                        let isSequential = isSequentialTransition()
                        
                        if isSequential {
                            // Seamless gapless transition - just swap and continue
                            completeGaplessTransition()
                            // Continue playing from the new buffer at position 0
                            if let newChannelData = currentBuffer?.floatChannelData,
                               Int(currentBuffer?.frameLength ?? 0) > 0 {
                                let newChannelCount = Int(currentBuffer?.format.channelCount ?? 1)
                                if newChannelCount >= 2 {
                                    leftOut?[i] = newChannelData[0][0] * settings.masterVolume
                                    rightOut?[i] = newChannelData[1][0] * settings.masterVolume
                                } else {
                                    let sample = newChannelData[0][0] * settings.masterVolume
                                    leftOut?[i] = sample
                                    rightOut?[i] = sample
                                }
                                state.playbackPosition = 1
                            } else {
                                leftOut?[i] = 0
                                rightOut?[i] = 0
                            }
                        } else {
                            // Cross-track or non-sequential: apply transition effect
                            state.isTransitioning = true
                            var config = TransitionEngine.TransitionConfig()
                            config.tempo = state.currentPhrase?.tempo ?? 120.0
                            config.durationBars = settings.transitionBars
                            transitionEngine.configure(config)
                            transitionEngine.start()
                            leftOut?[i] = 0
                            rightOut?[i] = 0
                        }
                    } else {
                        // Loop current phrase
                        state.playbackPosition = 0
                    }
                    
                    if !state.isTransitioning {
                        // Only output silence if we didn't handle it above
                    }
                }
            }
        }
        
        return noErr
    }
    
    private func renderTransition(
        frameCount: Int,
        currentBuffer: UnsafePointer<UnsafeMutablePointer<Float>>,
        currentLength: Int,
        currentChannels: Int,
        nextBuffer: UnsafePointer<UnsafeMutablePointer<Float>>,
        nextLength: Int,
        nextChannels: Int,
        leftOut: UnsafeMutablePointer<Float>?,
        rightOut: UnsafeMutablePointer<Float>?
    ) {
        // Ensure transition buffers are big enough
        if transitionOutLeft.count < frameCount {
            transitionOutLeft = [Float](repeating: 0, count: frameCount)
            transitionOutRight = [Float](repeating: 0, count: frameCount)
            transitionInLeft = [Float](repeating: 0, count: frameCount)
            transitionInRight = [Float](repeating: 0, count: frameCount)
        }
        
        // Fill outgoing buffers from current phrase
        for i in 0..<frameCount {
            let pos = state.playbackPosition + i
            if pos < currentLength {
                if currentChannels >= 2 {
                    transitionOutLeft[i] = currentBuffer[0][pos]
                    transitionOutRight[i] = currentBuffer[1][pos]
                } else {
                    transitionOutLeft[i] = currentBuffer[0][pos]
                    transitionOutRight[i] = transitionOutLeft[i]
                }
            } else {
                transitionOutLeft[i] = 0
                transitionOutRight[i] = 0
            }
        }
        
        // Fill incoming buffers from next phrase
        // Start from beginning of next phrase during transition
        let transitionPosition = max(0, state.playbackPosition - (currentLength - Int(transitionEngine.transitionDuration() * sampleRate)))
        
        for i in 0..<frameCount {
            let pos = transitionPosition + i
            if pos >= 0 && pos < nextLength {
                if nextChannels >= 2 {
                    transitionInLeft[i] = nextBuffer[0][pos]
                    transitionInRight[i] = nextBuffer[1][pos]
                } else {
                    transitionInLeft[i] = nextBuffer[0][pos]
                    transitionInRight[i] = transitionInLeft[i]
                }
            } else {
                transitionInLeft[i] = 0
                transitionInRight[i] = 0
            }
        }
        
        // Process transition
        transitionOutLeft.withUnsafeBufferPointer { outL in
            transitionOutRight.withUnsafeBufferPointer { outR in
                transitionInLeft.withUnsafeBufferPointer { inL in
                    transitionInRight.withUnsafeBufferPointer { inR in
                        if let leftOut = leftOut, let rightOut = rightOut {
                            transitionEngine.process(
                                outgoingLeft: outL.baseAddress!,
                                outgoingRight: outR.baseAddress!,
                                incomingLeft: inL.baseAddress!,
                                incomingRight: inR.baseAddress!,
                                outputLeft: leftOut,
                                outputRight: rightOut,
                                frameCount: frameCount
                            )
                            
                            // Apply master volume
                            for i in 0..<frameCount {
                                leftOut[i] *= settings.masterVolume
                                rightOut[i] *= settings.masterVolume
                            }
                        }
                    }
                }
            }
        }
        
        state.playbackPosition += frameCount
        
        // Check if transition is complete
        if transitionEngine.isComplete {
            completeTransition()
        }
    }
    
    private func completeTransition() {
        // Swap buffers
        currentBuffer = nextBuffer
        nextBuffer = nil
        
        // Update state
        if let next = state.nextPhrase {
            state.currentPhrase = next
            state.playbackPosition = Int(transitionEngine.transitionDuration() * sampleRate)
            
            // Select new next phrase
            let links = database.getLinks(for: next.id)
            let alternatives = database.getAlternatives(for: next.id, limit: 8)
            
            let newNext: PhraseNode?
            if settings.preferSameTrack, let seqNext = database.getNextInSequence(for: next.id) {
                newNext = seqNext
            } else {
                newNext = links.first.flatMap { database.getPhrase(id: $0.targetId) }
            }
            
            state.nextPhrase = newNext
            
            if let newNextPhrase = newNext {
                loadBuffer(for: newNextPhrase) { [weak self] buffer in
                    self?.stateLock.lock()
                    self?.nextBuffer = buffer
                    self?.stateLock.unlock()
                }
            }
            
            // Update published properties
            DispatchQueue.main.async {
                self.currentPhrase = next
                self.nextPhrase = newNext
                self.availableLinks = links
                self.alternativePhrases = alternatives
            }
        }
        
        state.isTransitioning = false
        transitionEngine.reset()
    }
    
    private func fillSilence(audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in ablPointer {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
    }
    
    // MARK: - Buffer Loading
    
    private func loadBuffer(for phrase: PhraseNode, completion: @escaping (AVAudioPCMBuffer?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: phrase.audioFile)
            
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("[HyperPhrasePlayer] Audio file not found: \(phrase.audioFile)")
                completion(nil)
                return
            }
            
            do {
                let file = try AVAudioFile(forReading: url)
                let format = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 2)!
                
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                    completion(nil)
                    return
                }
                
                try file.read(into: buffer)
                completion(buffer)
            } catch {
                print("[HyperPhrasePlayer] Error loading buffer: \(error)")
                completion(nil)
            }
        }
    }
    
    // MARK: - Helpers
    
    /// Check if the transition from current to next phrase is sequential (same track, next segment)
    private func isSequentialTransition() -> Bool {
        guard let current = state.currentPhrase,
              let next = state.nextPhrase else {
            return false
        }
        
        // Same track and next segment index
        return current.sourceTrack == next.sourceTrack &&
               next.trackIndex == current.trackIndex + 1
    }
    
    /// Complete a gapless transition (same track, sequential segment)
    private func completeGaplessTransition() {
        // Swap buffers
        currentBuffer = nextBuffer
        nextBuffer = nil
        
        // Update state
        if let next = state.nextPhrase {
            state.currentPhrase = next
            state.playbackPosition = 0  // Start from beginning
            
            // Select new next phrase
            let links = database.getLinks(for: next.id)
            let alternatives = database.getAlternatives(for: next.id, limit: 8)
            
            // For gapless, always prefer same track sequence
            let newNext = database.getNextInSequence(for: next.id)
            state.nextPhrase = newNext
            
            if let newNextPhrase = newNext {
                loadBuffer(for: newNextPhrase) { [weak self] buffer in
                    self?.stateLock.lock()
                    self?.nextBuffer = buffer
                    self?.stateLock.unlock()
                }
            }
            
            // Update published properties
            DispatchQueue.main.async {
                self.currentPhrase = next
                self.nextPhrase = newNext
                self.availableLinks = links
                self.alternativePhrases = alternatives
            }
        }
    }
    
    private func transitionTypeFromString(_ string: String) -> TransitionEngine.TransitionType {
        switch string {
        case "crossfade": return .crossfade
        case "eqSwap": return .eqSwap
        case "filter": return .filter
        case "cut": return .cut
        default: return .crossfade
        }
    }
    
    // MARK: - Errors
    
    enum HyperPlayerError: LocalizedError {
        case noPhrasesLoaded
        case graphNotLoaded
        case phraseNotFound(String)
        
        var errorDescription: String? {
            switch self {
            case .noPhrasesLoaded:
                return "No phrases loaded for playback"
            case .graphNotLoaded:
                return "Phrase graph not loaded"
            case .phraseNotFound(let id):
                return "Phrase not found: \(id)"
            }
        }
    }
}

