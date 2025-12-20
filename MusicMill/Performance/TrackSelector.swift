import Foundation
import Combine
import CoreML
import AVFoundation

/// Intelligently selects tracks based on model predictions and user preferences
class TrackSelector: ObservableObject {
    @Published var availableTracks: [Track] = []
    @Published var recommendedTracks: [Track] = []
    @Published var isClassifying = false
    @Published var classificationProgress: Double = 0.0
    
    private var model: MLModel?
    
    struct Track {
        let url: URL
        let title: String
        let style: String? // From directory structure or metadata
        let features: FeatureExtractor.AudioFeatures?
        let predictedStyle: String? // From model classification
        let confidence: Double?
    }
    
    /// Sets the model for intelligent selection
    func setModel(_ model: MLModel) {
        self.model = model
    }
    
    /// Loads tracks from a directory and classifies them using the model
    func loadTracks(from directory: URL) async {
        let analyzer = AudioAnalyzer()
        let featureExtractor = FeatureExtractor()
        
        await MainActor.run {
            isClassifying = true
            classificationProgress = 0.0
        }
        
        do {
            let audioFiles = try await analyzer.scanDirectory(at: directory)
            
            var tracks: [Track] = []
            for (index, audioFile) in audioFiles.enumerated() {
                // Extract features
                let features = try? await featureExtractor.extractFeatures(from: audioFile.url)
                let title = audioFile.url.deletingPathExtension().lastPathComponent
                
                // Classify track using model (if available)
                var predictedStyle: String? = nil
                var confidence: Double? = nil
                
                if let model = model {
                    if let classification = try? await classifyTrack(url: audioFile.url, model: model) {
                        predictedStyle = classification.label
                        confidence = classification.confidence
                    }
                }
                
                // Extract style from directory structure (parent folder name)
                let parentDir = audioFile.url.deletingLastPathComponent().lastPathComponent
                let style = (parentDir != directory.lastPathComponent) ? parentDir : nil
                
                tracks.append(Track(
                    url: audioFile.url,
                    title: title,
                    style: style,
                    features: features,
                    predictedStyle: predictedStyle,
                    confidence: confidence
                ))
                
                await MainActor.run {
                    classificationProgress = Double(index + 1) / Double(audioFiles.count)
                }
            }
            
            await MainActor.run {
                self.availableTracks = tracks
                self.isClassifying = false
                self.classificationProgress = 1.0
            }
        } catch {
            await MainActor.run {
                isClassifying = false
            }
            print("Error loading tracks: \(error)")
        }
    }
    
    /// Classifies a single track using the model
    private func classifyTrack(url: URL, model: MLModel) async throws -> ClassificationResult? {
        // For MLSoundClassifier, we typically classify the entire audio file
        // This is a simplified implementation - actual API may vary
        
        // Create input from audio file URL
        // Note: MLSoundClassifier model input format may require specific preprocessing
        // This is a placeholder that should be adjusted based on actual model requirements
        
        // For now, return nil - this needs to be implemented based on the actual
        // MLSoundClassifier model input/output format
        return nil
    }
    
    /// Recommends tracks based on selected style, tempo, and energy
    func recommendTracks(for style: String, tempo: Double? = nil, energy: Double? = nil) {
        var scoredTracks = availableTracks.map { track -> (Track, Double) in
            var score: Double = 0.0
            
            // Style match (prefer predicted style if available, fallback to directory-based style)
            let trackStyle = track.predictedStyle ?? track.style
            if trackStyle == style || style == "All" {
                score += 10.0
                // Boost score if we have high confidence in prediction
                if let confidence = track.confidence {
                    score += confidence * 5.0
                }
            }
            
            // Tempo match (if specified)
            if let targetTempo = tempo, let trackTempo = track.features?.tempo {
                let tempoDiff = abs(targetTempo - trackTempo)
                score += max(0, 5.0 - tempoDiff / 10.0) // Closer tempo = higher score
            }
            
            // Energy match (if specified)
            if let targetEnergy = energy, let trackEnergy = track.features?.energy {
                let energyDiff = abs(targetEnergy - trackEnergy)
                score += max(0, 5.0 - energyDiff * 10.0) // Closer energy = higher score
            }
            
            return (track, score)
        }
        
        // Sort by score and take top recommendations
        scoredTracks.sort { $0.1 > $1.1 }
        recommendedTracks = Array(scoredTracks.prefix(20).map { $0.0 })
    }
    
    struct ClassificationResult {
        let label: String
        let confidence: Double
    }
}
