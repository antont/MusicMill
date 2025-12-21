import Foundation
import Combine

/// Connects performance controls (style/tempo/energy) to synthesis engine with low-latency parameter updates
class GenerationController: ObservableObject {
    
    @Published var style: String? = nil
    @Published var tempo: Double? = nil
    @Published var key: String? = nil
    @Published var energy: Double = 0.5
    @Published var mode: SynthesisEngine.GenerationMode = .granular
    
    private let synthesisEngine: SynthesisEngine
    private var cancellables = Set<AnyCancellable>()
    private var parameterUpdateTimer: Timer?
    
    init(synthesisEngine: SynthesisEngine) {
        self.synthesisEngine = synthesisEngine
        
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
        
        $mode
            .sink { [weak self] mode in
                self?.updateSynthesisMode(mode)
            }
            .store(in: &cancellables)
    }
    
    /// Updates synthesis parameters
    private func updateSynthesisParameters(style: String?, tempo: Double?, key: String?, energy: Double) {
        var params = SynthesisEngine.SynthesisParameters()
        params.style = style
        params.tempo = tempo
        params.key = key
        params.energy = energy
        params.mode = mode
        
        synthesisEngine.setParameters(params)
    }
    
    /// Updates synthesis mode
    private func updateSynthesisMode(_ mode: SynthesisEngine.GenerationMode) {
        var params = SynthesisEngine.SynthesisParameters()
        params.style = style
        params.tempo = tempo
        params.key = key
        params.energy = energy
        params.mode = mode
        
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
        
        var params = SynthesisEngine.SynthesisParameters()
        params.style = newStyle
        params.tempo = tempo
        params.key = key
        params.energy = energy
        params.mode = mode
        
        synthesisEngine.transitionToParameters(params, duration: duration)
    }
    
    /// Smoothly transitions to new tempo
    func transitionToTempo(_ newTempo: Double?, duration: TimeInterval = 2.0) {
        tempo = newTempo
        
        var params = SynthesisEngine.SynthesisParameters()
        params.style = style
        params.tempo = newTempo
        params.key = key
        params.energy = energy
        params.mode = mode
        
        synthesisEngine.transitionToParameters(params, duration: duration)
    }
    
    /// Smoothly transitions to new energy
    func transitionToEnergy(_ newEnergy: Double, duration: TimeInterval = 2.0) {
        energy = newEnergy
        
        var params = SynthesisEngine.SynthesisParameters()
        params.style = style
        params.tempo = tempo
        params.key = key
        params.energy = newEnergy
        params.mode = mode
        
        synthesisEngine.transitionToParameters(params, duration: duration)
    }
}

