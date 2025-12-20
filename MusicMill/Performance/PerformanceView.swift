import SwiftUI
import AppKit

struct PerformanceView: View {
    @StateObject private var styleController = StyleController()
    @StateObject private var trackSelector = TrackSelector()
    @StateObject private var playbackController = PlaybackController()
    @StateObject private var mixingEngine = MixingEngine()
    @EnvironmentObject var modelManager: ModelManager
    
    @State private var selectedTempo: Double = 120.0
    @State private var selectedEnergy: Double = 0.5
    @State private var selectedTrack: TrackSelector.Track?
    
    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar - Controls
            VStack(alignment: .leading, spacing: 20) {
                Text("Performance Controls")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.bottom)
                
                // Style selector
                VStack(alignment: .leading, spacing: 8) {
                    Text("Style")
                        .font(.headline)
                    Picker("Style", selection: $styleController.selectedStyle) {
                        Text("All Styles").tag(nil as String?)
                        ForEach(styleController.availableStyles, id: \.self) { style in
                            Text(style).tag(style as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Slider(value: $styleController.styleIntensity, in: 0...1) {
                        Text("Intensity")
                    }
                    Text("Intensity: \(Int(styleController.styleIntensity * 100))%")
                        .font(.caption)
                }
                
                Divider()
                
                // Tempo control
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tempo (BPM)")
                        .font(.headline)
                    Slider(value: $selectedTempo, in: 60...180, step: 1) {
                        Text("Tempo")
                    }
                    Text("\(Int(selectedTempo)) BPM")
                        .font(.caption)
                }
                
                Divider()
                
                // Energy control
                VStack(alignment: .leading, spacing: 8) {
                    Text("Energy")
                        .font(.headline)
                    Slider(value: $selectedEnergy, in: 0...1) {
                        Text("Energy")
                    }
                    Text("Energy: \(Int(selectedEnergy * 100))%")
                        .font(.caption)
                }
                
                Divider()
                
                // Playback controls
                VStack(alignment: .leading, spacing: 8) {
                    Text("Playback")
                        .font(.headline)
                    HStack {
                        Button(action: {
                            if playbackController.isPlaying {
                                playbackController.pause()
                            } else {
                                playbackController.play()
                            }
                        }) {
                            Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                        
                        Spacer()
                        
                        Slider(value: $playbackController.volume, in: 0...1) {
                            Text("Volume")
                        }
                        .frame(width: 100)
                    }
                }
                
                Spacer()
            }
            .padding()
            .frame(width: 300)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Main area - Track browser
            VStack(alignment: .leading, spacing: 0) {
                Text("Recommended Tracks")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding()
                
                List(trackSelector.recommendedTracks, id: \.url) { track in
                    TrackRow(track: track, isSelected: selectedTrack?.url == track.url)
                        .onTapGesture {
                            selectedTrack = track
                            playbackController.loadTrack(url: track.url)
                        }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            setupPerformance()
        }
        .onChange(of: styleController.selectedStyle) { _ in
            updateRecommendations()
        }
        .onChange(of: selectedTempo) { _ in
            updateRecommendations()
        }
        .onChange(of: selectedEnergy) { _ in
            updateRecommendations()
        }
    }
    
    private func setupPerformance() {
        // Update styles from model
        styleController.updateStyles(from: modelManager.modelLabels)
        
        // Set up track selector with model if available
        if let model = modelManager.currentModel {
            let liveInference = LiveInference()
            liveInference.setModel(model)
            trackSelector.setModel(model, liveInference: liveInference)
        }
    }
    
    private func updateRecommendations() {
        trackSelector.recommendTracks(
            for: styleController.selectedStyle ?? "All",
            tempo: selectedTempo,
            energy: selectedEnergy
        )
    }
}

struct TrackRow: View {
    let track: TrackSelector.Track
    let isSelected: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.headline)
                if let style = track.style ?? track.predictedStyle {
                    Text(style)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let tempo = track.features?.tempo {
                    Text("\(Int(tempo)) BPM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}

