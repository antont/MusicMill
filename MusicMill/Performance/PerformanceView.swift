import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject var modelManager: ModelManager
    
    // Generation components
    @StateObject private var generationController = {
        let sampleLibrary = SampleLibrary()
        let synthesisEngine = SynthesisEngine(sampleLibrary: sampleLibrary)
        return GenerationController(synthesisEngine: synthesisEngine, sampleLibrary: sampleLibrary)
    }()
    
    @State private var isGenerating = false
    @State private var volume: Float = 0.8
    
    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar - Controls
            VStack(alignment: .leading, spacing: 16) {
                // Header
                Text("Performance")
                    .font(.title)
                    .fontWeight(.bold)
                
                // Backend selector
                VStack(alignment: .leading, spacing: 8) {
                    Text("Synthesis Mode")
                        .font(.headline)
                    Picker("Backend", selection: $generationController.backend) {
                        Text("Phrase").tag(SynthesisEngine.SynthesisBackend.phrase)
                        Text("Granular").tag(SynthesisEngine.SynthesisBackend.granular)
                        Text("RAVE").tag(SynthesisEngine.SynthesisBackend.rave)
                    }
                    .pickerStyle(.segmented)
                }
                
                Divider()
                
                // Backend-specific controls
                switch generationController.backend {
                case .phrase:
                    phraseControls
                case .granular, .concatenative:
                    granularControls
                case .rave, .hybrid:
                    raveControls
                }
                
                Divider()
                
                // Main play controls
                playbackControls
                
                Spacer()
                
                // Volume
                HStack {
                    Image(systemName: "speaker.fill")
                        .foregroundColor(.secondary)
                    Slider(value: $volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.secondary)
                }
                .onChange(of: volume) { _, newValue in
                    generationController.setVolume(newValue)
                }
            }
            .padding()
            .frame(width: 280)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Main area - Now Playing / Status
            VStack {
                Spacer()
                
                if isGenerating {
                    nowPlayingView
                } else {
                    readyToPlayView
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            generationController.refreshRAVEModels()
        }
    }
    
    // MARK: - Phrase Controls
    
    private var phraseControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Phrase Player")
                .font(.headline)
            
            Text("Plays musical segments with beat-aligned crossfades")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Load button
            Button(action: {
                Task {
                    await generationController.loadPhraseSegments()
                }
            }) {
                HStack {
                    Image(systemName: "waveform.badge.plus")
                    Text("Load Segments")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(generationController.isLoading)
            
            // Status
            HStack {
                if generationController.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Text(generationController.loadingStatus)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
        }
    }
    
    // MARK: - Granular Controls
    
    private var granularControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Granular Synthesis")
                .font(.headline)
            
            Text("Experimental - tiny audio grains, glitchy textures")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button(action: {
                Task {
                    await generationController.loadAvailableSamples()
                }
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Load Samples")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(generationController.isLoading)
            
            HStack {
                if generationController.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Text(generationController.loadingStatus)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
        }
    }
    
    // MARK: - RAVE Controls
    
    private var raveControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RAVE Neural Synthesis")
                .font(.headline)
            
            Text("AI-generated audio (requires trained model)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Model selector
            if !generationController.raveModels.isEmpty {
                Picker("Model", selection: $generationController.currentRaveModel) {
                    ForEach(generationController.raveModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .onChange(of: generationController.currentRaveModel) { _, newModel in
                    Task {
                        await generationController.switchRAVEModel(to: newModel)
                    }
                }
            }
            
            // Server status
            HStack {
                Circle()
                    .fill(raveStatusColor)
                    .frame(width: 8, height: 8)
                Text(generationController.raveStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Start") {
                    Task {
                        await generationController.startRAVEServer()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(generationController.raveStatus == "Running")
            }
        }
    }
    
    // MARK: - Playback Controls
    
    private var playbackControls: some View {
        VStack(spacing: 16) {
            // Big play/stop button
            Button(action: togglePlayback) {
                Image(systemName: isGenerating ? "stop.fill" : "play.fill")
                    .font(.system(size: 32))
                    .frame(width: 80, height: 80)
            }
            .buttonStyle(.borderedProminent)
            .tint(isGenerating ? .red : .green)
            .disabled(!canPlay)
            
            if !canPlay {
                Text("Load segments first")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Now Playing View
    
    private var nowPlayingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 80))
                .foregroundColor(.green)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            
            Text("Playing")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text(backendDescription)
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Ready View
    
    private var readyToPlayView: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 80))
                .foregroundColor(.secondary)
            
            Text("Ready")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            if canPlay {
                Text("Press play to start \(generationController.backend.rawValue) synthesis")
                    .font(.title3)
                    .foregroundColor(.secondary)
            } else {
                Text("Load segments to begin")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Helpers
    
    private var canPlay: Bool {
        switch generationController.backend {
        case .phrase:
            return generationController.loadingStatus.contains("loaded")
        case .granular, .concatenative:
            return generationController.samplesLoaded > 0
        case .rave, .hybrid:
            return generationController.raveStatus == "Running"
        }
    }
    
    private var statusColor: Color {
        if generationController.isLoading {
            return .secondary
        } else if generationController.loadingStatus.contains("loaded") || generationController.loadingStatus.contains("Ready") {
            return .green
        } else if generationController.loadingStatus.contains("Error") {
            return .red
        }
        return .secondary
    }
    
    private var raveStatusColor: Color {
        switch generationController.raveStatus {
        case "Running":
            return .green
        case let status where status.hasPrefix("Starting"):
            return .yellow
        case let status where status.hasPrefix("Error"):
            return .red
        default:
            return .gray
        }
    }
    
    private var backendDescription: String {
        switch generationController.backend {
        case .phrase:
            return "Phrase Player - Musical Segments"
        case .granular:
            return "Granular Synthesis"
        case .concatenative:
            return "Concatenative Synthesis"
        case .rave:
            return "RAVE Neural Audio"
        case .hybrid:
            return "Hybrid Mode"
        }
    }
    
    private func togglePlayback() {
        if isGenerating {
            generationController.stop()
            isGenerating = false
        } else {
            do {
                try generationController.start()
                isGenerating = true
            } catch {
                print("Failed to start: \(error)")
            }
        }
    }
}
