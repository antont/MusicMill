import Foundation
import Combine

/// Connects performance controls (style/tempo/energy) to synthesis engine with low-latency parameter updates
class GenerationController: ObservableObject {
    
    @Published var style: String? = nil
    @Published var tempo: Double? = nil
    @Published var key: String? = nil
    @Published var energy: Double = 0.5
    @Published var backend: SynthesisEngine.SynthesisBackend = .concatenative
    @Published var isLoading: Bool = false
    @Published var loadingStatus: String = ""
    @Published var samplesLoaded: Int = 0
    @Published var availableStyles: [String] = []
    @Published var raveStatus: String = "Not started"
    @Published var raveStyles: [String] = []
    @Published var raveModels: [String] = []
    @Published var currentRaveModel: String = "percussion"
    
    private let synthesisEngine: SynthesisEngine
    private let sampleLibrary: SampleLibrary
    private var cancellables = Set<AnyCancellable>()
    private var parameterUpdateTimer: Timer?
    
    init(synthesisEngine: SynthesisEngine, sampleLibrary: SampleLibrary) {
        self.synthesisEngine = synthesisEngine
        self.sampleLibrary = sampleLibrary
        
        // Subscribe to parameter changes and update synthesis engine
        Publishers.CombineLatest4(
            $style,
            $tempo,
            $key,
            $energy
        )
        .debounce(for: .milliseconds(50), scheduler: RunLoop.main) // Low-latency updates
        .sink { [weak self] style, tempo, key, energy in
            self?.updateSynthesisParameters(style: style, tempo: tempo, key: key, energy: energy)
        }
        .store(in: &cancellables)
        
        $backend
            .sink { [weak self] backend in
                self?.updateSynthesisBackend(backend)
            }
            .store(in: &cancellables)
    }
    
    /// Updates synthesis parameters
    private func updateSynthesisParameters(style: String?, tempo: Double?, key: String?, energy: Double) {
        var params = SynthesisEngine.Parameters()
        params.style = style
        params.tempo = tempo
        params.key = key
        params.energy = energy
        params.backend = backend
        
        synthesisEngine.setParameters(params)
    }
    
    /// Updates synthesis backend
    private func updateSynthesisBackend(_ backend: SynthesisEngine.SynthesisBackend) {
        var params = SynthesisEngine.Parameters()
        params.style = style
        params.tempo = tempo
        params.key = key
        params.energy = energy
        params.backend = backend
        
        synthesisEngine.setParameters(params)
    }
    
    /// Starts generation
    func start() throws {
        try synthesisEngine.start()
    }
    
    /// Stops generation
    func stop() {
        synthesisEngine.stop()
    }
    
    /// Smoothly transitions to new style
    func transitionToStyle(_ newStyle: String?, duration: TimeInterval = 2.0) {
        style = newStyle
        updateSynthesisParameters(style: newStyle, tempo: tempo, key: key, energy: energy)
    }
    
    /// Smoothly transitions to new tempo
    func transitionToTempo(_ newTempo: Double?, duration: TimeInterval = 2.0) {
        tempo = newTempo
        updateSynthesisParameters(style: style, tempo: newTempo, key: key, energy: energy)
    }
    
    /// Smoothly transitions to new energy
    func transitionToEnergy(_ newEnergy: Double, duration: TimeInterval = 2.0) {
        energy = newEnergy
        updateSynthesisParameters(style: style, tempo: tempo, key: key, energy: newEnergy)
    }
    
    // MARK: - RAVE Server Management
    
