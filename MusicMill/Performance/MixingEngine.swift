import Foundation
import AVFoundation
import Combine

/// Handles real-time audio mixing with crossfade, volume, and EQ
/// Now supports both generated audio and track playback
class MixingEngine: ObservableObject {
    private var audioEngine: AVAudioEngine
    private var players: [AVAudioPlayerNode] = []
    private var files: [AVAudioFile] = []
    private var mixerNode: AVAudioMixerNode
    private var eqNodes: [AVAudioUnitEQ] = []
    private var generationInput: AVAudioNode?
    
    init() {
        audioEngine = AVAudioEngine()
        mixerNode = audioEngine.mainMixerNode
    }
    
    /// Connects generated audio input to the mixer
    func connectGenerationInput(_ node: AVAudioNode, format: AVAudioFormat) {
        if let existingInput = generationInput {
            audioEngine.disconnectNodeInput(existingInput)
        }
        
        generationInput = node
        audioEngine.attach(node)
        audioEngine.connect(node, to: mixerNode, format: format)
    }
    
    /// Adds a track to the mixer
    func addTrack(url: URL) throws -> Int {
        let playerNode = AVAudioPlayerNode()
        let file = try AVAudioFile(forReading: url)
        
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: mixerNode, format: file.processingFormat)
        
        players.append(playerNode)
        files.append(file)
        
        // Create EQ node for this track
        let eqNode = AVAudioUnitEQ(numberOfBands: 3)
        audioEngine.attach(eqNode)
        audioEngine.connect(playerNode, to: eqNode, format: file.processingFormat)
        audioEngine.connect(eqNode, to: mixerNode, format: file.processingFormat)
        eqNodes.append(eqNode)
        
        return players.count - 1
    }
    
    /// Starts playback of a track
    func playTrack(at index: Int) {
        guard index < players.count && index < files.count else { return }
        
        let playerNode = players[index]
        let file = files[index]
        playerNode.scheduleFile(file, at: nil)
        playerNode.play()
    }
    
    /// Crossfades between two tracks
    func crossfade(from fromIndex: Int, to toIndex: Int, duration: TimeInterval) {
        guard fromIndex < players.count && toIndex < players.count else { return }
        
        let fromPlayer = players[fromIndex]
        let toPlayer = players[toIndex]
        
        // Fade out first track
        fromPlayer.volume = 1.0
        // In a real implementation, you'd animate the volume over duration
        
        // Fade in second track
        toPlayer.volume = 0.0
        // In a real implementation, you'd animate the volume over duration
    }
    
    /// Sets volume for a track
    func setVolume(_ volume: Float, forTrack index: Int) {
        guard index < players.count else { return }
        players[index].volume = max(0.0, min(1.0, volume))
    }
    
    /// Sets EQ parameters for a track
    func setEQ(band: Int, frequency: Float, gain: Float, forTrack index: Int) {
        guard index < eqNodes.count, band < eqNodes[index].bands.count else { return }
        
        let eqBand = eqNodes[index].bands[band]
        eqBand.frequency = frequency
        eqBand.gain = gain
        eqBand.bandwidth = 1.0
        eqBand.bypass = false
    }
    
    /// Starts the audio engine
    func start() throws {
        try audioEngine.start()
    }
    
    /// Stops the audio engine
    func stop() {
        audioEngine.stop()
        players.forEach { $0.stop() }
    }
}

