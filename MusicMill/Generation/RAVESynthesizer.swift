import Foundation
import AVFoundation
import CoreML
import Accelerate

/// RAVE (Realtime Audio Variational autoEncoder) synthesizer
/// Uses neural network to generate continuous audio from latent space
class RAVESynthesizer {
    
    // MARK: - Types
    
    struct Parameters {
        var latentDimension: Int = 16 // RAVE latent space dimension
        var chunkSize: Int = 2048 // Audio samples per inference
        var masterVolume: Float = 1.0
        var latentInterpolation: Float = 0.1 // How fast to interpolate between latent vectors
    }
    
    enum RAVEError: LocalizedError {
        case modelNotLoaded
        case encoderNotLoaded
        case decoderNotLoaded
        case inferenceError(String)
        case invalidInput
        
        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "RAVE model not loaded"
            case .encoderNotLoaded:
                return "RAVE encoder not loaded"
            case .decoderNotLoaded:
                return "RAVE decoder not loaded"
            case .inferenceError(let msg):
                return "Inference error: \(msg)"
            case .invalidInput:
                return "Invalid input for RAVE model"
            }
        }
    }
    
    // MARK: - Properties
    
    private var encoder: MLModel?
    private var decoder: MLModel?
    
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double = 44100.0
    
    private var parameters = Parameters()
    private var isPlaying = false
    
    // Latent space navigation
    private var currentLatent: [Float] = []
    private var targetLatent: [Float] = []
    
    private let latentLock = NSLock()
    
    // Audio buffer for output
    private var outputBuffer: [Float] = []
    private var outputBufferPosition: Int = 0
    private let outputLock = NSLock()
    
    // MARK: - Initialization
    
    init() {
        // Initialize latent vectors
        currentLatent = [Float](repeating: 0, count: parameters.latentDimension)
        targetLatent = [Float](repeating: 0, count: parameters.latentDimension)
        
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.renderAudio(frameCount: frameCount, audioBufferList: audioBufferList)
        }
        
        guard let sourceNode = sourceNode else { return }
        
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
    }
    
    // MARK: - Model Loading
    
    /// Loads RAVE encoder model from bundle or URL
    func loadEncoder(from url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine // Use Neural Engine for speed
        
        encoder = try MLModel(contentsOf: url, configuration: config)
        print("RAVE encoder loaded from: \(url.lastPathComponent)")
    }
    
    /// Loads RAVE decoder model from bundle or URL
    func loadDecoder(from url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        
        decoder = try MLModel(contentsOf: url, configuration: config)
        print("RAVE decoder loaded from: \(url.lastPathComponent)")
    }
    
    /// Loads models from app bundle
    func loadModelsFromBundle() throws {
        // Look for models in the bundle
        guard let encoderURL = Bundle.main.url(forResource: "RAVESynthesizerEncoder", withExtension: "mlmodelc"),
              let decoderURL = Bundle.main.url(forResource: "RAVESynthesizerDecoder", withExtension: "mlmodelc") else {
            // Try mlpackage format
            if let encoderURL = Bundle.main.url(forResource: "RAVESynthesizerEncoder", withExtension: "mlpackage"),
               let decoderURL = Bundle.main.url(forResource: "RAVESynthesizerDecoder", withExtension: "mlpackage") {
                try loadEncoder(from: encoderURL)
                try loadDecoder(from: decoderURL)
                return
            }
            throw RAVEError.modelNotLoaded
        }
        
        try loadEncoder(from: encoderURL)
        try loadDecoder(from: decoderURL)
    }
    
    /// Check if models are loaded
    var isModelLoaded: Bool {
        return decoder != nil
    }
    
    // MARK: - Latent Space Control
    
    /// Sets the target latent vector directly
    func setTargetLatent(_ latent: [Float]) {
        latentLock.lock()
        targetLatent = latent
        // Pad or truncate to match dimension
        if targetLatent.count < parameters.latentDimension {
            targetLatent.append(contentsOf: [Float](repeating: 0, count: parameters.latentDimension - targetLatent.count))
        } else if targetLatent.count > parameters.latentDimension {
            targetLatent = Array(targetLatent.prefix(parameters.latentDimension))
        }
        latentLock.unlock()
    }
    
    /// Sets target latent based on style/tempo/energy (normalized 0-1)
    func setTarget(style: Float, tempo: Float, energy: Float) {
        // Map parameters to latent dimensions
        // This is a simple mapping - could be learned from data
        var latent = [Float](repeating: 0, count: parameters.latentDimension)
        
        // Use first few dimensions for main parameters
        if parameters.latentDimension >= 3 {
            latent[0] = (style - 0.5) * 4.0 // Map 0-1 to -2..2
            latent[1] = (tempo - 0.5) * 4.0
            latent[2] = (energy - 0.5) * 4.0
        }
        
        // Add some variation to other dimensions
        for i in 3..<parameters.latentDimension {
            latent[i] = Float.random(in: -0.5...0.5)
        }
        
        setTargetLatent(latent)
    }
    
    /// Randomizes the target latent
    func randomizeTarget() {
        var latent = [Float](repeating: 0, count: parameters.latentDimension)
        for i in 0..<parameters.latentDimension {
            latent[i] = Float.random(in: -2...2)
        }
        setTargetLatent(latent)
    }
    
    // MARK: - Playback Control
    
    /// Starts audio generation
    func start() throws {
        guard decoder != nil else {
            throw RAVEError.decoderNotLoaded
        }
        
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        isPlaying = true
        
        // Prime the output buffer
        generateNextChunk()
    }
    
    /// Stops audio generation
    func stop() {
        isPlaying = false
        audioEngine.stop()
    }
    
    /// Updates parameters
    func setParameters(_ params: Parameters) {
        parameters = params
        
        // Resize latent vectors if dimension changed
        latentLock.lock()
        if currentLatent.count != params.latentDimension {
            currentLatent = [Float](repeating: 0, count: params.latentDimension)
            targetLatent = [Float](repeating: 0, count: params.latentDimension)
        }
        latentLock.unlock()
    }
    
    /// Gets audio engine for external connections
    func getAudioEngine() -> AVAudioEngine {
        return audioEngine
    }
    
    // MARK: - Audio Generation
    
    private func generateNextChunk() {
        guard let decoder = decoder else { return }
        
        // Interpolate current latent toward target
        latentLock.lock()
        for i in 0..<currentLatent.count {
            currentLatent[i] += (targetLatent[i] - currentLatent[i]) * parameters.latentInterpolation
        }
        let latent = currentLatent
        latentLock.unlock()
        
        // Create input for decoder
        do {
            // Prepare latent input array
            // Shape: [1, latentDim, 1] for single chunk
            let latentArray = try MLMultiArray(shape: [1, NSNumber(value: parameters.latentDimension), 1], dataType: .float32)
            for i in 0..<parameters.latentDimension {
                latentArray[i] = NSNumber(value: latent[i])
            }
            
            // Create feature provider
            let input = try MLDictionaryFeatureProvider(dictionary: ["latent": latentArray])
            
            // Run inference
            let output = try decoder.prediction(from: input)
            
            // Extract audio from output
            if let audioOutput = output.featureValue(for: "audio")?.multiArrayValue {
                var newAudio = [Float](repeating: 0, count: parameters.chunkSize)
                
                for i in 0..<min(audioOutput.count, parameters.chunkSize) {
                    newAudio[i] = audioOutput[i].floatValue * parameters.masterVolume
                }
                
                // Append to output buffer
                outputLock.lock()
                outputBuffer.append(contentsOf: newAudio)
                outputLock.unlock()
            }
        } catch {
            print("RAVE inference error: \(error)")
        }
    }
    
    private func renderAudio(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard ablPointer.count >= 2 else { return noErr }
        
        let leftOut = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let rightOut = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        guard isPlaying else {
            // Fill with silence
            for i in 0..<Int(frameCount) {
                leftOut?[i] = 0
                rightOut?[i] = 0
            }
            return noErr
        }
        
        outputLock.lock()
        
        for i in 0..<Int(frameCount) {
            // Check if we need more audio
            if outputBufferPosition >= outputBuffer.count - parameters.chunkSize {
                outputLock.unlock()
                generateNextChunk()
                outputLock.lock()
            }
            
            // Get sample
            let sample: Float
            if outputBufferPosition < outputBuffer.count {
                sample = outputBuffer[outputBufferPosition]
                outputBufferPosition += 1
            } else {
                sample = 0
            }
            
            leftOut?[i] = sample
            rightOut?[i] = sample
            
            // Trim buffer periodically to prevent memory growth
            if outputBufferPosition > 88200 { // ~2 seconds
                outputBuffer.removeFirst(44100)
                outputBufferPosition -= 44100
            }
        }
        
        outputLock.unlock()
        
        return noErr
    }
    
    // MARK: - Encoding (for analysis/style transfer)
    
    /// Encodes audio to latent space (requires encoder model)
    func encode(audio: [Float]) throws -> [Float] {
        guard let encoder = encoder else {
            throw RAVEError.encoderNotLoaded
        }
        
        // Prepare input
        let audioArray = try MLMultiArray(shape: [1, 1, NSNumber(value: audio.count)], dataType: .float32)
        for i in 0..<audio.count {
            audioArray[i] = NSNumber(value: audio[i])
        }
        
        let input = try MLDictionaryFeatureProvider(dictionary: ["audio": audioArray])
        let output = try encoder.prediction(from: input)
        
        guard let latentOutput = output.featureValue(for: "latent")?.multiArrayValue else {
            throw RAVEError.inferenceError("No latent output")
        }
        
        var latent = [Float](repeating: 0, count: latentOutput.count)
        for i in 0..<latentOutput.count {
            latent[i] = latentOutput[i].floatValue
        }
        
        return latent
    }
    
    /// Encodes audio file and returns average latent vector
    func encodeFile(url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RAVEError.invalidInput
        }
        
        try file.read(into: buffer)
        
        guard let channelData = buffer.floatChannelData else {
            throw RAVEError.invalidInput
        }
        
        // Convert to mono
        var monoData = [Float](repeating: 0, count: Int(buffer.frameLength))
        let channelCount = Int(format.channelCount)
        
        for i in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for ch in 0..<channelCount {
                sum += channelData[ch][i]
            }
            monoData[i] = sum / Float(channelCount)
        }
        
        // Encode in chunks and average
        var latentSum = [Float](repeating: 0, count: parameters.latentDimension)
        var chunkCount = 0
        
        let chunkSize = parameters.chunkSize
        for start in stride(from: 0, to: monoData.count - chunkSize, by: chunkSize) {
            let chunk = Array(monoData[start..<(start + chunkSize)])
            let latent = try encode(audio: chunk)
            
            for i in 0..<min(latent.count, parameters.latentDimension) {
                latentSum[i] += latent[i]
            }
            chunkCount += 1
        }
        
        // Average
        if chunkCount > 0 {
            for i in 0..<parameters.latentDimension {
                latentSum[i] /= Float(chunkCount)
            }
        }
        
        return latentSum
    }
}

