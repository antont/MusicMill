import Foundation
import AVFoundation

/// Analyzes synthesis output quality by comparing to source features
class QualityAnalyzer {
    
    private let featureExtractor = FeatureExtractor()
    
    // MARK: - Quality Score
    
    struct QualityScore {
        let overall: Double        // 0-1 composite score
        let tempoMatch: Double?    // How close tempo is (0-1), nil if tempo unknown
        let keyMatch: Double?      // Same key = 1, related = 0.5, different = 0
        let energyMatch: Double    // Closeness of energy levels
        let spectralMatch: Double  // Closeness of brightness
        let textureMatch: Double   // Zero crossing rate similarity
        
        // Perceptual quality metrics
        let noiseMatch: Double     // Based on spectral flatness - higher = less noisy than source
        let clarityMatch: Double   // Based on HNR - higher = cleaner audio
        let rhythmMatch: Double    // Based on onset regularity - higher = more rhythmic
        
        var description: String {
            var lines = ["Quality Score: \(String(format: "%.2f", overall * 100))%"]
            if let tempo = tempoMatch {
                lines.append("  Tempo: \(String(format: "%.2f", tempo * 100))%")
            }
            if let key = keyMatch {
                lines.append("  Key: \(String(format: "%.2f", key * 100))%")
            }
            lines.append("  Energy: \(String(format: "%.2f", energyMatch * 100))%")
            lines.append("  Spectral: \(String(format: "%.2f", spectralMatch * 100))%")
            lines.append("  Texture: \(String(format: "%.2f", textureMatch * 100))%")
            lines.append("  Noise: \(String(format: "%.2f", noiseMatch * 100))%")
            lines.append("  Clarity: \(String(format: "%.2f", clarityMatch * 100))%")
            lines.append("  Rhythm: \(String(format: "%.2f", rhythmMatch * 100))%")
            return lines.joined(separator: "\n")
        }
    }
    
    // MARK: - Comparison Weights
    
    struct ComparisonWeights {
        // Original metrics (reduced weights to accommodate new ones)
        var tempo: Double = 0.10
        var key: Double = 0.10
        var energy: Double = 0.10
        var spectral: Double = 0.10
        var texture: Double = 0.10
        
        // Perceptual quality metrics (higher weights - these matter more for audio quality)
        var noise: Double = 0.20      // Spectral flatness - penalize noisy output
        var clarity: Double = 0.20    // HNR - reward clean harmonic content
        var rhythm: Double = 0.10     // Onset regularity - reward rhythmic coherence
        
        /// Default weights balanced between musical and perceptual quality
        static let `default` = ComparisonWeights()
        
        /// Weights focusing on timbral qualities (for when tempo/key aren't relevant)
        static let timbral = ComparisonWeights(
            tempo: 0.0, key: 0.0, 
            energy: 0.15, spectral: 0.15, texture: 0.10,
            noise: 0.25, clarity: 0.25, rhythm: 0.10
        )
        
        /// Weights focusing on perceptual quality (artifacts, noise, rhythm)
        static let perceptual = ComparisonWeights(
            tempo: 0.05, key: 0.05,
            energy: 0.05, spectral: 0.05, texture: 0.05,
            noise: 0.30, clarity: 0.30, rhythm: 0.15
        )
    }
    
    // MARK: - Musical Key Relationships
    
    private let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    
    /// Circle of fifths relationships for key matching
    private let circleOfFifths = [
        "C": ["G", "F", "Am", "Em"],    // Neighbors and relative/parallel
        "C#": ["G#", "F#", "A#m", "Fm"],
        "D": ["A", "G", "Bm", "F#m"],
        "D#": ["A#", "G#", "Cm", "Gm"],
        "E": ["B", "A", "C#m", "G#m"],
        "F": ["C", "A#", "Dm", "Am"],
        "F#": ["C#", "B", "D#m", "A#m"],
        "G": ["D", "C", "Em", "Bm"],
        "G#": ["D#", "C#", "Fm", "Cm"],
        "A": ["E", "D", "F#m", "C#m"],
        "A#": ["F", "D#", "Gm", "Dm"],
        "B": ["F#", "E", "G#m", "D#m"],
        // Minor keys
        "Cm": ["Gm", "Fm", "D#", "C"],
        "C#m": ["G#m", "F#m", "E", "C#"],
        "Dm": ["Am", "Gm", "F", "D"],
        "D#m": ["A#m", "G#m", "F#", "D#"],
        "Em": ["Bm", "Am", "G", "E"],
        "Fm": ["Cm", "A#m", "G#", "F"],
        "F#m": ["C#m", "Bm", "A", "F#"],
        "Gm": ["Dm", "Cm", "A#", "G"],
        "G#m": ["D#m", "C#m", "B", "G#"],
        "Am": ["Em", "Dm", "C", "A"],
        "A#m": ["Fm", "D#m", "C#", "A#"],
        "Bm": ["F#m", "Em", "D", "B"]
    ]
    
