import Foundation
import Combine
import CoreML

/// Intelligently selects tracks based on model predictions and user preferences
class TrackSelector: ObservableObject {
    @Published var availableTracks: [Track] = []
    @Published var recommendedTracks: [Track] = []
    
    private var model: MLModel?
    private var liveInference: LiveInference?
    
    struct Track {
        let url: URL
        let title: String
        let style: String?
        let features: FeatureExtractor.AudioFeatures?
        let predictedStyle: String?
        let confidence: Double?
    }
    
    /// Sets the model for intelligent selection
    func setModel(_ model: MLModel, liveInference: LiveInference) {
        self.model = model
        self.liveInference = liveInference
    }
    
    /// Loads tracks from a directory
    func loadTracks(from directory: URL) async {
        let analyzer = AudioAnalyzer()
        let featureExtractor = FeatureExtractor()
        
        do {
            let audioFiles = try await analyzer.scanDirectory(at: directory)
            
            var tracks: [Track] = []
            for audioFile in audioFiles {
                let features = try? await featureExtractor.extractFeatures(from: audioFile.url)
                let title = audioFile.url.deletingPathExtension().lastPathComponent
                
                tracks.append(Track(
                    url: audioFile.url,
                    title: title,
                    style: nil, // Would come from directory structure or metadata
                    features: features,
                    predictedStyle: nil,
                    confidence: nil
                ))
            }
            
            await MainActor.run {
                self.availableTracks = tracks
            }
        } catch {
            print("Error loading tracks: \(error)")
        }
    }
    
    /// Recommends tracks based on selected style
    func recommendTracks(for style: String, tempo: Double? = nil, energy: Double? = nil) {
        var scoredTracks = availableTracks.map { track -> (Track, Double) in
            var score: Double = 0.0
            
            // Style match
            if track.style == style || track.predictedStyle == style {
                score += 10.0
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
    
    /// Predicts style for a track using the model
    func predictStyle(for track: Track) async {
        // This would use live inference to classify the track
        // Placeholder for now
    }
}

