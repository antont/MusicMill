import Foundation
import AVFoundation
import Accelerate

/// Detects chord progressions, phrase boundaries, and section structure (intro, verse, chorus)
class StructureAnalyzer {
    
    struct MusicalStructure {
        let sections: [Section]
        let chordProgressions: [ChordProgression]
        let phraseBoundaries: [TimeInterval]
        let repetitions: [Repetition]
    }
    
    struct Section {
        let type: SectionType
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float
    }
    
    enum SectionType {
        case intro
        case verse
        case chorus
        case bridge
        case outro
        case unknown
    }
    
    struct ChordProgression {
        let chords: [Chord]
        let startTime: TimeInterval
        let endTime: TimeInterval
    }
    
    struct Chord {
        let root: String // e.g., "C", "D#"
        let quality: ChordQuality
        let startTime: TimeInterval
        let confidence: Float
    }
    
    enum ChordQuality {
        case major
        case minor
        case diminished
        case augmented
        case unknown
    }
    
    struct Repetition {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let repeatCount: Int
        let similarity: Float
    }
    
    private let spectralAnalyzer = SpectralAnalyzer()
    
    /// Analyzes musical structure from an audio file
    func analyzeStructure(from url: URL) async throws -> MusicalStructure {
        // Get chromagram for chord detection
        let spectralFeatures = try await spectralAnalyzer.analyzeSpectralFeatures(from: url)
        
        // Detect chords
        let chordProgressions = detectChordProgressions(chromagram: spectralFeatures.chromagram, hopLength: spectralFeatures.hopLength, sampleRate: spectralFeatures.sampleRate)
        
        // Detect phrase boundaries
        let phraseBoundaries = detectPhraseBoundaries(chromagram: spectralFeatures.chromagram, hopLength: spectralFeatures.hopLength, sampleRate: spectralFeatures.sampleRate)
        
        // Detect repetitions
        let repetitions = detectRepetitions(chromagram: spectralFeatures.chromagram, hopLength: spectralFeatures.hopLength, sampleRate: spectralFeatures.sampleRate)
        
        // Detect sections
        let sections = detectSections(
            chordProgressions: chordProgressions,
            phraseBoundaries: phraseBoundaries,
            repetitions: repetitions,
            totalDuration: Double(spectralFeatures.chromagram.count * spectralFeatures.hopLength) / spectralFeatures.sampleRate
        )
        
        return MusicalStructure(
            sections: sections,
            chordProgressions: chordProgressions,
            phraseBoundaries: phraseBoundaries,
            repetitions: repetitions
        )
    }
    
    /// Detects chord progressions from chromagram
    private func detectChordProgressions(chromagram: [[Float]], hopLength: Int, sampleRate: Double) -> [ChordProgression] {
        var progressions: [ChordProgression] = []
        var currentChords: [Chord] = []
        var currentStartTime: TimeInterval = 0.0
        
        let frameDuration = Double(hopLength) / sampleRate
        let minChordDuration: TimeInterval = 0.5 // Minimum chord duration in seconds
        
        for (frameIndex, chromaFrame) in chromagram.enumerated() {
            let time = Double(frameIndex) * frameDuration
            
            // Detect chord from chroma frame
            if let chord = detectChord(from: chromaFrame, time: time) {
                if let lastChord = currentChords.last, lastChord.root == chord.root && lastChord.quality == chord.quality {
                    // Same chord continues
                    continue
                } else {
                    // New chord detected
                    if !currentChords.isEmpty {
                        // Save previous progression if it lasted long enough
                        let progressionDuration = time - currentStartTime
                        if progressionDuration >= minChordDuration {
                            progressions.append(ChordProgression(
                                chords: currentChords,
                                startTime: currentStartTime,
                                endTime: time
                            ))
                        }
                    }
                    currentChords = [chord]
                    currentStartTime = time
                }
            }
        }
        
        // Add final progression
        if !currentChords.isEmpty {
            let finalTime = Double(chromagram.count) * frameDuration
            progressions.append(ChordProgression(
                chords: currentChords,
                startTime: currentStartTime,
                endTime: finalTime
            ))
        }
        
        return progressions
    }
    
    /// Detects a single chord from a chroma frame
    private func detectChord(from chromaFrame: [Float], time: TimeInterval) -> Chord? {
        guard chromaFrame.count == 12 else { return nil }
        
        // Find the root note (strongest chroma bin)
        var maxValue: Float = 0.0
        var rootIndex = 0
        
        for (index, value) in chromaFrame.enumerated() {
            if value > maxValue {
                maxValue = value
                rootIndex = index
            }
        }
        
        guard maxValue > 0.1 else { return nil } // Threshold
        
        // Map index to note name
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let root = noteNames[rootIndex]
        
        // Determine chord quality (simplified - would need more sophisticated analysis)
        let quality: ChordQuality = .unknown // Simplified - would analyze chroma pattern
        
        return Chord(
            root: root,
            quality: quality,
            startTime: time,
            confidence: maxValue
        )
    }
    