    // MARK: - Public API
    
    /// Compares source and output audio features
    func compare(source: FeatureExtractor.AudioFeatures, output: FeatureExtractor.AudioFeatures, weights: ComparisonWeights = .default) -> QualityScore {
        
        // Tempo match
        var tempoMatch: Double? = nil
        if let srcTempo = source.tempo, let outTempo = output.tempo {
            // Allow for octave errors (half/double tempo)
            let ratio = outTempo / srcTempo
            if ratio >= 0.48 && ratio <= 0.52 {
                tempoMatch = 0.8 // Half tempo detected
            } else if ratio >= 1.95 && ratio <= 2.05 {
                tempoMatch = 0.8 // Double tempo detected
            } else {
                let diff = abs(srcTempo - outTempo) / srcTempo
                tempoMatch = max(0, 1.0 - diff)
            }
        }
        
        // Key match
        var keyMatch: Double? = nil
        if let srcKey = source.key, let outKey = output.key {
            keyMatch = calculateKeyMatch(source: srcKey, output: outKey)
        }
        
        // Energy match (both are 0-1)
        let energyDiff = abs(source.energy - output.energy)
        let energyMatch = max(0, 1.0 - energyDiff)
        
        // Spectral centroid match (ratio-based)
        let spectralMatch: Double
        if source.spectralCentroid > 0 && output.spectralCentroid > 0 {
            let ratio = min(source.spectralCentroid, output.spectralCentroid) / max(source.spectralCentroid, output.spectralCentroid)
            spectralMatch = ratio
        } else {
            spectralMatch = 0.0
        }
        
        // Texture match (zero crossing rate)
        let textureMatch: Double
        if source.zeroCrossingRate > 0 && output.zeroCrossingRate > 0 {
            let ratio = min(source.zeroCrossingRate, output.zeroCrossingRate) / max(source.zeroCrossingRate, output.zeroCrossingRate)
            textureMatch = ratio
        } else {
            textureMatch = 0.0
        }
        
        // MARK: - Perceptual Quality Metrics
        
        // Noise match: Compare spectral flatness
        // Lower flatness = more tonal = better for music
        // We want output to be similar to or less noisy than source
        let noiseMatch: Double
        if source.spectralFlatness > 0 {
            // If output is less noisy (lower flatness), that's good (score up to 1.0)
            // If output is more noisy (higher flatness), penalize it
            if output.spectralFlatness <= source.spectralFlatness {
                // Output is less noisy or equal - good!
                noiseMatch = 1.0
            } else {
                // Output is noisier - penalize based on how much noisier
                let noiseDiff = output.spectralFlatness - source.spectralFlatness
                noiseMatch = max(0, 1.0 - noiseDiff * 2.0) // Amplify penalty
            }
        } else {
            noiseMatch = output.spectralFlatness < 0.5 ? 1.0 : 0.5 // Default: low flatness is good
        }
        
        // Clarity match: Compare HNR (harmonic-to-noise ratio)
        // Higher HNR = cleaner audio
        // We want output to have similar or higher HNR than source
        let clarityMatch: Double
        if source.harmonicToNoiseRatio > 0 {
            // If output has higher or similar HNR, that's good
            if output.harmonicToNoiseRatio >= source.harmonicToNoiseRatio * 0.8 {
                clarityMatch = min(1.0, output.harmonicToNoiseRatio / source.harmonicToNoiseRatio)
            } else {
                // Output has significantly lower HNR - more artifacts
                let hnrRatio = output.harmonicToNoiseRatio / source.harmonicToNoiseRatio
                clarityMatch = max(0, hnrRatio)
            }
        } else {
            // Default: higher HNR is better (normalize to 0-1 assuming max HNR of 30)
            clarityMatch = min(1.0, output.harmonicToNoiseRatio / 20.0)
        }
        
        // Rhythm match: Compare onset regularity
        // Lower regularity value = more rhythmic (better for music)
        // We want output to have similar or better rhythmic regularity
        let rhythmMatch: Double
        if source.onsetRegularity < 1.0 {
            // If output is more regular (lower value), that's good
            if output.onsetRegularity <= source.onsetRegularity {
                rhythmMatch = 1.0
            } else {
                // Output is less regular - penalize
                let irregularityDiff = output.onsetRegularity - source.onsetRegularity
                rhythmMatch = max(0, 1.0 - irregularityDiff)
            }
        } else {
            // Source itself is irregular - just check if output is reasonable
            rhythmMatch = max(0, 1.0 - output.onsetRegularity)
        }
        
        // Calculate overall score
        var overallScore = 0.0
        var totalWeight = 0.0
        
        if let tempo = tempoMatch {
            overallScore += tempo * weights.tempo
            totalWeight += weights.tempo
        }
        
        if let key = keyMatch {
            overallScore += key * weights.key
            totalWeight += weights.key
        }
        
        overallScore += energyMatch * weights.energy
        totalWeight += weights.energy
        
        overallScore += spectralMatch * weights.spectral
        totalWeight += weights.spectral
        
        overallScore += textureMatch * weights.texture
        totalWeight += weights.texture
        
        // Add perceptual quality metrics
        overallScore += noiseMatch * weights.noise
        totalWeight += weights.noise
        
        overallScore += clarityMatch * weights.clarity
        totalWeight += weights.clarity
        
        overallScore += rhythmMatch * weights.rhythm
        totalWeight += weights.rhythm
        
        // Normalize by total weight
        if totalWeight > 0 {
            overallScore /= totalWeight
        }
        
        return QualityScore(
            overall: overallScore,
            tempoMatch: tempoMatch,
            keyMatch: keyMatch,
            energyMatch: energyMatch,
            spectralMatch: spectralMatch,
            textureMatch: textureMatch,
            noiseMatch: noiseMatch,
            clarityMatch: clarityMatch,
            rhythmMatch: rhythmMatch
        )
    }
    
