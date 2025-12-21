import Foundation
import Accelerate

/// Intelligent segment matching for concatenative synthesis
/// Finds the best next segment based on spectral similarity, tempo, key, and transition compatibility
class SegmentMatcher {
    
    // MARK: - Types
    
    struct SegmentInfo {
        let identifier: String
        let style: String?
        let tempo: Double?
        let key: String?
        let energy: Double
        let spectralEmbedding: [Float]
        let startSpectrum: [Float]
        let endSpectrum: [Float]
        let onsetPositions: [Double]
        let duration: TimeInterval
    }
    
    struct MatchResult {
        let segment: SegmentInfo
        let overallScore: Float
        let spectralSimilarity: Float
        let transitionCompatibility: Float
        let tempoCompatibility: Float
        let keyCompatibility: Float
    }
    
    struct MatchCriteria {
        var targetStyle: String? = nil
        var tempoRange: ClosedRange<Double>? = nil // e.g., 120...130 BPM
        var energyRange: ClosedRange<Double>? = nil // e.g., 0.5...0.8
        var preferSameKey: Bool = true
        var minSimilarity: Float = 0.3
        var weights: MatchWeights = .default
    }
    
    struct MatchWeights {
        var spectral: Float = 0.3
        var transition: Float = 0.3
        var tempo: Float = 0.2
        var key: Float = 0.15
        var energy: Float = 0.05
        
        static let `default` = MatchWeights()
        
        static let spectralFocused = MatchWeights(
            spectral: 0.5, transition: 0.3, tempo: 0.1, key: 0.05, energy: 0.05
        )
        
        static let tempoFocused = MatchWeights(
            spectral: 0.2, transition: 0.2, tempo: 0.4, key: 0.15, energy: 0.05
        )
    }
    
    // MARK: - Properties
    
    private var segments: [SegmentInfo] = []
    private let segmentsLock = NSLock()
    
    // Key relationships for harmonic mixing
    private let circleOfFifths = ["C", "G", "D", "A", "E", "B", "F#", "Db", "Ab", "Eb", "Bb", "F"]
    private let relativeMinors: [String: String] = [
        "C": "Am", "G": "Em", "D": "Bm", "A": "F#m", "E": "C#m", "B": "G#m",
        "F#": "D#m", "Db": "Bbm", "Ab": "Fm", "Eb": "Cm", "Bb": "Gm", "F": "Dm"
    ]
    
    // MARK: - Public Interface
    
    /// Adds a segment to the matcher
    func addSegment(_ info: SegmentInfo) {
        segmentsLock.lock()
        segments.append(info)
        segmentsLock.unlock()
    }
    
    /// Adds segments from audio features
    func addSegment(identifier: String, style: String?, features: FeatureExtractor.AudioFeatures) {
        let info = SegmentInfo(
            identifier: identifier,
            style: style,
            tempo: features.tempo,
            key: features.key,
            energy: features.energy,
            spectralEmbedding: features.spectralEmbedding,
            startSpectrum: features.startSpectrum,
            endSpectrum: features.endSpectrum,
            onsetPositions: features.onsetPositions,
            duration: features.duration
        )
        addSegment(info)
    }
    
    /// Clears all segments
    func clearSegments() {
        segmentsLock.lock()
        segments.removeAll()
        segmentsLock.unlock()
    }
    
    /// Finds the best matching segment after the current one
    func findBestMatch(after current: SegmentInfo, criteria: MatchCriteria = MatchCriteria()) -> MatchResult? {
        segmentsLock.lock()
        defer { segmentsLock.unlock() }
        
        var candidates: [MatchResult] = []
        
        for segment in segments {
            // Skip same segment
            if segment.identifier == current.identifier { continue }
            
            // Apply hard filters
            if let style = criteria.targetStyle, segment.style != style { continue }
            
            if let tempoRange = criteria.tempoRange, let tempo = segment.tempo {
                if !tempoRange.contains(tempo) { continue }
            }
            
            if let energyRange = criteria.energyRange {
                if !energyRange.contains(segment.energy) { continue }
            }
            
            // Calculate match scores
            let result = calculateMatch(from: current, to: segment, weights: criteria.weights, preferSameKey: criteria.preferSameKey)
            
            if result.overallScore >= criteria.minSimilarity {
                candidates.append(result)
            }
        }
        
        // Sort by score (descending)
        candidates.sort { $0.overallScore > $1.overallScore }
        
        // Return best match, or nil if no candidates
        return candidates.first
    }
    
    /// Finds top N matching segments
    func findTopMatches(after current: SegmentInfo, count: Int = 5, criteria: MatchCriteria = MatchCriteria()) -> [MatchResult] {
        segmentsLock.lock()
        defer { segmentsLock.unlock() }
        
        var candidates: [MatchResult] = []
        
        for segment in segments {
            if segment.identifier == current.identifier { continue }
            
            if let style = criteria.targetStyle, segment.style != style { continue }
            
            if let tempoRange = criteria.tempoRange, let tempo = segment.tempo {
                if !tempoRange.contains(tempo) { continue }
            }
            
            if let energyRange = criteria.energyRange {
                if !energyRange.contains(segment.energy) { continue }
            }
            
            let result = calculateMatch(from: current, to: segment, weights: criteria.weights, preferSameKey: criteria.preferSameKey)
            
            if result.overallScore >= criteria.minSimilarity {
                candidates.append(result)
            }
        }
        
        candidates.sort { $0.overallScore > $1.overallScore }
        
        return Array(candidates.prefix(count))
    }
    
