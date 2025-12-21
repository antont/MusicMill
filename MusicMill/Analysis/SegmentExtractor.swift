import Foundation
import AVFoundation
import Accelerate

/// Extracts meaningful segments (beats, phrases, loops) from tracks with style classification per segment
class SegmentExtractor {
    
    struct Segment {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let duration: TimeInterval
        let onsetTime: TimeInterval? // Detected onset time
        let isBeat: Bool // Whether this segment aligns with a beat
        let isPhrase: Bool // Whether this is a phrase boundary
        let isLoop: Bool // Whether this appears to be a loop
        let style: String? // Classified style for this segment
        let features: FeatureExtractor.AudioFeatures? // Audio features for this segment
    }
    
    private let featureExtractor = FeatureExtractor()
    
    /// Extracts segments from an audio file
    func extractSegments(from url: URL, minSegmentDuration: TimeInterval = 1.0, maxSegmentDuration: TimeInterval = 8.0) async throws -> [Segment] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(duration)
        
        // Load audio data for analysis
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SegmentExtractorError.noAudioTrack
        }
        
        let audioData = try await loadAudioData(from: audioTrack, asset: asset, sampleRate: 44100)
        
        // Detect onsets
        let onsets = detectOnsets(audioData: audioData, sampleRate: 44100)
        
        // Detect beats
        let beats = detectBeats(audioData: audioData, sampleRate: 44100, onsets: onsets)
        
        // Detect phrase boundaries
        let phraseBoundaries = detectPhraseBoundaries(audioData: audioData, sampleRate: 44100, beats: beats)
        
        // Detect loops (repetitive segments)
        let loops = detectLoops(audioData: audioData, sampleRate: 44100, beats: beats)
        
        // Build segments from detected boundaries
        var segments: [Segment] = []
        var segmentStart: TimeInterval = 0.0
        
        // Combine all boundaries and sort
        var boundaries = Set<TimeInterval>()
        boundaries.insert(0.0)
        boundaries.insert(totalDuration)
        onsets.forEach { boundaries.insert($0) }
        beats.forEach { boundaries.insert($0) }
        phraseBoundaries.forEach { boundaries.insert($0) }
        
        let sortedBoundaries = boundaries.sorted()
        
        for i in 0..<sortedBoundaries.count - 1 {
            let start = sortedBoundaries[i]
            let end = sortedBoundaries[i + 1]
            let duration = end - start
            
            // Only create segments within duration constraints
            guard duration >= minSegmentDuration && duration <= maxSegmentDuration else {
                continue
            }
            
            let isBeat = beats.contains { abs($0 - start) < 0.1 }
            let isPhrase = phraseBoundaries.contains { abs($0 - start) < 0.1 }
            let isLoop = loops.contains { $0.start <= start && $0.end >= end }
            let onsetTime = onsets.first { abs($0 - start) < 0.1 }
            
            // Extract features for this segment
            let segmentFeatures = try? await extractSegmentFeatures(
                from: url,
                startTime: start,
                duration: duration
            )
            
            segments.append(Segment(
                startTime: start,
                endTime: end,
                duration: duration,
                onsetTime: onsetTime,
                isBeat: isBeat,
                isPhrase: isPhrase,
                isLoop: isLoop,
                style: nil, // Will be set by classification later
                features: segmentFeatures
            ))
        }
        
        return segments
    }
    
    /// Detects onsets (transient events) in audio
    private func detectOnsets(audioData: [Float], sampleRate: Double) -> [TimeInterval] {
        var onsets: [TimeInterval] = []
        
        // High-frequency energy method for onset detection
        let windowSize = 2048
        let hopSize = 512
        let threshold: Float = 0.3
        
        for i in stride(from: 0, to: audioData.count - windowSize, by: hopSize) {
            let window = Array(audioData[i..<min(i + windowSize, audioData.count)])
            
            // Calculate high-frequency energy
            var highFreqEnergy: Float = 0.0
            for j in 1..<window.count {
                let diff = abs(window[j] - window[j-1])
                highFreqEnergy += diff
            }
            highFreqEnergy /= Float(window.count)
            
            // Detect onset if energy spike
            if highFreqEnergy > threshold {
                let time = Double(i) / sampleRate
                // Only add if not too close to previous onset
                if onsets.isEmpty || time - onsets.last! > 0.1 {
                    onsets.append(time)
                }
            }
        }
        
        return onsets
    }
    
    /// Detects beats using autocorrelation
    private func detectBeats(audioData: [Float], sampleRate: Double, onsets: [TimeInterval]) -> [TimeInterval] {
        // Use onsets as candidates, then refine with autocorrelation
        var beats: [TimeInterval] = []
        
        // Estimate tempo from onset intervals
        guard onsets.count > 2 else { return onsets }
        
        var intervals: [Double] = []
        for i in 1..<onsets.count {
            intervals.append(onsets[i] - onsets[i-1])
        }
        
        // Find most common interval (approximate tempo)
        let sortedIntervals = intervals.sorted()
        let medianInterval = sortedIntervals[sortedIntervals.count / 2]
        
        // Use median interval as beat period
        var currentBeat = 0.0
        while currentBeat < Double(audioData.count) / sampleRate {
            beats.append(currentBeat)
            currentBeat += medianInterval
        }
        
        return beats
    }
    
    /// Detects phrase boundaries (longer musical phrases)
    private func detectPhraseBoundaries(audioData: [Float], sampleRate: Double, beats: [TimeInterval]) -> [TimeInterval] {
        // Phrases are typically 4, 8, or 16 beats
        var phraseBoundaries: [TimeInterval] = [0.0]
        
        guard beats.count >= 4 else { return phraseBoundaries }
        
        // Detect phrase boundaries every 8 beats (common phrase length)
        let phraseLength = 8
        for i in stride(from: phraseLength, to: beats.count, by: phraseLength) {
            phraseBoundaries.append(beats[i])
        }
        
        return phraseBoundaries
    }
    
    /// Detects loops (repetitive segments)
    private func detectLoops(audioData: [Float], sampleRate: Double, beats: [TimeInterval]) -> [(start: TimeInterval, end: TimeInterval)] {
        var loops: [(start: TimeInterval, end: TimeInterval)] = []
        
        // Simple loop detection: look for repeated patterns
        // This is a simplified version - production would use more sophisticated methods
        let windowSize = 44100 * 4 // 4 seconds
        let hopSize = 44100 // 1 second
        
        guard audioData.count > windowSize * 2 else { return loops }
        
        for i in stride(from: 0, to: audioData.count - windowSize * 2, by: hopSize) {
            let window1 = Array(audioData[i..<i + windowSize])
            
            // Compare with subsequent windows
            for j in stride(from: i + windowSize, to: min(i + windowSize * 3, audioData.count - windowSize), by: hopSize) {
                let window2 = Array(audioData[j..<j + windowSize])
                
                // Calculate similarity (correlation)
                let similarity = calculateSimilarity(window1, window2)
                
                if similarity > 0.7 { // Threshold for loop detection
                    let start = Double(i) / sampleRate
                    let end = Double(j + windowSize) / sampleRate
                    loops.append((start: start, end: end))
                    break // Found a loop, move on
                }
            }
        }
        
        return loops
    }
    
    /// Calculates similarity between two audio windows
    private func calculateSimilarity(_ window1: [Float], _ window2: [Float]) -> Float {
        guard window1.count == window2.count else { return 0.0 }
        
        // Calculate cross-correlation
        var correlation: Float = 0.0
        var norm1: Float = 0.0
        var norm2: Float = 0.0
        
        for i in 0..<window1.count {
            correlation += window1[i] * window2[i]
            norm1 += window1[i] * window1[i]
            norm2 += window2[i] * window2[i]
        }
        
        let denominator = sqrt(norm1 * norm2)
        return denominator > 0 ? correlation / denominator : 0.0
    }
    
    /// Loads audio data from a track
    private func loadAudioData(from track: AVAssetTrack, asset: AVAsset, sampleRate: Double) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1 // Mono for analysis
        ])
        
        reader.add(output)
        reader.startReading()
        
        var audioData: [Float] = []
        
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                
                let status = CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &dataPointer
                )
                
                guard status == noErr, let pointer = dataPointer else {
                    continue
                }
                
                let floatPointer = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)
                let floatCount = length / MemoryLayout<Float>.size
                audioData.append(contentsOf: Array(UnsafeBufferPointer(start: floatPointer, count: floatCount)))
            }
        }
        
        return audioData
    }
    
    /// Extracts features for a specific segment
    private func extractSegmentFeatures(from url: URL, startTime: TimeInterval, duration: TimeInterval) async throws -> FeatureExtractor.AudioFeatures? {
        // Create a temporary segment file and extract features
        // For now, return nil - this would require segment extraction
        // In production, extract segment and analyze it
        return nil
    }
    
    enum SegmentExtractorError: LocalizedError {
        case noAudioTrack
        case audioLoadFailed
        
        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "No audio track found in file"
            case .audioLoadFailed:
                return "Failed to load audio data"
            }
        }
    }
}

