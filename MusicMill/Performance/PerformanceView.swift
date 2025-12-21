import SwiftUI

struct PerformanceView: View {
    @StateObject private var styleController = StyleController()
    @StateObject private var trackSelector = TrackSelector()
    @StateObject private var playbackController = PlaybackController()
    @StateObject private var mixingEngine = MixingEngine()
    @EnvironmentObject var modelManager: ModelManager
    
    // Generation components
    @StateObject private var generationController = {
        let granularSynthesizer = GranularSynthesizer()
        let sampleLibrary = SampleLibrary()
        let sampleGenerator = SampleGenerator(granularSynthesizer: granularSynthesizer, sampleLibrary: sampleLibrary)
        let neuralGenerator = NeuralGenerator()
        let synthesisEngine = SynthesisEngine(sampleGenerator: sampleGenerator, neuralGenerator: neuralGenerator)
        return GenerationController(synthesisEngine: synthesisEngine, sampleLibrary: sampleLibrary)
    }()
    
    @State private var selectedTempo: Double = 120.0
    @State private var selectedEnergy: Double = 0.5
    @State private var selectedTrack: TrackSelector.Track?
    @State private var isGenerating = false
    @State private var hasLoadedSamples = false
    
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
                
                Divider()
                
                // Generation mode
                VStack(alignment: .leading, spacing: 8) {
                    Text("Generation Mode")
                        .font(.headline)
                    Picker("Mode", selection: $generationController.mode) {
                        Text("Granular").tag(SynthesisEngine.GenerationMode.granular)
                        Text("Neural").tag(SynthesisEngine.GenerationMode.neural)
                        Text("Hybrid").tag(SynthesisEngine.GenerationMode.hybrid)
                    }
                    .pickerStyle(.segmented)
                }
                
                Divider()
                
                // Generation controls
                VStack(alignment: .leading, spacing: 8) {
                    Text("Generation")
                        .font(.headline)
                    
                    // Loading status
                    if generationController.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(generationController.loadingStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(generationController.loadingStatus)
                            .font(.caption)
                            .foregroundColor(generationController.samplesLoaded > 0 ? .green : .secondary)
                    }
                    
                    HStack {
                        Button(action: {
                            if isGenerating {
                                generationController.stop()
                                isGenerating = false
                            } else {
                                do {
                                    try generationController.start()
                                    isGenerating = true
                                } catch {
                                    print("Failed to start generation: \(error)")
                                }
                            }
                        }) {
                            Image(systemName: isGenerating ? "stop.fill" : "play.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(generationController.samplesLoaded == 0 || generationController.isLoading)
                        
                        Spacer()
                        
                        // Reload button
                        Button(action: {
                            Task {
                                await generationController.loadAvailableSamples()
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(generationController.isLoading)
                    }
                }
                
                Divider()
                
                // Playback controls (for debug/example tracks)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Playback (Debug)")
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
        .onChange(of: styleController.selectedStyle) { newStyle in
            generationController.style = newStyle
            updateRecommendations()
        }
        .onChange(of: selectedTempo) { newTempo in
            generationController.tempo = newTempo
            updateRecommendations()
        }
        .onChange(of: selectedEnergy) { newEnergy in
            generationController.energy = newEnergy
            updateRecommendations()
        }
    }
    
    private func setupPerformance() {
        // Update styles from model
        styleController.updateStyles(from: modelManager.modelLabels)
        
        // Set up track selector with model if available
        if let model = modelManager.currentModel {
            trackSelector.setModel(model)
        }
        
        // Load samples from analysis if not already loaded
        if !hasLoadedSamples {
            hasLoadedSamples = true
            Task {
                await generationController.loadAvailableSamples()
                // Update style controller with available styles from samples
                await MainActor.run {
                    styleController.updateStyles(from: generationController.availableStyles)
                }
            }
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

