import Foundation
import AVFoundation

/// Unified interface for real-time audio generation, supporting granular, neural, and hybrid approaches
class SynthesisEngine {
    
    enum GenerationMode {
        case granular // Sample-based granular synthesis
        case neural // Pure neural synthesis
        case hybrid // Combined granular + neural
    }
    
    private let sampleGenerator: SampleGenerator
    private let neuralGenerator: NeuralGenerator
    private var currentMode: GenerationMode = .granular
    private var audioEngine: AVAudioEngine
    private var mixerNode: AVAudioMixerNode
    
    struct SynthesisParameters {
        var style: String?
        var tempo: Double?
        var key: String?
        var energy: Double?
        var mode: GenerationMode = .granular
    }
    
    init(sampleGenerator: SampleGenerator, neuralGenerator: NeuralGenerator) {
        self.sampleGenerator = sampleGenerator
        self.neuralGenerator = neuralGenerator
        
        audioEngine = AVAudioEngine()
        mixerNode = audioEngine.mainMixerNode
        audioEngine.prepare()
    }
    
    /// Sets synthesis parameters
    func setParameters(_ parameters: SynthesisParameters) {
        currentMode = parameters.mode
        
        switch parameters.mode {
        case .granular:
            var grainParams = SampleGenerator.GenerationParameters()
            grainParams.style = parameters.style
            grainParams.tempo = parameters.tempo
            grainParams.key = parameters.key
            grainParams.energy = parameters.energy
            sampleGenerator.setParameters(grainParams)
            
        case .neural:
            var neuralParams = NeuralGenerator.GenerationParameters()
            // Convert style string to float embedding (simplified)
            neuralParams.style = parameters.style != nil ? 0.5 : 0.5
            neuralParams.tempo = parameters.tempo != nil ? Float((parameters.tempo! - 60.0) / 120.0) : 0.5
            neuralParams.energy = Float(parameters.energy ?? 0.5)
            neuralGenerator.setParameters(neuralParams)
            
        case .hybrid:
            // Use both generators
            var grainParams = SampleGenerator.GenerationParameters()
            grainParams.style = parameters.style
            grainParams.tempo = parameters.tempo
            grainParams.key = parameters.key
            grainParams.energy = parameters.energy
            sampleGenerator.setParameters(grainParams)
            
            var neuralParams = NeuralGenerator.GenerationParameters()
            neuralParams.style = parameters.style != nil ? 0.5 : 0.5
            neuralParams.tempo = parameters.tempo != nil ? Float((parameters.tempo! - 60.0) / 120.0) : 0.5
            neuralParams.energy = Float(parameters.energy ?? 0.5)
            neuralGenerator.setParameters(neuralParams)
        }
    }
    
    /// Starts synthesis
    func start() throws {
        try audioEngine.start()
        
        switch currentMode {
        case .granular:
            try sampleGenerator.start()
        case .neural:
            try neuralGenerator.start()
        case .hybrid:
            try sampleGenerator.start()
            try neuralGenerator.start()
        }
    }
    
    /// Stops synthesis
    func stop() {
        switch currentMode {
        case .granular:
            sampleGenerator.stop()
        case .neural:
            neuralGenerator.stop()
        case .hybrid:
            sampleGenerator.stop()
            neuralGenerator.stop()
        }
        
        audioEngine.stop()
    }
    
    /// Smoothly transitions to new parameters
    func transitionToParameters(_ parameters: SynthesisParameters, duration: TimeInterval = 2.0) {
        // Transition based on mode
        switch parameters.mode {
        case .granular:
            var grainParams = SampleGenerator.GenerationParameters()
            grainParams.style = parameters.style
            grainParams.tempo = parameters.tempo
            grainParams.key = parameters.key
            grainParams.energy = parameters.energy
            sampleGenerator.transitionToParameters(grainParams, duration: duration)
            
        case .neural:
            var neuralParams = NeuralGenerator.GenerationParameters()
            neuralParams.style = parameters.style != nil ? 0.5 : 0.5
            neuralParams.tempo = parameters.tempo != nil ? Float((parameters.tempo! - 60.0) / 120.0) : 0.5
            neuralParams.energy = Float(parameters.energy ?? 0.5)
            neuralGenerator.setParameters(neuralParams)
            
        case .hybrid:
            // Transition both
            var grainParams = SampleGenerator.GenerationParameters()
            grainParams.style = parameters.style
            grainParams.tempo = parameters.tempo
            grainParams.key = parameters.key
            grainParams.energy = parameters.energy
            sampleGenerator.transitionToParameters(grainParams, duration: duration)
            
            var neuralParams = NeuralGenerator.GenerationParameters()
            neuralParams.style = parameters.style != nil ? 0.5 : 0.5
            neuralParams.tempo = parameters.tempo != nil ? Float((parameters.tempo! - 60.0) / 120.0) : 0.5
            neuralParams.energy = Float(parameters.energy ?? 0.5)
            neuralGenerator.setParameters(neuralParams)
        }
        
        currentMode = parameters.mode
    }
    
    /// Gets the output node for connecting to audio engine
    func getOutputNode() -> AVAudioNode {
        return mixerNode
    }
}


