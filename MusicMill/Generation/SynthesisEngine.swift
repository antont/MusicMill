import Foundation
import AVFoundation

/// Unified interface for real-time audio generation, supporting multiple synthesis backends
class SynthesisEngine {
    
    // MARK: - Types
    
    enum SynthesisBackend: String, CaseIterable {
        case phrase = "Phrase"           // Beat-aligned phrase playback (recommended)
        case granular = "Granular"       // Classic granular synthesis (tiny grains)
        case concatenative = "Concatenative" // Longer segments with crossfading
        case rave = "RAVE"               // Neural synthesis via RAVE
        case hybrid = "Hybrid"           // Combined approaches
        
        var description: String {
            switch self {
            case .phrase:
                return "Phrase - beat-aligned musical segments, smooth flow"
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
        var backend: SynthesisBackend = .phrase  // Default to phrase mode
        var style: String?
        var tempo: Double?
        var key: String?
        var energy: Double = 0.5
        var masterVolume: Float = 1.0
    }
    
    // MARK: - Properties
    
    private var phrasePlayer: PhrasePlayer?
    private var granularSynthesizer: GranularSynthesizer?
    private var concatenativeSynthesizer: ConcatenativeSynthesizer?
    private var raveSynthesizer: RAVESynthesizer?
    
    private var currentBackend: SynthesisBackend = .phrase  // Default to phrase mode
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
    
    /// Gets or creates the phrase player
    private func getPhrasePlayer() -> PhrasePlayer {
        if phrasePlayer == nil {
            phrasePlayer = PhrasePlayer()
        }
        return phrasePlayer!
    }
    
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
        case .phrase:
            // Available if phrase player has phrases loaded
            return phrasePlayer?.phraseCount ?? 0 > 0
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
        case .phrase:
            let player = getPhrasePlayer()
            var phraseParams = PhrasePlayer.Parameters()
            phraseParams.masterVolume = params.masterVolume
            phraseParams.targetStyle = params.style
            phraseParams.targetTempo = params.tempo
            phraseParams.targetEnergy = params.energy
            player.parameters = phraseParams
            
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
    
    /// Loads phrases from librosa analysis for the PhrasePlayer
    func loadPhrasesFromAnalysis(collectionURL: URL) async throws {
        let storage = AnalysisStorage()
        
        guard let analysis = try storage.loadAnalysis(for: collectionURL) else {
            throw SynthesisError.noSamplesLoaded
        }
        
        let player = getPhrasePlayer()
        var loadedCount = 0
        
        for audioFile in analysis.audioFiles {
            guard let features = audioFile.features,
                  features.beats != nil else {
                // Skip files without beat analysis
                continue
            }
            
            let url = URL(fileURLWithPath: audioFile.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            
            do {
                try player.loadPhrase(from: url, id: url.lastPathComponent, analysis: features)
                loadedCount += 1
                
                // Limit for memory
                if loadedCount >= 20 {
                    break
                }
            } catch {
                print("Warning: Could not load phrase from \(url.lastPathComponent): \(error)")
            }
        }
        
        #if DEBUG
        print("[SynthesisEngine] Loaded \(loadedCount) phrases for PhrasePlayer")
        #endif
    }
    
    /// Loads phrase segments from the prepared segments.json file
    func loadPhraseSegments() async throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let segmentsDir = documentsURL.appendingPathComponent("MusicMill/PhraseSegments")
        let segmentsJSON = segmentsDir.appendingPathComponent("segments.json")
        
        guard FileManager.default.fileExists(atPath: segmentsJSON.path) else {
            throw SynthesisError.noSamplesLoaded
        }
        
        let data = try Data(contentsOf: segmentsJSON)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let segments = json?["segments"] as? [[String: Any]] else {
            throw SynthesisError.noSamplesLoaded
        }
        
        let player = getPhrasePlayer()
        var loadedCount = 0
        
        for segment in segments {
            guard let filePath = segment["file"] as? String,
                  let tempo = segment["tempo"] as? Double,
                  let segmentType = segment["type"] as? String,
                  let beats = segment["beats"] as? [Double],
                  let downbeats = segment["downbeats"] as? [Double],
                  let energy = segment["energy"] as? Double else {
                continue
            }
            
            let url = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("Warning: Segment file not found: \(filePath)")
                continue
            }
            
            do {
                // Load audio buffer
                let file = try AVAudioFile(forReading: url)
                let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                    continue
                }
                try file.read(into: buffer)
                
                // Load into phrase player
                player.loadPhrase(
                    id: url.lastPathComponent,
                    buffer: buffer,
                    beats: beats,
                    downbeats: downbeats,
                    tempo: tempo,
                    energy: energy,
                    segmentType: segmentType,
                    style: nil
                )
                
                loadedCount += 1
                
                // Limit for memory
                if loadedCount >= 30 {
                    break
                }
            } catch {
                print("Warning: Could not load segment \(url.lastPathComponent): \(error)")
            }
        }
        
        #if DEBUG
        print("[SynthesisEngine] Loaded \(loadedCount) phrase segments")
        #endif
        
        if loadedCount == 0 {
            throw SynthesisError.noSamplesLoaded
        }
    }
    
    /// Gets phrase player for direct access
    func getPhrasePlayerForUI() -> PhrasePlayer {
        return getPhrasePlayer()
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
        case .phrase:
            try getPhrasePlayer().start()
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
        phrasePlayer?.stop()
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
        case .phrase:
            return nil // PhrasePlayer manages its own engine internally
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
