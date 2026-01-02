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
        var nextPhrase: PhraseNode?           // Queued branch (could be same or different song)
        var currentSongPath: String?          // Path to currently playing song
        var songPosition: Int = 0             // Sample position within the full song
        var isTransitioning: Bool = false
        var transitionProgress: Float = 0.0
        var pendingCut: Bool = false          // User requested beat-aligned cut
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
    @Published private(set) var playbackProgress: Double = 0.0  // 0-1 position in current phrase
    @Published private(set) var trackPlaybackProgress: Double = 0.0  // 0-1 position in full track (for full waveform display)
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
    
    // Song cache - full songs loaded by path
    private var songCache: [String: AVAudioPCMBuffer] = [:]
    private var currentSongBuffer: AVAudioPCMBuffer?  // Currently playing song
    private var pendingSongBuffer: AVAudioPCMBuffer?  // For cross-song transitions
    
    
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
    /// This loads the song (if needed) and seeks to the phrase's start time
    func selectPhrase(_ phrase: PhraseNode) {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        state.currentPhrase = phrase
        state.isTransitioning = false
        state.nextPhrase = nil
        
        let songPath = phrase.audioFile  // Now points to original song
        let startSample = Int((phrase.startTime ?? 0) * sampleRate)
        
        // Load song if needed
        if state.currentSongPath != songPath {
            // Different song - need to load it
            loadSong(path: songPath) { [weak self] buffer in
                guard let self = self else { return }
                self.stateLock.lock()
                self.currentSongBuffer = buffer
                self.state.currentSongPath = songPath
                self.state.songPosition = startSample
                self.stateLock.unlock()
            }
        } else {
            // Same song - just seek to phrase start
            state.songPosition = startSample
        }
        
        // Update available links
        let links = database.getLinks(for: phrase.id)
        let alternatives = database.getAlternatives(for: phrase.id, limit: 8)
        
        // Update published properties
        DispatchQueue.main.async {
            self.currentPhrase = phrase
            self.nextPhrase = nil
            self.availableLinks = links
            self.alternativePhrases = alternatives
        }
    }
    
    /// Queue a specific phrase as next (user selection / branch)
    /// If the phrase is from a different song, pre-load that song
    func queueNext(_ phrase: PhraseNode) {
        stateLock.lock()
        state.nextPhrase = phrase
        stateLock.unlock()
        
        let songPath = phrase.audioFile
        
        // Pre-load the song if it's different from current
        if songPath != state.currentSongPath {
            loadSong(path: songPath) { [weak self] buffer in
                self?.stateLock.lock()
                self?.pendingSongBuffer = buffer
                self?.stateLock.unlock()
            }
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
    
    /// Get branch options for a specific phrase (alternatives from OTHER tracks only)
    func getBranchOptions(for phrase: PhraseNode, limit: Int = 5) -> [PhraseNode] {
        let links = database.getLinks(for: phrase.id)
        return links
            .filter { !$0.isOriginalSequence }  // Exclude same-track sequence links
            .compactMap { database.getPhrase(id: $0.targetId) }
            .filter { $0.sourceTrack != phrase.sourceTrack }  // Exclude ALL phrases from same track
            .prefix(limit)
            .map { $0 }  // Convert ArraySlice to Array
    }
    
    // MARK: - Playback Control
    
    /// Start playback
    func start() throws {
        guard currentSongBuffer != nil else {
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
    
    /// Trigger transition to queued branch (beat-aligned)
    func triggerTransition() {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard state.nextPhrase != nil else { return }
        
        // For same-song branch, execute immediately at phrase boundary
        // For cross-song branch, mark for beat-aligned cut
        if let branch = state.nextPhrase,
           branch.audioFile == state.currentSongPath {
            // Same song - seek directly
            let targetSample = Int((branch.startTime ?? 0) * sampleRate)
            state.songPosition = targetSample
            advanceToPhrase(branch)
        } else {
            // Cross-song - mark for beat-aligned cut
            state.pendingCut = true
        }
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
        
        // Get current song buffer
        guard let songBuffer = currentSongBuffer,
              let channelData = songBuffer.floatChannelData else {
            fillSilence(audioBufferList: audioBufferList, frameCount: frameCount)
            return noErr
        }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard ablPointer.count >= 2 else { return noErr }
        
        let leftOut = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let rightOut = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        let songLength = Int(songBuffer.frameLength)
        let channelCount = Int(songBuffer.format.channelCount)
        
        // Get current phrase boundaries
        let phraseEndSample = Int((state.currentPhrase?.endTime ?? Double.greatestFiniteMagnitude) * sampleRate)
        
        // Check for pending beat-aligned cut to branch
        if state.pendingCut, let branchPhrase = state.nextPhrase {
            let phraseRelativeTime = Double(state.songPosition) / sampleRate - (state.currentPhrase?.startTime ?? 0)
            if isNearBeat(phraseRelativeTime, beats: state.currentPhrase?.beats ?? []) {
                executeBranch(to: branchPhrase)
                state.pendingCut = false
            }
        }
        
        // Render audio samples
        for i in 0..<Int(frameCount) {
            if state.songPosition < songLength {
                // Read from song buffer
                let leftSample: Float
                let rightSample: Float
                
                if channelCount >= 2 {
                    leftSample = channelData[0][state.songPosition]
                    rightSample = channelData[1][state.songPosition]
                } else {
                    leftSample = channelData[0][state.songPosition]
                    rightSample = leftSample
                }
                
                leftOut?[i] = leftSample * settings.masterVolume
                rightOut?[i] = rightSample * settings.masterVolume
                state.songPosition += 1
                
                // Check if we've reached phrase boundary
                if state.songPosition >= phraseEndSample {
                    handlePhraseEnd()
                }
            } else {
                // End of song
                if settings.autoAdvance, let branchPhrase = state.nextPhrase {
                    executeBranch(to: branchPhrase)
                } else {
                    // Loop from start of current phrase
                    state.songPosition = Int((state.currentPhrase?.startTime ?? 0) * sampleRate)
                }
                leftOut?[i] = 0
                rightOut?[i] = 0
            }
        }
        
        // Calculate and publish playback progress within current phrase
        updatePlaybackProgress()
        
        return noErr
    }
    
    /// Handle reaching the end of the current phrase
    private func handlePhraseEnd() {
        guard let songPath = state.currentSongPath else { return }
        
        // Check if there's a queued branch
        if let branchPhrase = state.nextPhrase {
            // Is it to a different song?
            if branchPhrase.audioFile != songPath {
                // Cross-song branch - execute transition
                executeBranch(to: branchPhrase)
            } else {
                // Same-song branch - just update current phrase and continue
                advanceToPhrase(branchPhrase)
            }
        } else if settings.autoAdvance {
            // Auto-advance to next phrase in same song
            if let nextPhrase = database.getNextInSequence(for: state.currentPhrase?.id ?? "") {
                advanceToPhrase(nextPhrase)
            }
            // If no next phrase, just keep playing (song will naturally end)
        }
        // If no branch and no auto-advance, continue playing (phrase boundaries are just markers)
    }
    
    /// Advance to a new phrase within the same song (gapless)
    private func advanceToPhrase(_ phrase: PhraseNode) {
        state.currentPhrase = phrase
        state.nextPhrase = nil
        
        // Update UI
        let links = database.getLinks(for: phrase.id)
        let alternatives = database.getAlternatives(for: phrase.id, limit: 8)
        
        DispatchQueue.main.async { [weak self] in
            self?.currentPhrase = phrase
            self?.nextPhrase = nil
            self?.availableLinks = links
            self?.alternativePhrases = alternatives
        }
    }
    
    /// Execute a branch transition to a different song
    private func executeBranch(to phrase: PhraseNode) {
        let songPath = phrase.audioFile
        let startSample = Int((phrase.startTime ?? 0) * sampleRate)
        
        // If song is pre-loaded in pending buffer, use it
        if songPath != state.currentSongPath, let pendingBuffer = pendingSongBuffer {
            currentSongBuffer = pendingBuffer
            pendingSongBuffer = nil
            state.currentSongPath = songPath
            state.songPosition = startSample
        } else if songPath == state.currentSongPath {
            // Same song, just seek
            state.songPosition = startSample
        } else {
            // Song not loaded - load synchronously (should have been pre-loaded)
            print("[HyperPhrasePlayer] Warning: Song not pre-loaded for branch: \(songPath)")
            // Load from cache if available
            if let cached = songCache[songPath] {
                currentSongBuffer = cached
                state.currentSongPath = songPath
                state.songPosition = startSample
            }
        }
        
        advanceToPhrase(phrase)
    }
    
    /// Update playback progress (0-1 within current phrase and full track)
    private func updatePlaybackProgress() {
        guard let phrase = state.currentPhrase,
              let currentSongBuffer = currentSongBuffer else { return }
        
        let phraseStart = phrase.startTime ?? 0
        let phraseEnd = phrase.endTime ?? phrase.duration
        let phraseDuration = phraseEnd - phraseStart
        
        guard phraseDuration > 0 else { return }
        
        let currentTime = Double(state.songPosition) / sampleRate
        let phraseRelativeTime = currentTime - phraseStart
        let progress = min(1.0, max(0.0, phraseRelativeTime / phraseDuration))
        
        // Calculate track-relative progress
        let totalSongDuration = Double(currentSongBuffer.frameLength) / sampleRate
        let trackProgress = min(1.0, max(0.0, currentTime / totalSongDuration))
        
        // Update both progress values if changed significantly
        if abs(progress - playbackProgress) > 0.005 || abs(trackProgress - trackPlaybackProgress) > 0.005 {
            DispatchQueue.main.async { [weak self] in
                self?.playbackProgress = progress
                self?.trackPlaybackProgress = trackProgress
            }
        }
    }
    
    private func fillSilence(audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in ablPointer {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
    }
    
    // MARK: - Song Loading
    
    /// Load a full song file (with caching)
    private func loadSong(path: String, completion: @escaping (AVAudioPCMBuffer?) -> Void) {
        // Check cache first
        if let cached = songCache[path] {
            completion(cached)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let url = URL(fileURLWithPath: path)
            
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("[HyperPhrasePlayer] Song not found: \(path)")
                completion(nil)
                return
            }
            
            do {
                let file = try AVAudioFile(forReading: url)
                let format = AVAudioFormat(standardFormatWithSampleRate: self.sampleRate, channels: 2)!
                
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                    print("[HyperPhrasePlayer] Failed to create buffer for: \(path)")
                    completion(nil)
                    return
                }
                
                try file.read(into: buffer)
                
                // Cache the loaded song
                DispatchQueue.main.async {
                    self.songCache[path] = buffer
                    print("[HyperPhrasePlayer] Cached song: \(URL(fileURLWithPath: path).lastPathComponent) (\(buffer.frameLength) samples)")
                }
                
                completion(buffer)
            } catch {
                print("[HyperPhrasePlayer] Error loading song: \(error)")
                completion(nil)
            }
        }
    }
    
    /// Get phrase at a given song position
    private func getPhraseAtPosition(_ samplePosition: Int, inSong songPath: String) -> PhraseNode? {
        let timePosition = Double(samplePosition) / sampleRate
        let trackPhrases = database.getPhrasesForTrack(songPath)
        
        for phrase in trackPhrases {
            let start = phrase.startTime ?? 0
            let end = phrase.endTime ?? phrase.duration
            if timePosition >= start && timePosition < end {
                return phrase
            }
        }
        
        // If past all phrases, return the last one
        return trackPhrases.last
    }
    
    // MARK: - Helpers
    
    /// Check if current playback position is near a beat
    private func isNearBeat(_ currentTime: TimeInterval, beats: [TimeInterval]) -> Bool {
        let tolerance: TimeInterval = 0.05  // 50ms tolerance
        
        // If no beat data, cut immediately
        if beats.isEmpty {
            return true
        }
        
        // Find nearest beat
        for beat in beats {
            if abs(currentTime - beat) <= tolerance {
                return true
            }
        }
        
        // Also cut if we're very close to end of phrase (within 100ms)
        if let phrase = state.currentPhrase {
            let remaining = phrase.duration - currentTime
            if remaining < 0.1 {
                return true
            }
        }
        
        return false
    }
    
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

