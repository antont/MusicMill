import Foundation
import AVFoundation

/// Unified interface for real-time audio generation, supporting multiple synthesis backends
class SynthesisEngine {
    
    // MARK: - Types
    
    enum SynthesisBackend: String, CaseIterable {
        case granular = "Granular"       // Classic granular synthesis (tiny grains)
        case concatenative = "Concatenative" // Longer segments with crossfading
        case rave = "RAVE"               // Neural synthesis via RAVE
        case hybrid = "Hybrid"           // Combined approaches
        
        var description: String {
            switch self {
            case .granular:
                return "Granular synthesis - tiny audio grains, glitchy/textural"
            case .concatenative:
                return "Concatenative - full phrases, smooth crossfades"
            case .rave:
                return "RAVE neural - AI-generated continuous audio"
            case .hybrid:
                return "Hybrid - combines granular + neural"
            }
        }
    }
    
    struct Parameters {
        var backend: SynthesisBackend = .concatenative
        var style: String?
        var tempo: Double?
        var key: String?
        var energy: Double = 0.5
        var masterVolume: Float = 1.0
    }
    
    // MARK: - Properties
    
    private var granularSynthesizer: GranularSynthesizer?
    private var concatenativeSynthesizer: ConcatenativeSynthesizer?
    private var raveSynthesizer: RAVESynthesizer?
    
    private var currentBackend: SynthesisBackend = .concatenative
    private var isPlaying = false
    
    private var sampleLibrary: SampleLibrary?
    
    // MARK: - Initialization
    
    init() {
        // Synthesizers are created lazily when needed
    }
    
    /// Initialize with a sample library for granular/concatenative synthesis
    convenience init(sampleLibrary: SampleLibrary) {
        self.init()
        self.sampleLibrary = sampleLibrary
    }
    
    // MARK: - Backend Management
    
    /// Gets or creates the granular synthesizer
    private func getGranularSynthesizer() -> GranularSynthesizer {
        if granularSynthesizer == nil {
            granularSynthesizer = GranularSynthesizer()
        }
        return granularSynthesizer!
    }
    
    /// Gets or creates the concatenative synthesizer
    private func getConcatenativeSynthesizer() -> ConcatenativeSynthesizer {
        if concatenativeSynthesizer == nil {
            concatenativeSynthesizer = ConcatenativeSynthesizer()
        }
        return concatenativeSynthesizer!
    }
    
    /// Gets or creates the RAVE synthesizer
    private func getRaveSynthesizer() -> RAVESynthesizer {
        if raveSynthesizer == nil {
            raveSynthesizer = RAVESynthesizer()
        }
        return raveSynthesizer!
    }
    
    /// Checks if a backend is available
    func isBackendAvailable(_ backend: SynthesisBackend) -> Bool {
        switch backend {
        case .granular, .concatenative:
            // Available if we have samples loaded
            return sampleLibrary?.getAvailableStyles().count ?? 0 > 0
        case .rave:
            // Available if RAVE server is running
            return raveSynthesizer?.isServerRunning ?? false
        case .hybrid:
            // Available if both granular and neural are available
            return isBackendAvailable(.granular) && isBackendAvailable(.rave)
        }
    }
    
    /// Gets list of available backends
    func getAvailableBackends() -> [SynthesisBackend] {
        return SynthesisBackend.allCases.filter { isBackendAvailable($0) }
    }
    
    // MARK: - Parameter Control
    
    /// Sets synthesis parameters
    func setParameters(_ params: Parameters) {
        currentBackend = params.backend
        
        switch params.backend {
        case .granular:
            let synth = getGranularSynthesizer()
            var grainParams = GranularSynthesizer.GrainParameters()
            grainParams.amplitude = params.masterVolume
            synth.parameters = grainParams
            
        case .concatenative:
            let synth = getConcatenativeSynthesizer()
            var concatParams = ConcatenativeSynthesizer.Parameters()
            concatParams.masterVolume = params.masterVolume
            synth.setParameters(concatParams)
            
        case .rave:
            let synth = getRaveSynthesizer()
            synth.setVolume(params.masterVolume)
            // Set style and parameters
            if let style = params.style {
                synth.setStyle(style)
            }
            synth.setEnergy(Float(params.energy))
            if let tempo = params.tempo {
                synth.setTempoFactor(Float(tempo / 120.0))  // Normalize to 120 BPM base
            }
            
        case .hybrid:
            // Configure both
            let granular = getGranularSynthesizer()
            var grainParams = GranularSynthesizer.GrainParameters()
            grainParams.amplitude = params.masterVolume * 0.5 // Half volume each
            granular.parameters = grainParams
            
            let rave = getRaveSynthesizer()
            rave.setVolume(params.masterVolume * 0.5)
            if let style = params.style {
                rave.setStyle(style)
            }
            rave.setEnergy(Float(params.energy))
        }
    }
    
