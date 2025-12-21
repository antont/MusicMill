import Foundation
import AVFoundation
import Combine

/// High-level sample-based generation using granular synthesis
class SampleGenerator: ObservableObject {
    
    private let granularSynthesizer: GranularSynthesizer
    private let sampleLibrary: SampleLibrary
    
    struct GenerationParameters {
        var style: String?
        var tempo: Double?
        var key: String?
        var energy: Double?
        var grainSize: TimeInterval = 0.05
        var grainDensity: Double = 20.0
        var pitch: Float = 1.0
        var pan: Float = 0.0
        var amplitude: Float = 0.8
        var positionJitter: Float = 0.1
        var pitchJitter: Float = 0.02
    }
    
    @Published private(set) var isPlaying = false
    @Published private(set) var currentSampleName: String = "None"
    @Published private(set) var loadedSampleCount: Int = 0
    
    private var currentParameters = GenerationParameters()
    private var currentSample: SampleLibrary.Sample?
    private var loadedSampleIDs: Set<String> = []
    
    init(granularSynthesizer: GranularSynthesizer, sampleLibrary: SampleLibrary) {
        self.granularSynthesizer = granularSynthesizer
        self.sampleLibrary = sampleLibrary
    }
    
    /// Sets generation parameters
    func setParameters(_ parameters: GenerationParameters) {
        currentParameters = parameters
        
        // Update granular synthesizer parameters
        var grainParams = GranularSynthesizer.GrainParameters()
        grainParams.grainSize = parameters.grainSize
        grainParams.grainDensity = parameters.grainDensity
        grainParams.pitch = parameters.pitch
        grainParams.pan = parameters.pan
        grainParams.amplitude = parameters.amplitude
        grainParams.positionJitter = parameters.positionJitter
        grainParams.pitchJitter = parameters.pitchJitter
        granularSynthesizer.parameters = grainParams
        
        // Select new sample if style/tempo/key changed significantly
        selectSampleIfNeeded()
    }
    
    /// Selects a sample matching current parameters and loads it
    private func selectSampleIfNeeded() {
        let candidates = sampleLibrary.findSamples(
            style: currentParameters.style,
            tempo: currentParameters.tempo,
            key: currentParameters.key,
            energy: currentParameters.energy,
            limit: 10
        )
        
        guard !candidates.isEmpty else { return }
        
        // Pick a random candidate that's different from current
        let newSample = candidates.filter { $0.id != currentSample?.id }.randomElement() ?? candidates.first!
        
        if newSample.id != currentSample?.id {
            loadSample(newSample)
        }
    }
    
    /// Loads a sample into the granular synthesizer
    private func loadSample(_ sample: SampleLibrary.Sample) {
        do {
            // Load buffer if not already loaded
            if let buffer = try sampleLibrary.loadBuffer(for: sample.id) {
                granularSynthesizer.loadSourceBuffer(buffer, identifier: sample.id)
                currentSample = sample
                loadedSampleIDs.insert(sample.id)
                
                DispatchQueue.main.async {
                    self.currentSampleName = sample.metadata.sourceTrack ?? sample.id
                    self.loadedSampleCount = self.loadedSampleIDs.count
                }
            }
        } catch {
            print("Failed to load sample \(sample.id): \(error)")
        }
    }
    
    /// Loads multiple samples for variety
    func preloadSamples(style: String? = nil, count: Int = 10) {
        let samples = sampleLibrary.findSamples(style: style, limit: count)
        
        for sample in samples {
            if !loadedSampleIDs.contains(sample.id) {
                loadSample(sample)
            }
        }
    }
    