    /// Detects phrase boundaries
    private func detectPhraseBoundaries(chromagram: [[Float]], hopLength: Int, sampleRate: Double) -> [TimeInterval] {
        var boundaries: [TimeInterval] = [0.0]
        
        let frameDuration = Double(hopLength) / sampleRate
        
        // Detect boundaries based on chroma changes
        for i in 1..<chromagram.count {
            let prevFrame = chromagram[i-1]
            let currFrame = chromagram[i]
            
            // Calculate chroma difference
            var diff: Float = 0.0
            for j in 0..<min(prevFrame.count, currFrame.count) {
                diff += abs(prevFrame[j] - currFrame[j])
            }
            
            // If significant change, it's a phrase boundary
            if diff > 2.0 { // Threshold
                boundaries.append(Double(i) * frameDuration)
            }
        }
        
        return boundaries
    }
    
    /// Detects repetitive segments
    private func detectRepetitions(chromagram: [[Float]], hopLength: Int, sampleRate: Double) -> [Repetition] {
        var repetitions: [Repetition] = []
        
        let frameDuration = Double(hopLength) / sampleRate
        let minRepetitionDuration: TimeInterval = 4.0 // Minimum 4 seconds
        let minRepetitionFrames = Int(minRepetitionDuration / frameDuration)
        
        // Look for repeated patterns
        for segmentLength in stride(from: minRepetitionFrames, to: chromagram.count / 2, by: minRepetitionFrames) {
            for start in 0..<chromagram.count - segmentLength * 2 {
                let segment1 = Array(chromagram[start..<start + segmentLength])
                
                // Compare with subsequent segments
                for offset in stride(from: start + segmentLength, to: chromagram.count - segmentLength, by: segmentLength) {
                    let segment2 = Array(chromagram[offset..<offset + segmentLength])
                    
                    let similarity = calculateSegmentSimilarity(segment1, segment2)
                    
                    if similarity > 0.7 { // Threshold
                        let startTime = Double(start) * frameDuration
                        let endTime = Double(offset + segmentLength) * frameDuration
                        
                        // Count how many times it repeats
                        var repeatCount = 2
                        var nextOffset = offset + segmentLength
                        
                        while nextOffset + segmentLength <= chromagram.count {
                            let segment3 = Array(chromagram[nextOffset..<nextOffset + segmentLength])
                            let sim = calculateSegmentSimilarity(segment1, segment3)
                            
                            if sim > 0.7 {
                                repeatCount += 1
                                nextOffset += segmentLength
                            } else {
                                break
                            }
                        }
                        
                        repetitions.append(Repetition(
                            startTime: startTime,
                            endTime: endTime,
                            repeatCount: repeatCount,
                            similarity: similarity
                        ))
                        
                        break // Found repetition, move on
                    }
                }
            }
        }
        
        return repetitions
    }
    
    /// Calculates similarity between two chromagram segments
    private func calculateSegmentSimilarity(_ seg1: [[Float]], _ seg2: [[Float]]) -> Float {
        guard seg1.count == seg2.count && !seg1.isEmpty else { return 0.0 }
        
        var totalSimilarity: Float = 0.0
        
        for (frame1, frame2) in zip(seg1, seg2) {
            var frameSimilarity: Float = 0.0
            var norm1: Float = 0.0
            var norm2: Float = 0.0
            
            for (val1, val2) in zip(frame1, frame2) {
                frameSimilarity += val1 * val2
                norm1 += val1 * val1
                norm2 += val2 * val2
            }
            
            let denominator = sqrt(norm1 * norm2)
            if denominator > 0 {
                totalSimilarity += frameSimilarity / denominator
            }
        }
        
        return totalSimilarity / Float(seg1.count)
    }
    
    /// Detects sections (intro, verse, chorus, etc.)
    private func detectSections(
        chordProgressions: [ChordProgression],
        phraseBoundaries: [TimeInterval],
        repetitions: [Repetition],
        totalDuration: TimeInterval
    ) -> [Section] {
        var sections: [Section] = []
        
        // Simple heuristic-based section detection
        // Production would use more sophisticated methods
        
        // First section is likely intro
        if let firstBoundary = phraseBoundaries.first, firstBoundary > 0 {
            sections.append(Section(
                type: .intro,
                startTime: 0.0,
                endTime: firstBoundary,
                confidence: 0.6
            ))
        }
        
        // Sections with high repetition are likely chorus
        for repetition in repetitions {
            if repetition.repeatCount >= 3 {
                sections.append(Section(
                    type: .chorus,
                    startTime: repetition.startTime,
                    endTime: repetition.endTime,
                    confidence: Float(repetition.similarity)
                ))
            }
        }
        
        // Fill in gaps with verse sections
        var coveredTime: Set<TimeInterval> = []
        for section in sections {
            coveredTime.insert(section.startTime)
            coveredTime.insert(section.endTime)
        }
        
        // Add verse sections for uncovered areas
        let sortedBoundaries = phraseBoundaries.sorted()
        for i in 0..<sortedBoundaries.count - 1 {
            let start = sortedBoundaries[i]
            let end = sortedBoundaries[i + 1]
            
            // Check if this time range is already covered
            let isCovered = sections.contains { $0.startTime <= start && $0.endTime >= end }
            
            if !isCovered && end - start > 8.0 { // At least 8 seconds
                sections.append(Section(
                    type: .verse,
                    startTime: start,
                    endTime: end,
                    confidence: 0.5
                ))
            }
        }
        
        // Sort sections by start time
        sections.sort { $0.startTime < $1.startTime }
        
        return sections
    }
    
    enum StructureAnalyzerError: LocalizedError {
        case noAudioTrack
        case analysisFailed
        
        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "No audio track found in file"
            case .analysisFailed:
                return "Failed to analyze musical structure"
            }
        }
    }
}