    /// Analyzes output audio buffer against source features
    func analyzeOutput(audioBuffer: AVAudioPCMBuffer, sourceFeatures: FeatureExtractor.AudioFeatures, weights: ComparisonWeights = .default) -> QualityScore {
        let outputFeatures = featureExtractor.extractFeatures(from: audioBuffer)
        return compare(source: sourceFeatures, output: outputFeatures, weights: weights)
    }
    
    /// Analyzes output audio from URL against source features
    func analyzeOutput(audioURL: URL, sourceFeatures: FeatureExtractor.AudioFeatures, weights: ComparisonWeights = .default) async throws -> QualityScore {
        let outputFeatures = try await featureExtractor.extractFeatures(from: audioURL)
        return compare(source: sourceFeatures, output: outputFeatures, weights: weights)
    }
    
    // MARK: - Key Matching
    
    private func calculateKeyMatch(source: String, output: String) -> Double {
        // Exact match
        if source == output {
            return 1.0
        }
        
        // Relative major/minor (e.g., C and Am)
        if isRelativeKey(source, output) {
            return 0.85
        }
        
        // Parallel major/minor (e.g., C and Cm)
        if isParallelKey(source, output) {
            return 0.75
        }
        
        // Circle of fifths neighbor
        if isCircleOfFifthsNeighbor(source, output) {
            return 0.6
        }
        
        // Distant key
        return 0.2
    }
    
    private func isRelativeKey(_ key1: String, _ key2: String) -> Bool {
        // Relative pairs: C/Am, G/Em, D/Bm, etc.
        let relativePairs = [
            ("C", "Am"), ("G", "Em"), ("D", "Bm"), ("A", "F#m"),
            ("E", "C#m"), ("B", "G#m"), ("F#", "D#m"), ("C#", "A#m"),
            ("F", "Dm"), ("A#", "Gm"), ("D#", "Cm"), ("G#", "Fm")
        ]
        
        for (major, minor) in relativePairs {
            if (key1 == major && key2 == minor) || (key1 == minor && key2 == major) {
                return true
            }
        }
        return false
    }
    
    private func isParallelKey(_ key1: String, _ key2: String) -> Bool {
        // Parallel pairs: C/Cm, G/Gm, etc.
        let note1 = key1.replacingOccurrences(of: "m", with: "")
        let note2 = key2.replacingOccurrences(of: "m", with: "")
        
        if note1 == note2 && key1 != key2 {
            return true
        }
        return false
    }
    
    private func isCircleOfFifthsNeighbor(_ key1: String, _ key2: String) -> Bool {
        if let neighbors = circleOfFifths[key1] {
            return neighbors.contains(key2)
        }
        if let neighbors = circleOfFifths[key2] {
            return neighbors.contains(key1)
        }
        return false
    }
}

