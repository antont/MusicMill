import Foundation
import CoreML
import Combine

/// Manages track selection and recommendations based on style, tempo, and energy
class TrackSelector: ObservableObject {
    
    struct Track {
        let url: URL
        let title: String
        let style: String?
        let predictedStyle: String?
        let features: TrackFeatures?
    }
    
    struct TrackFeatures {
        let tempo: Double?
        let key: String?
        let energy: Double
    }
    
    @Published var recommendedTracks: [Track] = []
    @Published var allTracks: [Track] = []
    
    private var model: MLModel?
    
    init() {}
    
    func setModel(_ model: MLModel) {
        self.model = model
    }
    
    func loadTracks(from urls: [URL]) {
        allTracks = urls.map { url in
            Track(
                url: url,
                title: url.deletingPathExtension().lastPathComponent,
                style: nil,
                predictedStyle: nil,
                features: nil
            )
        }
    }
    
    func recommendTracks(for style: String, tempo: Double, energy: Double) {
        // Simple filtering based on style
        // In a full implementation, this would use ML predictions
        recommendedTracks = allTracks.filter { track in
            if style == "All" {
                return true
            }
            return track.style == style || track.predictedStyle == style
        }
        
        // Sort by relevance (placeholder - just by title)
        recommendedTracks.sort { $0.title < $1.title }
    }
    
    func addTrack(_ track: Track) {
        allTracks.append(track)
    }
    
    func clear() {
        allTracks.removeAll()
        recommendedTracks.removeAll()
    }
}