    /// Finds random match with some similarity constraints
    func findRandomMatch(after current: SegmentInfo, minSimilarity: Float = 0.2) -> MatchResult? {
        segmentsLock.lock()
        defer { segmentsLock.unlock() }
        
        var candidates: [MatchResult] = []
        
        for segment in segments {
            if segment.identifier == current.identifier { continue }
            
            let result = calculateMatch(from: current, to: segment, weights: .default, preferSameKey: false)
            
            if result.overallScore >= minSimilarity {
                candidates.append(result)
            }
        }
        
        return candidates.randomElement()
    }
    
    // MARK: - Match Calculation
    
    private func calculateMatch(from: SegmentInfo, to: SegmentInfo, weights: MatchWeights, preferSameKey: Bool) -> MatchResult {
        // Spectral similarity (overall timbre)
        let spectralSimilarity = cosineSimilarity(from.spectralEmbedding, to.spectralEmbedding)
        
        // Transition compatibility (end of 'from' to start of 'to')
        let transitionCompatibility = cosineSimilarity(from.endSpectrum, to.startSpectrum)
        
        // Tempo compatibility
        let tempoCompatibility = calculateTempoCompatibility(from: from.tempo, to: to.tempo)
        
        // Key compatibility
        let keyCompatibility = calculateKeyCompatibility(from: from.key, to: to.key, preferSame: preferSameKey)
        
        // Energy similarity
        let energySimilarity = 1.0 - Float(abs(from.energy - to.energy))
        
        // Calculate weighted overall score
        let overallScore = 
            spectralSimilarity * weights.spectral +
            transitionCompatibility * weights.transition +
            tempoCompatibility * weights.tempo +
            keyCompatibility * weights.key +
            energySimilarity * weights.energy
        
        return MatchResult(
            segment: to,
            overallScore: overallScore,
            spectralSimilarity: spectralSimilarity,
            transitionCompatibility: transitionCompatibility,
            tempoCompatibility: tempoCompatibility,
            keyCompatibility: keyCompatibility
        )
    }
    
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count && !a.isEmpty else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        
        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? max(0, min(1, dotProduct / denominator)) : 0
    }
    
    private func calculateTempoCompatibility(from: Double?, to: Double?) -> Float {
        guard let fromTempo = from, let toTempo = to else { return 0.5 }
        
        // Calculate ratio
        let ratio = toTempo / fromTempo
        
        // Perfect match
        if abs(ratio - 1.0) < 0.02 { return 1.0 }
        
        // Half/double tempo (common in mixing)
        if abs(ratio - 0.5) < 0.02 || abs(ratio - 2.0) < 0.02 { return 0.9 }
        
        // Within 5%
        if abs(ratio - 1.0) < 0.05 { return 0.8 }
        
        // Within 10%
        if abs(ratio - 1.0) < 0.10 { return 0.6 }
        
        // Beyond 10% - score decreases
        return max(0, Float(1.0 - abs(ratio - 1.0)))
    }
    
    private func calculateKeyCompatibility(from: String?, to: String?, preferSame: Bool) -> Float {
        guard let fromKey = from, let toKey = to else { return 0.5 }
        
        // Same key
        if fromKey == toKey { return 1.0 }
        
        // Relative major/minor (e.g., C and Am)
        if isRelativeKey(fromKey, toKey) { return 0.95 }
        
        // Adjacent on circle of fifths (e.g., C and G)
        if isAdjacentKey(fromKey, toKey) { return 0.85 }
        
        // Parallel major/minor (e.g., C and Cm)
        if isParallelKey(fromKey, toKey) { return 0.8 }
        
        // Other - low compatibility
        return preferSame ? 0.2 : 0.5
    }
    
    private func isRelativeKey(_ a: String, _ b: String) -> Bool {
        // Check if b is the relative minor/major of a
        if let relativeMinor = relativeMinors[a], relativeMinor == b { return true }
        
        // Check reverse
        for (major, minor) in relativeMinors {
            if minor == a && major == b { return true }
        }
        
        return false
    }
    
    private func isAdjacentKey(_ a: String, _ b: String) -> Bool {
        // Strip minor 'm' suffix for comparison
        let aRoot = a.replacingOccurrences(of: "m", with: "")
        let bRoot = b.replacingOccurrences(of: "m", with: "")
        
        guard let aIndex = circleOfFifths.firstIndex(of: aRoot),
              let bIndex = circleOfFifths.firstIndex(of: bRoot) else {
            return false
        }
        
        let distance = abs(aIndex - bIndex)
        return distance == 1 || distance == circleOfFifths.count - 1
    }
    
    private func isParallelKey(_ a: String, _ b: String) -> Bool {
        let aIsMinor = a.hasSuffix("m")
        let bIsMinor = b.hasSuffix("m")
        
        if aIsMinor == bIsMinor { return false }
        
        let aRoot = a.replacingOccurrences(of: "m", with: "")
        let bRoot = b.replacingOccurrences(of: "m", with: "")
        
        return aRoot == bRoot
    }
    
    // MARK: - Onset Alignment
    
    /// Finds the best onset position for crossfade alignment
    func findBestCrossfadePoint(in segment: SegmentInfo, near targetTime: Double, window: Double = 0.5) -> Double {
        guard !segment.onsetPositions.isEmpty else { return targetTime }
        
        // Find onset closest to target time within window
        var bestOnset = targetTime
        var bestDistance = Double.infinity
        
        for onset in segment.onsetPositions {
            let distance = abs(onset - targetTime)
            if distance < window && distance < bestDistance {
                bestDistance = distance
                bestOnset = onset
            }
        }
        
        return bestOnset
    }
}