    /// Sets the active backend
    func setBackend(_ backend: SynthesisBackend) throws {
        guard isBackendAvailable(backend) else {
            throw SynthesisError.backendNotAvailable(backend)
        }
        
        let wasPlaying = isPlaying
        if wasPlaying {
            stop()
        }
        
        currentBackend = backend
        
        if wasPlaying {
            try start()
        }
    }
    
    /// Gets current backend
    func getCurrentBackend() -> SynthesisBackend {
        return currentBackend
    }
    
    // MARK: - Sample Loading
    
    /// Loads a sample into the appropriate synthesizers
    func loadSample(from url: URL, identifier: String, style: String? = nil) async throws {
        // Load into granular
        try getGranularSynthesizer().loadSource(from: url, identifier: identifier)
        
        // Load into concatenative
        try await getConcatenativeSynthesizer().loadSegment(from: url, identifier: identifier, style: style)
    }
    
    /// Loads samples from sample library
    func loadFromLibrary() async throws {
        guard let library = sampleLibrary else {
            throw SynthesisError.noSamplesLoaded
        }
        
        let samples = library.getAllSamples()
        for sample in samples.prefix(10) { // Limit for memory
            if let buffer = sample.buffer {
                let granular = getGranularSynthesizer()
                granular.loadSourceBuffer(buffer, identifier: sample.id)
                
                let concat = getConcatenativeSynthesizer()
                concat.loadSegment(from: buffer, identifier: sample.id, style: sample.metadata.style)
            }
        }
    }
    
    /// Starts RAVE server
    func startRAVEServer() async throws {
        let rave = getRaveSynthesizer()
        try await rave.startServer()
    }
    
    /// Stops RAVE server
    func stopRAVEServer() {
        raveSynthesizer?.stopServer()
    }
    
    /// Gets available RAVE styles
    func getRAVEStyles() -> [String] {
        return raveSynthesizer?.availableStyles ?? []
    }
    
    /// Gets RAVE server status
    func getRAVEStatus() -> RAVEBridge.Status {
        return raveSynthesizer?.serverStatus ?? .idle
    }
    
    /// Gets available RAVE models
    func getAvailableRAVEModels() -> [String] {
        return RAVESynthesizer.getAvailableModels()
    }
    
    /// Gets current RAVE model name
    func getCurrentRAVEModel() -> String? {
        return raveSynthesizer?.currentModel
    }
    
    /// Switches RAVE to a different model
    func switchRAVEModel(to model: String) async throws {
        guard let rave = raveSynthesizer else { return }
        try await rave.switchModel(to: model)
    }
    
    /// Gets RAVE bridge diagnostics
    func getRAVEDiagnostics() -> [String: String] {
        // Create a bridge temporarily just to get diagnostics if needed
        let rave = getRaveSynthesizer()
        return rave.getDiagnostics()
    }
    
    // MARK: - Playback Control
    
    /// Starts synthesis with current backend
    func start() throws {
        switch currentBackend {
        case .granular:
            try getGranularSynthesizer().start()
        case .concatenative:
            try getConcatenativeSynthesizer().start()
        case .rave:
            try getRaveSynthesizer().start()
        case .hybrid:
            try getGranularSynthesizer().start()
            try getRaveSynthesizer().start()
        }
        isPlaying = true
    }
    
    /// Stops synthesis
    func stop() {
        granularSynthesizer?.stop()
        concatenativeSynthesizer?.stop()
        raveSynthesizer?.stop()
        isPlaying = false
    }
    
    /// Checks if currently playing
    func isCurrentlyPlaying() -> Bool {
        return isPlaying
    }
    
    /// Gets audio engine for the current backend
    func getAudioEngine() -> AVAudioEngine? {
        switch currentBackend {
        case .granular:
            return granularSynthesizer?.getAudioEngine()
        case .concatenative:
            return concatenativeSynthesizer?.getAudioEngine()
        case .rave:
            return raveSynthesizer?.getAudioEngine()
        case .hybrid:
            // Return granular engine (they should share somehow in a real impl)
            return granularSynthesizer?.getAudioEngine()
        }
    }
    
    // MARK: - Errors
    
    enum SynthesisError: LocalizedError {
        case backendNotAvailable(SynthesisBackend)
        case noSamplesLoaded
        case modelLoadFailed
        
        var errorDescription: String? {
            switch self {
            case .backendNotAvailable(let backend):
                return "\(backend.rawValue) backend is not available"
            case .noSamplesLoaded:
                return "No samples loaded for synthesis"
            case .modelLoadFailed:
                return "Failed to load synthesis model"
            }
        }
    }
}
