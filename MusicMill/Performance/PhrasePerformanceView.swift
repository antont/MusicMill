import SwiftUI
import Combine

/// Dedicated performance view for Phrase Player - musical segment playback
struct PhrasePerformanceView: View {
    @StateObject private var controller = PhraseController()
    
    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar - Controls
            VStack(alignment: .leading, spacing: 16) {
                Text("Phrase Player")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("Beat-aligned musical segments with smooth crossfades")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Divider()
                
                // Load segments
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library")
                        .font(.headline)
                    
                    Button(action: {
                        Task {
                            await controller.loadSegments()
                        }
                    }) {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                            Text("Load Phrase Segments")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isLoading)
                    
                    // Status
                    HStack {
                        if controller.isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                        Text(controller.status)
                            .font(.caption)
                            .foregroundColor(controller.phraseCount > 0 ? .green : .secondary)
                    }
                    
                    if controller.phraseCount > 0 {
                        Text("\(controller.phraseCount) phrases ready")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                Divider()
                
                // Crossfade settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Crossfade")
                        .font(.headline)
                    
                    HStack {
                        Text("Bars:")
                        Picker("", selection: $controller.crossfadeBars) {
                            Text("1").tag(1)
                            Text("2").tag(2)
                            Text("4").tag(4)
                            Text("8").tag(8)
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Text("Crossfade duration in musical bars")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Play controls
                VStack(spacing: 16) {
                    Button(action: controller.togglePlayback) {
                        Image(systemName: controller.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 32))
                            .frame(width: 80, height: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isPlaying ? .red : .green)
                    .disabled(controller.phraseCount == 0)
                }
                .frame(maxWidth: .infinity)
                
                Spacer()
                
                // Volume
                HStack {
                    Image(systemName: "speaker.fill")
                        .foregroundColor(.secondary)
                    Slider(value: $controller.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .frame(width: 280)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Main area
            VStack {
                Spacer()
                
                if controller.isPlaying {
                    VStack(spacing: 20) {
                        Image(systemName: "waveform")
                            .font(.system(size: 80))
                            .foregroundColor(.green)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                        
                        Text("Playing")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        if let current = controller.currentPhrase {
                            Text(current)
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 80))
                            .foregroundColor(.secondary)
                        
                        Text("Phrase Player")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        
                        if controller.phraseCount > 0 {
                            Text("Press play to start")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Load phrase segments to begin")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Controller

@MainActor
class PhraseController: ObservableObject {
    @Published var isLoading = false
    @Published var isPlaying = false
    @Published var status = "No segments loaded"
    @Published var phraseCount = 0
    @Published var currentPhrase: String?
    @Published var volume: Float = 0.8
    @Published var crossfadeBars: Int = 2
    
    private let synthesisEngine: SynthesisEngine
    
    init() {
        let sampleLibrary = SampleLibrary()
        self.synthesisEngine = SynthesisEngine(sampleLibrary: sampleLibrary)
    }
    
    func loadSegments() async {
        isLoading = true
        status = "Loading..."
        
        do {
            try await synthesisEngine.loadPhraseSegments()
            
            // Get count from phrase player
            let player = synthesisEngine.getPhrasePlayer()
            phraseCount = player.phraseCount
            
            status = "Loaded"
        } catch {
            status = "Error: \(error.localizedDescription)"
            phraseCount = 0
        }
        
        isLoading = false
    }
    
    func togglePlayback() {
        if isPlaying {
            synthesisEngine.stop()
            isPlaying = false
            currentPhrase = nil
        } else {
            do {
                // Set parameters
                var params = SynthesisEngine.Parameters()
                params.backend = .phrase
                params.masterVolume = volume
                synthesisEngine.setParameters(params)
                
                // Update crossfade bars
                let player = synthesisEngine.getPhrasePlayer()
                var phraseParams = player.parameters
                phraseParams.crossfadeBars = crossfadeBars
                phraseParams.masterVolume = volume
                player.parameters = phraseParams
                
                try synthesisEngine.start()
                isPlaying = true
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
        }
    }
}

