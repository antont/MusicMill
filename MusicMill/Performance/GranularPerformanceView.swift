import SwiftUI
import Combine

/// Dedicated performance view for Granular Synthesis - experimental glitchy textures
struct GranularPerformanceView: View {
    @StateObject private var controller = GranularController()
    
    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar - Controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Granular Synthesis")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Experimental - tiny audio grains for glitchy textures")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Divider()
                    
                    // Load samples
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Library")
                            .font(.headline)
                        
                        Button(action: {
                            Task {
                                await controller.loadSamples()
                            }
                        }) {
                            HStack {
                                Image(systemName: "folder.badge.plus")
                                Text("Load Samples")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(controller.isLoading)
                        
                        HStack {
                            if controller.isLoading {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text(controller.status)
                                .font(.caption)
                                .foregroundColor(controller.sampleCount > 0 ? .green : .secondary)
                        }
                    }
                    
                    Divider()
                    
                    // Grain parameters
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Grain Parameters")
                            .font(.headline)
                        
                        // Grain size
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Size")
                                Spacer()
                                Text("\(Int(controller.grainSize * 1000)) ms")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $controller.grainSize, in: 0.01...0.5)
                        }
                        
                        // Grain density
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Density")
                                Spacer()
                                Text("\(Int(controller.grainDensity)) /sec")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $controller.grainDensity, in: 1...50)
                        }
                        
                        // Position jitter
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Position Jitter")
                                Spacer()
                                Text("\(Int(controller.positionJitter * 100))%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $controller.positionJitter, in: 0...1)
                        }
                        
                        // Pitch jitter
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Pitch Jitter")
                                Spacer()
                                Text("\(Int(controller.pitchJitter * 100))%")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $controller.pitchJitter, in: 0...0.5)
                        }
                    }
                    
                    Divider()
                    
                    // Envelope
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Envelope")
                            .font(.headline)
                        
                        Picker("", selection: $controller.envelope) {
                            Text("Hann").tag(GranularSynthesizer.EnvelopeType.hann)
                            Text("Blackman").tag(GranularSynthesizer.EnvelopeType.blackman)
                            Text("Triangle").tag(GranularSynthesizer.EnvelopeType.triangle)
                            Text("Hamming").tag(GranularSynthesizer.EnvelopeType.hamming)
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Divider()
                    
                    // Advanced
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Advanced")
                            .font(.headline)
                        
                        Toggle("Zero-crossing start", isOn: $controller.zeroCrossingStart)
                        Toggle("Rhythm alignment", isOn: $controller.rhythmAlignment)
                        Toggle("Position evolution", isOn: $controller.positionEvolution)
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
                        .disabled(controller.sampleCount == 0)
                    }
                    .frame(maxWidth: .infinity)
                    
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
            }
            .frame(width: 280)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Main area
            VStack {
                Spacer()
                
                if controller.isPlaying {
                    VStack(spacing: 20) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 80))
                            .foregroundColor(.orange)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                        
                        Text("Generating")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Granular Synthesis")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        
                        // Show current parameters
                        VStack(spacing: 4) {
                            Text("Grain: \(Int(controller.grainSize * 1000))ms @ \(Int(controller.grainDensity))/sec")
                            Text("Jitter: pos \(Int(controller.positionJitter * 100))%, pitch \(Int(controller.pitchJitter * 100))%")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 80))
                            .foregroundColor(.secondary)
                        
                        Text("Granular Synthesis")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        
                        if controller.sampleCount > 0 {
                            Text("Press play to start")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Load samples to begin")
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
class GranularController: ObservableObject {
    @Published var isLoading = false
    @Published var isPlaying = false
    @Published var status = "No samples loaded"
    @Published var sampleCount = 0
    @Published var volume: Float = 0.8
    
    // Grain parameters
    @Published var grainSize: Double = 0.1 // 100ms
    @Published var grainDensity: Double = 15.0
    @Published var positionJitter: Double = 0.05
    @Published var pitchJitter: Double = 0.01
    @Published var envelope: GranularSynthesizer.EnvelopeType = .blackman
    @Published var zeroCrossingStart = true
    @Published var rhythmAlignment = true
    @Published var positionEvolution = true
    
    private let synthesisEngine: SynthesisEngine
    private let sampleLibrary: SampleLibrary
    
    init() {
        self.sampleLibrary = SampleLibrary()
        self.synthesisEngine = SynthesisEngine(sampleLibrary: sampleLibrary)
    }
    
    func loadSamples() async {
        isLoading = true
        status = "Scanning for samples..."
        
        // Look for analysis in Documents
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let analysisDir = documentsURL.appendingPathComponent("MusicMill/Analysis")
        
        guard FileManager.default.fileExists(atPath: analysisDir.path) else {
            status = "No analysis found. Run analysis first."
            isLoading = false
            return
        }
        
        do {
            // Find segment files
            var segmentURLs: [URL] = []
            let contents = try FileManager.default.contentsOfDirectory(at: analysisDir, includingPropertiesForKeys: nil)
            for dir in contents where dir.hasDirectoryPath {
                let segmentsDir = dir.appendingPathComponent("Segments")
                if FileManager.default.fileExists(atPath: segmentsDir.path) {
                    let segments = try FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "m4a" || $0.pathExtension == "wav" }
                    segmentURLs.append(contentsOf: segments)
                }
            }
            
            if segmentURLs.isEmpty {
                status = "No segments found"
                isLoading = false
                return
            }
            
            status = "Loading \(segmentURLs.count) segments..."
            
            // Load into granular synthesizer
            let synth = synthesisEngine.getGranularSynthesizer()
            for (index, url) in segmentURLs.prefix(10).enumerated() {
                try? synth.loadSource(from: url, identifier: "seg_\(index)")
            }
            
            sampleCount = synth.getSourceIdentifiers().count
            status = "\(sampleCount) samples loaded"
            
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    func togglePlayback() {
        if isPlaying {
            synthesisEngine.stop()
            isPlaying = false
        } else {
            do {
                // Set backend
                var engineParams = SynthesisEngine.Parameters()
                engineParams.backend = .granular
                engineParams.masterVolume = volume
                synthesisEngine.setParameters(engineParams)
                
                // Set granular parameters
                let synth = synthesisEngine.getGranularSynthesizer()
                var params = GranularSynthesizer.GrainParameters()
                params.grainSize = grainSize
                params.grainDensity = grainDensity
                params.positionJitter = Float(positionJitter)
                params.pitchJitter = Float(pitchJitter)
                params.envelopeType = envelope
                params.zeroCrossingStart = zeroCrossingStart
                params.rhythmAlignment = rhythmAlignment ? 0.8 : 0
                params.positionEvolution = positionEvolution ? 0.2 : 0
                params.amplitude = volume
                synth.parameters = params
                
                try synthesisEngine.start()
                isPlaying = true
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
        }
    }
}