    /// Starts the RAVE server for neural synthesis
    func startRAVEServer() async {
        await MainActor.run {
            raveStatus = "Starting server..."
        }
        
        do {
            try await synthesisEngine.startRAVEServer()
            
            await MainActor.run {
                raveStatus = "Server running"
                raveStyles = synthesisEngine.getRAVEStyles()
                
                // Add RAVE styles to available styles
                for style in raveStyles where !availableStyles.contains(style) {
                    availableStyles.append(style)
                }
            }
        } catch {
            await MainActor.run {
                raveStatus = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    /// Stops the RAVE server
    func stopRAVEServer() {
        synthesisEngine.stopRAVEServer()
        Task { @MainActor in
            raveStatus = "Stopped"
        }
    }
    
    /// Gets the current RAVE server status
    func updateRAVEStatus() {
        let status = synthesisEngine.getRAVEStatus()
        switch status {
        case .idle:
            raveStatus = "Not started"
        case .starting:
            raveStatus = "Starting..."
        case .running:
            raveStatus = "Running"
        case .error(let msg):
            raveStatus = "Error: \(msg)"
        }
    }
    
    /// Refreshes the list of available RAVE models
    func refreshRAVEModels() {
        raveModels = synthesisEngine.getAvailableRAVEModels()
        if let current = synthesisEngine.getCurrentRAVEModel() {
            currentRaveModel = current
        }
    }
    
    /// Switches to a different RAVE model
    func switchRAVEModel(to model: String) async {
        await MainActor.run {
            raveStatus = "Switching to \(model)..."
        }
        
        do {
            try await synthesisEngine.switchRAVEModel(to: model)
            
            await MainActor.run {
                currentRaveModel = model
                raveStatus = "Running (\(model))"
                raveStyles = synthesisEngine.getRAVEStyles()
            }
        } catch {
            await MainActor.run {
                raveStatus = "Error: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Sample Loading
    
    /// Loads samples from a previously analyzed collection
    func loadSamples(from collectionURL: URL) async {
        await MainActor.run {
            isLoading = true
            loadingStatus = "Loading samples..."
        }
        
        do {
            try await sampleLibrary.loadFromAnalysis(collectionURL: collectionURL)
            
            await MainActor.run {
                samplesLoaded = sampleLibrary.getStatistics().totalSamples
                availableStyles = sampleLibrary.getAvailableStyles()
                loadingStatus = "Loaded \(samplesLoaded) samples"
                isLoading = false
            }
        } catch {
            await MainActor.run {
                loadingStatus = "Error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
    
    /// Loads samples from segment files directly
    func loadSamples(from segmentURLs: [URL], style: String? = nil) async {
        await MainActor.run {
            isLoading = true
            loadingStatus = "Loading \(segmentURLs.count) segments..."
        }
        
        do {
            try await sampleLibrary.loadFromSegments(segmentURLs, style: style)
            
            await MainActor.run {
                samplesLoaded = sampleLibrary.getStatistics().totalSamples
                availableStyles = sampleLibrary.getAvailableStyles()
                loadingStatus = "Loaded \(samplesLoaded) samples"
                isLoading = false
            }
        } catch {
            await MainActor.run {
                loadingStatus = "Error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
    
    /// Finds and loads samples from any available analysis in Documents
    func loadAvailableSamples() async {
        await MainActor.run {
            isLoading = true
            loadingStatus = "Searching for analyzed collections..."
        }
        
        let storage = AnalysisStorage()
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let analysisDir = documentsURL.appendingPathComponent("MusicMill/Analysis")
        
        guard FileManager.default.fileExists(atPath: analysisDir.path) else {
            await MainActor.run {
                loadingStatus = "No analysis found. Analyze a collection first."
                isLoading = false
            }
            return
        }
        
        // Find all analysis directories
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: analysisDir, includingPropertiesForKeys: nil)
            var allSegments: [URL] = []
            
            for dir in contents where dir.hasDirectoryPath {
                let segmentsDir = dir.appendingPathComponent("Segments")
                if FileManager.default.fileExists(atPath: segmentsDir.path) {
                    let segments = try FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "m4a" }
                    allSegments.append(contentsOf: segments)
                }
            }
            
            if allSegments.isEmpty {
                await MainActor.run {
                    loadingStatus = "No segments found. Analyze a collection first."
                    isLoading = false
                }
                return
            }
            
            await MainActor.run {
                loadingStatus = "Loading \(allSegments.count) segments..."
            }
            
            try await sampleLibrary.loadFromSegments(allSegments, style: nil)
            
            await MainActor.run {
                samplesLoaded = sampleLibrary.getStatistics().totalSamples
                availableStyles = sampleLibrary.getAvailableStyles()
                loadingStatus = "Ready: \(samplesLoaded) samples loaded"
                isLoading = false
            }
        } catch {
            await MainActor.run {
                loadingStatus = "Error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}