    /// Cycles to the next available sample
    func nextSample() {
        let loadedIDs = granularSynthesizer.getSourceIdentifiers()
        guard loadedIDs.count > 1 else { return }
        
        if let currentID = currentSample?.id,
           let currentIndex = loadedIDs.firstIndex(of: currentID) {
            let nextIndex = (currentIndex + 1) % loadedIDs.count
            granularSynthesizer.setSourceIndex(nextIndex)
            
            // Find the sample for this ID
            if let sample = sampleLibrary.getAllSamples().first(where: { $0.id == loadedIDs[nextIndex] }) {
                currentSample = sample
                DispatchQueue.main.async {
                    self.currentSampleName = sample.metadata.sourceTrack ?? sample.id
                }
            }
        }
    }
    
    /// Sets playback position (0-1) within current sample
    func setPosition(_ position: Float) {
        granularSynthesizer.setPosition(position)
    }
    
    /// Starts generation
    func start() throws {
        // Ensure we have at least one sample loaded
        if currentSample == nil {
            selectSampleIfNeeded()
        }
        
        guard currentSample != nil else {
            throw GeneratorError.noSamplesLoaded
        }
        
        try granularSynthesizer.start()
        
        DispatchQueue.main.async {
            self.isPlaying = true
        }
    }
    
    /// Stops generation
    func stop() {
        granularSynthesizer.stop()
        
        DispatchQueue.main.async {
            self.isPlaying = false
        }
    }
    
    /// Smoothly transitions to new parameters (async to avoid blocking)
    func transitionToParameters(_ parameters: GenerationParameters, duration: TimeInterval = 2.0) {
        Task {
            let startParams = currentParameters
            let steps = Int(duration * 20) // 20 updates per second
            let stepDuration = duration / Double(steps)
            
            for step in 0...steps {
                let progress = Double(step) / Double(steps)
                
                var interpolated = GenerationParameters()
                interpolated.style = parameters.style
                interpolated.tempo = interpolate(start: startParams.tempo ?? 120.0, end: parameters.tempo ?? 120.0, progress: progress)
                interpolated.key = parameters.key
                interpolated.energy = interpolate(start: startParams.energy ?? 0.5, end: parameters.energy ?? 0.5, progress: progress)
                interpolated.grainSize = interpolate(start: startParams.grainSize, end: parameters.grainSize, progress: progress)
                interpolated.grainDensity = interpolate(start: startParams.grainDensity, end: parameters.grainDensity, progress: progress)
                interpolated.pitch = Float(interpolate(start: Double(startParams.pitch), end: Double(parameters.pitch), progress: progress))
                interpolated.pan = Float(interpolate(start: Double(startParams.pan), end: Double(parameters.pan), progress: progress))
                interpolated.amplitude = Float(interpolate(start: Double(startParams.amplitude), end: Double(parameters.amplitude), progress: progress))
                interpolated.positionJitter = Float(interpolate(start: Double(startParams.positionJitter), end: Double(parameters.positionJitter), progress: progress))
                interpolated.pitchJitter = Float(interpolate(start: Double(startParams.pitchJitter), end: Double(parameters.pitchJitter), progress: progress))
                
                setParameters(interpolated)
                
                if step < steps {
                    try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
                }
            }
            
            currentParameters = parameters
        }
    }
    
    /// Interpolates between two values
    private func interpolate(start: Double, end: Double, progress: Double) -> Double {
        return start + (end - start) * progress
    }
    
    /// Gets available styles from the library
    func getAvailableStyles() -> [String] {
        return sampleLibrary.getAvailableStyles()
    }
    
    /// Gets library statistics
    func getLibraryStatistics() -> SampleLibrary.LibraryStatistics {
        return sampleLibrary.getStatistics()
    }
    
    /// Gets the output node for connecting to audio engine
    func getOutputNode() -> AVAudioNode {
        return granularSynthesizer.getOutputNode()
    }
    
    /// Gets the audio engine for external connections
    func getAudioEngine() -> AVAudioEngine {
        return granularSynthesizer.getAudioEngine()
    }
    
    enum GeneratorError: LocalizedError {
        case noSamplesLoaded
        
        var errorDescription: String? {
            switch self {
            case .noSamplesLoaded:
                return "No samples loaded in library"
            }
        }
    }
}


