import Foundation
import AVFoundation
import Combine

/// Deck identifier
enum DeckID: String, CaseIterable {
    case a = "A"
    case b = "B"
}

/// A single deck for phrase playback with EQ, volume, and position control.
class Deck: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var id: DeckID
    @Published private(set) var currentPhrase: PhraseNode?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var playbackPosition: Double = 0  // 0-1
    @Published private(set) var playbackTime: TimeInterval = 0  // Seconds
    @Published private(set) var isLoaded: Bool = false
    
    /// EQ gains in dB (-infinity to +12)
    @Published var eqLow: Float = 0 {
        didSet { updateEQ() }
    }
    @Published var eqMid: Float = 0 {
        didSet { updateEQ() }
    }
    @Published var eqHigh: Float = 0 {
        didSet { updateEQ() }
    }
    
    /// Volume (0-1)
    @Published var volume: Float = 1.0 {
        didSet { updateVolume() }
    }
    
    // MARK: - Audio Components
    
    private(set) var sourceNode: AVAudioSourceNode?
    private var audioBuffer: AVAudioPCMBuffer?
    private var eq: ThreeBandEQ?
    
    // MARK: - Playback State
    
    private var samplePosition: Int = 0
    private let sampleRate: Double = 44100.0
    private let lock = NSLock()
    
    // Beat grid for position snapping
    private var beatTimes: [TimeInterval] = []
    private var downbeatTimes: [TimeInterval] = []
    
    // MARK: - Initialization
    
    init(id: DeckID) {
        self.id = id
        self.eq = ThreeBandEQ(sampleRate: Float(sampleRate))
        createSourceNode()
    }
    
    // MARK: - Source Node Creation
    
    private func createSourceNode() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.renderAudio(frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }
    
    private func renderAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        
        guard isPlaying,
              let buffer = audioBuffer,
              let bufferData = buffer.floatChannelData else {
            // Output silence
            for bufferIndex in 0..<ablPointer.count {
                let outBuffer = ablPointer[bufferIndex]
                if let data = outBuffer.mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<Int(frameCount) {
                        data[i] = 0
                    }
                }
            }
            return noErr
        }
        
        let bufferLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        
        // Render audio with EQ
        for frame in 0..<Int(frameCount) {
            var leftSample: Float = 0
            var rightSample: Float = 0
            
            if samplePosition < bufferLength {
                leftSample = bufferData[0][samplePosition]
                if channelCount > 1 {
                    rightSample = bufferData[1][samplePosition]
                } else {
                    rightSample = leftSample
                }
                
                // Apply EQ
                if let eq = eq {
                    leftSample = eq.process(sample: leftSample, channel: 0)
                    rightSample = eq.process(sample: rightSample, channel: 1)
                }
                
                // Apply volume
                leftSample *= volume
                rightSample *= volume
                
                samplePosition += 1
            }
            
            // Write to output buffers
            if ablPointer.count >= 2 {
                // Stereo output
                if let leftData = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) {
                    leftData[frame] = leftSample
                }
                if let rightData = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) {
                    rightData[frame] = rightSample
                }
            } else if ablPointer.count == 1 {
                // Interleaved stereo
                if let data = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) {
                    data[frame * 2] = leftSample
                    data[frame * 2 + 1] = rightSample
                }
            }
        }
        
        // Update playback position
        if bufferLength > 0 {
            let progress = Double(samplePosition) / Double(bufferLength)
            let time = Double(samplePosition) / sampleRate
            
            DispatchQueue.main.async { [weak self] in
                self?.playbackPosition = min(1.0, progress)
                self?.playbackTime = time
            }
            
            // Stop at end
            if samplePosition >= bufferLength {
                DispatchQueue.main.async { [weak self] in
                    self?.isPlaying = false
                }
            }
        }
        
        return noErr
    }
    
    // MARK: - Phrase Loading
    
    /// Load a phrase into this deck
    func load(_ phrase: PhraseNode) async throws {
        // Load audio file
        let audioURL = URL(fileURLWithPath: phrase.audioFile)
        let audioFile = try AVAudioFile(forReading: audioURL)
        
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw DeckError.bufferCreationFailed
        }
        
        try audioFile.read(into: buffer)
        
        // Convert to standard format if needed
        let standardFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        if format.sampleRate != sampleRate || format.channelCount != 2 {
            // Need conversion
            guard let converter = AVAudioConverter(from: format, to: standardFormat) else {
                throw DeckError.conversionFailed
            }
            
            let ratio = sampleRate / format.sampleRate
            let convertedFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
            
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: standardFormat, frameCapacity: convertedFrameCount) else {
                throw DeckError.bufferCreationFailed
            }
            
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if let error = error {
                throw error
            }
            
            lock.lock()
            audioBuffer = convertedBuffer
            lock.unlock()
        } else {
            lock.lock()
            audioBuffer = buffer
            lock.unlock()
        }
        
        // Store beat grid
        beatTimes = phrase.beats
        downbeatTimes = phrase.downbeats
        
        // Update state on main thread
        await MainActor.run {
            currentPhrase = phrase
            isLoaded = true
            playbackPosition = 0
            playbackTime = 0
            samplePosition = 0
        }
    }
    
    /// Unload the current phrase
    func unload() {
        lock.lock()
        audioBuffer = nil
        samplePosition = 0
        lock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            self?.currentPhrase = nil
            self?.isLoaded = false
            self?.isPlaying = false
            self?.playbackPosition = 0
            self?.playbackTime = 0
        }
        
        beatTimes = []
        downbeatTimes = []
    }
    
    // MARK: - Playback Control
    
    /// Start playback
    func play() {
        guard isLoaded else { return }
        
        lock.lock()
        let atEnd = audioBuffer.map { samplePosition >= Int($0.frameLength) } ?? true
        if atEnd {
            samplePosition = 0
        }
        lock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = true
        }
    }
    
    /// Pause playback
    func pause() {
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
        }
    }
    
    /// Toggle play/pause
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    /// Stop playback and reset position
    func stop() {
        lock.lock()
        samplePosition = 0
        lock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
            self?.playbackPosition = 0
            self?.playbackTime = 0
        }
    }
    
    /// Seek to position (0-1)
    func seek(to position: Double) {
        guard let buffer = audioBuffer else { return }
        
        let clampedPosition = max(0, min(1, position))
        let newSamplePosition = Int(clampedPosition * Double(buffer.frameLength))
        
        lock.lock()
        samplePosition = newSamplePosition
        lock.unlock()
        
        let time = Double(newSamplePosition) / sampleRate
        
        DispatchQueue.main.async { [weak self] in
            self?.playbackPosition = clampedPosition
            self?.playbackTime = time
        }
    }
    
    /// Seek to specific time in seconds
    func seek(toTime time: TimeInterval) {
        guard let buffer = audioBuffer else { return }
        let duration = Double(buffer.frameLength) / sampleRate
        let position = time / duration
        seek(to: position)
    }
    
    /// Nudge position by samples (for beat matching)
    func nudge(by samples: Int) {
        lock.lock()
        let newPosition = samplePosition + samples
        samplePosition = max(0, newPosition)
        if let buffer = audioBuffer {
            samplePosition = min(samplePosition, Int(buffer.frameLength))
        }
        let pos = samplePosition
        lock.unlock()
        
        if let buffer = audioBuffer {
            let progress = Double(pos) / Double(buffer.frameLength)
            let time = Double(pos) / sampleRate
            
            DispatchQueue.main.async { [weak self] in
                self?.playbackPosition = progress
                self?.playbackTime = time
            }
        }
    }
    
    /// Nudge by milliseconds
    func nudge(byMs ms: Double) {
        let samples = Int(ms * sampleRate / 1000.0)
        nudge(by: samples)
    }
    
    // MARK: - Beat-Aware Seeking
    
    /// Seek to the nearest beat
    func seekToNearestBeat() {
        guard !beatTimes.isEmpty else { return }
        
        let currentTime = playbackTime
        var nearestBeat = beatTimes[0]
        var minDiff = abs(currentTime - nearestBeat)
        
        for beat in beatTimes {
            let diff = abs(currentTime - beat)
            if diff < minDiff {
                minDiff = diff
                nearestBeat = beat
            }
        }
        
        seek(toTime: nearestBeat)
    }
    
    /// Seek to the nearest downbeat
    func seekToNearestDownbeat() {
        guard !downbeatTimes.isEmpty else { return }
        
        let currentTime = playbackTime
        var nearestDownbeat = downbeatTimes[0]
        var minDiff = abs(currentTime - nearestDownbeat)
        
        for downbeat in downbeatTimes {
            let diff = abs(currentTime - downbeat)
            if diff < minDiff {
                minDiff = diff
                nearestDownbeat = downbeat
            }
        }
        
        seek(toTime: nearestDownbeat)
    }
    
    /// Seek to next beat
    func seekToNextBeat() {
        guard !beatTimes.isEmpty else { return }
        
        let currentTime = playbackTime
        for beat in beatTimes {
            if beat > currentTime + 0.01 {  // Small threshold to avoid current beat
                seek(toTime: beat)
                return
            }
        }
    }
    
    /// Seek to previous beat
    func seekToPreviousBeat() {
        guard !beatTimes.isEmpty else { return }
        
        let currentTime = playbackTime
        var previousBeat: TimeInterval?
        
        for beat in beatTimes {
            if beat >= currentTime - 0.01 {  // Small threshold
                break
            }
            previousBeat = beat
        }
        
        if let beat = previousBeat {
            seek(toTime: beat)
        }
    }
    
    // MARK: - EQ Control
    
    private func updateEQ() {
        eq?.setGains(low: eqLow, mid: eqMid, high: eqHigh)
    }
    
    /// Kill bass (set to -infinity)
    func killBass() {
        eqLow = -60  // Effectively -infinity
    }
    
    /// Kill mids
    func killMids() {
        eqMid = -60
    }
    
    /// Kill highs
    func killHighs() {
        eqHigh = -60
    }
    
    /// Reset all EQ to flat
    func resetEQ() {
        eqLow = 0
        eqMid = 0
        eqHigh = 0
    }
    
    // MARK: - Volume Control
    
    private func updateVolume() {
        // Volume is applied in render callback
    }
    
    // MARK: - Utility
    
    /// Get current duration in seconds
    var duration: TimeInterval {
        guard let buffer = audioBuffer else { return 0 }
        return Double(buffer.frameLength) / sampleRate
    }
    
    /// Get remaining time
    var remainingTime: TimeInterval {
        duration - playbackTime
    }
}

// MARK: - Errors

enum DeckError: Error, LocalizedError {
    case bufferCreationFailed
    case conversionFailed
    case fileNotFound
    
    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed: return "Failed to create audio buffer"
        case .conversionFailed: return "Failed to convert audio format"
        case .fileNotFound: return "Audio file not found"
        }
    }
}

