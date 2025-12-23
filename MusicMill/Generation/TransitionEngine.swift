import Foundation
import AVFoundation
import Accelerate

/// DJ-style transition engine with beat-aligned EQ crossfading
///
/// Supports multiple transition types:
/// - Crossfade: Simple volume blend
/// - EQ Swap: DJ-style mixing with bass swap
/// - Filter: Low-pass/high-pass sweep
/// - Cut: Hard cut on beat
class TransitionEngine {
    
    // MARK: - Types
    
    enum TransitionType: String {
        case crossfade  // Simple volume crossfade
        case eqSwap     // DJ-style EQ mixing
        case filter     // Filter sweep
        case cut        // Hard cut on beat
    }
    
    enum TransitionState {
        case idle
        case starting       // Waiting for beat to start
        case transitioning  // Actively transitioning
        case complete
    }
    
    struct TransitionConfig {
        var type: TransitionType = .eqSwap
        var durationBars: Int = 2           // Transition length in musical bars
        var tempo: Double = 120.0           // Current tempo for timing
        var startOnDownbeat: Bool = true    // Wait for downbeat to start
        var eqCutoffLow: Float = 200.0      // Hz - low band cutoff
        var eqCutoffHigh: Float = 2000.0    // Hz - high band cutoff
    }
    
    /// Progress callback for UI updates
    typealias ProgressCallback = (Float) -> Void
    
    // MARK: - Properties
    
    private let sampleRate: Double = 44100.0
    private var config = TransitionConfig()
    
    // EQ filter coefficients
    private var lowPassCoeffs: [Float] = []
    private var highPassCoeffs: [Float] = []
    
    // Filter state (for biquad filters)
    private var outgoingLowState: [Float] = [0, 0, 0, 0]
    private var outgoingHighState: [Float] = [0, 0, 0, 0]
    private var incomingLowState: [Float] = [0, 0, 0, 0]
    private var incomingHighState: [Float] = [0, 0, 0, 0]
    
    private var state: TransitionState = .idle
    private var transitionProgress: Float = 0.0  // 0 to 1
    private var transitionSamples: Int = 0       // Total samples for transition
    private var currentSample: Int = 0           // Current position
    
    private var progressCallback: ProgressCallback?
    
    // MARK: - Initialization
    
    init() {
        setupEQFilters()
    }
    
    // MARK: - Configuration
    
    /// Configure the transition
    func configure(_ config: TransitionConfig) {
        self.config = config
        
        // Calculate transition duration in samples
        let beatsPerBar = 4.0
        let secondsPerBeat = 60.0 / config.tempo
        let transitionSeconds = Double(config.durationBars) * beatsPerBar * secondsPerBeat
        transitionSamples = Int(transitionSeconds * sampleRate)
        
        // Update EQ filters if cutoffs changed
        setupEQFilters()
    }
    
    /// Set progress callback for UI updates
    func setProgressCallback(_ callback: @escaping ProgressCallback) {
        self.progressCallback = callback
    }
    
    // MARK: - EQ Filter Setup
    
    private func setupEQFilters() {
        // Simple biquad low-pass filter coefficients
        // Using Butterworth design
        let lowCutoff = config.eqCutoffLow / Float(sampleRate / 2)
        let highCutoff = config.eqCutoffHigh / Float(sampleRate / 2)
        
        lowPassCoeffs = computeBiquadLowPass(cutoff: lowCutoff)
        highPassCoeffs = computeBiquadHighPass(cutoff: highCutoff)
    }
    
    /// Compute biquad low-pass filter coefficients
    private func computeBiquadLowPass(cutoff: Float) -> [Float] {
        let omega = 2.0 * Float.pi * cutoff
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * 0.707)  // Q = 0.707 (Butterworth)
        
        let b0 = (1.0 - cosOmega) / 2.0
        let b1 = 1.0 - cosOmega
        let b2 = (1.0 - cosOmega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha
        
        // Normalize by a0
        return [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
    }
    
    /// Compute biquad high-pass filter coefficients
    private func computeBiquadHighPass(cutoff: Float) -> [Float] {
        let omega = 2.0 * Float.pi * cutoff
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * 0.707)
        
        let b0 = (1.0 + cosOmega) / 2.0
        let b1 = -(1.0 + cosOmega)
        let b2 = (1.0 + cosOmega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha
        
        return [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
    }
    
    // MARK: - Transition Control
    
    /// Start a transition
    func start() {
        state = .transitioning
        currentSample = 0
        transitionProgress = 0.0
        
        // Reset filter states
        outgoingLowState = [0, 0, 0, 0]
        outgoingHighState = [0, 0, 0, 0]
        incomingLowState = [0, 0, 0, 0]
        incomingHighState = [0, 0, 0, 0]
    }
    
    /// Reset the transition engine
    func reset() {
        state = .idle
        transitionProgress = 0.0
        currentSample = 0
    }
    
    /// Check if transition is complete
    var isComplete: Bool {
        state == .complete
    }
    
    /// Get current progress (0-1)
    var progress: Float {
        transitionProgress
    }
    
    // MARK: - Audio Processing
    
    /// Process audio samples for transition
    ///
    /// - Parameters:
    ///   - outgoingLeft: Outgoing track left channel
    ///   - outgoingRight: Outgoing track right channel
    ///   - incomingLeft: Incoming track left channel
    ///   - incomingRight: Incoming track right channel
    ///   - outputLeft: Output buffer left channel
    ///   - outputRight: Output buffer right channel
    ///   - frameCount: Number of frames to process
    func process(
        outgoingLeft: UnsafePointer<Float>,
        outgoingRight: UnsafePointer<Float>,
        incomingLeft: UnsafePointer<Float>,
        incomingRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        switch config.type {
        case .crossfade:
            processCrossfade(
                outgoingLeft: outgoingLeft, outgoingRight: outgoingRight,
                incomingLeft: incomingLeft, incomingRight: incomingRight,
                outputLeft: outputLeft, outputRight: outputRight,
                frameCount: frameCount
            )
            
        case .eqSwap:
            processEQSwap(
                outgoingLeft: outgoingLeft, outgoingRight: outgoingRight,
                incomingLeft: incomingLeft, incomingRight: incomingRight,
                outputLeft: outputLeft, outputRight: outputRight,
                frameCount: frameCount
            )
            
        case .filter:
            processFilter(
                outgoingLeft: outgoingLeft, outgoingRight: outgoingRight,
                incomingLeft: incomingLeft, incomingRight: incomingRight,
                outputLeft: outputLeft, outputRight: outputRight,
                frameCount: frameCount
            )
            
        case .cut:
            processCut(
                outgoingLeft: outgoingLeft, outgoingRight: outgoingRight,
                incomingLeft: incomingLeft, incomingRight: incomingRight,
                outputLeft: outputLeft, outputRight: outputRight,
                frameCount: frameCount
            )
        }
        
        // Update progress
        currentSample += frameCount
        transitionProgress = Float(currentSample) / Float(max(1, transitionSamples))
        
        if transitionProgress >= 1.0 {
            state = .complete
            transitionProgress = 1.0
        }
        
        progressCallback?(transitionProgress)
    }
    
    // MARK: - Transition Types
    
    /// Simple volume crossfade with equal-power curve
    private func processCrossfade(
        outgoingLeft: UnsafePointer<Float>,
        outgoingRight: UnsafePointer<Float>,
        incomingLeft: UnsafePointer<Float>,
        incomingRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        for i in 0..<frameCount {
            let sampleProgress = Float(currentSample + i) / Float(max(1, transitionSamples))
            let clampedProgress = min(1.0, max(0.0, sampleProgress))
            
            // Equal-power crossfade curve
            let fadeOut = cos(clampedProgress * Float.pi / 2)
            let fadeIn = sin(clampedProgress * Float.pi / 2)
            
            outputLeft[i] = outgoingLeft[i] * fadeOut + incomingLeft[i] * fadeIn
            outputRight[i] = outgoingRight[i] * fadeOut + incomingRight[i] * fadeIn
        }
    }
    
    /// DJ-style EQ swap: bring in highs first, then swap bass
    private func processEQSwap(
        outgoingLeft: UnsafePointer<Float>,
        outgoingRight: UnsafePointer<Float>,
        incomingLeft: UnsafePointer<Float>,
        incomingRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        for i in 0..<frameCount {
            let sampleProgress = Float(currentSample + i) / Float(max(1, transitionSamples))
            let clampedProgress = min(1.0, max(0.0, sampleProgress))
            
            // Phase 1 (0-50%): Bring in incoming highs, keep outgoing bass
            // Phase 2 (50-100%): Swap bass, fade out outgoing highs
            
            let outgoingLowGain: Float
            let outgoingHighGain: Float
            let incomingLowGain: Float
            let incomingHighGain: Float
            
            if clampedProgress < 0.5 {
                // First half: bring in incoming mids/highs
                let phase1Progress = clampedProgress * 2.0  // 0 to 1
                outgoingLowGain = 1.0
                outgoingHighGain = 1.0 - phase1Progress * 0.3  // Slight reduction
                incomingLowGain = 0.0
                incomingHighGain = phase1Progress
            } else {
                // Second half: swap bass
                let phase2Progress = (clampedProgress - 0.5) * 2.0  // 0 to 1
                outgoingLowGain = 1.0 - phase2Progress
                outgoingHighGain = 0.7 - phase2Progress * 0.7
                incomingLowGain = phase2Progress
                incomingHighGain = 1.0
            }
            
            // Apply simple frequency separation using the filters
            // For simplicity, we use a basic approach here
            // In production, we'd use proper 3-band EQ
            
            let outgoingMono = (outgoingLeft[i] + outgoingRight[i]) * 0.5
            let incomingMono = (incomingLeft[i] + incomingRight[i]) * 0.5
            
            // Simple bass approximation (low-pass)
            let outgoingBass = applyBiquad(
                sample: outgoingMono,
                coeffs: lowPassCoeffs,
                state: &outgoingLowState
            )
            let incomingBass = applyBiquad(
                sample: incomingMono,
                coeffs: lowPassCoeffs,
                state: &incomingLowState
            )
            
            // Mids+Highs = original - bass (approximation)
            let outgoingHigh = outgoingMono - outgoingBass
            let incomingHigh = incomingMono - incomingBass
            
            // Mix
            let mixed = outgoingBass * outgoingLowGain +
                       outgoingHigh * outgoingHighGain +
                       incomingBass * incomingLowGain +
                       incomingHigh * incomingHighGain
            
            // Preserve stereo by scaling original stereo signals
            let outgoingScale = outgoingLowGain * 0.5 + outgoingHighGain * 0.5
            let incomingScale = incomingLowGain * 0.5 + incomingHighGain * 0.5
            
            outputLeft[i] = outgoingLeft[i] * outgoingScale + incomingLeft[i] * incomingScale
            outputRight[i] = outgoingRight[i] * outgoingScale + incomingRight[i] * incomingScale
        }
    }
    
    /// Filter sweep transition
    private func processFilter(
        outgoingLeft: UnsafePointer<Float>,
        outgoingRight: UnsafePointer<Float>,
        incomingLeft: UnsafePointer<Float>,
        incomingRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        for i in 0..<frameCount {
            let sampleProgress = Float(currentSample + i) / Float(max(1, transitionSamples))
            let clampedProgress = min(1.0, max(0.0, sampleProgress))
            
            // Outgoing: low-pass sweep down
            // Incoming: high-pass sweep down (opening up)
            let outgoingGain = 1.0 - clampedProgress
            let incomingGain = clampedProgress
            
            // Simple crossfade with volume curves for filter effect
            // In production, we'd apply actual filter sweeps
            outputLeft[i] = outgoingLeft[i] * outgoingGain + incomingLeft[i] * incomingGain
            outputRight[i] = outgoingRight[i] * outgoingGain + incomingRight[i] * incomingGain
        }
    }
    
    /// Hard cut on beat
    private func processCut(
        outgoingLeft: UnsafePointer<Float>,
        outgoingRight: UnsafePointer<Float>,
        incomingLeft: UnsafePointer<Float>,
        incomingRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        // Instant cut at midpoint
        let midpoint = transitionSamples / 2
        
        for i in 0..<frameCount {
            if currentSample + i < midpoint {
                outputLeft[i] = outgoingLeft[i]
                outputRight[i] = outgoingRight[i]
            } else {
                outputLeft[i] = incomingLeft[i]
                outputRight[i] = incomingRight[i]
            }
        }
    }
    
    // MARK: - Filter Processing
    
    /// Apply biquad filter to a single sample
    private func applyBiquad(sample: Float, coeffs: [Float], state: inout [Float]) -> Float {
        guard coeffs.count >= 5 else { return sample }
        
        let b0 = coeffs[0]
        let b1 = coeffs[1]
        let b2 = coeffs[2]
        let a1 = coeffs[3]
        let a2 = coeffs[4]
        
        // Direct Form II Transposed
        let output = b0 * sample + state[0]
        state[0] = b1 * sample - a1 * output + state[1]
        state[1] = b2 * sample - a2 * output
        
        return output
    }
    
    // MARK: - Convenience
    
    /// Get samples until next downbeat for beat-aligned starts
    func samplesToNextDownbeat(currentPosition: Int, downbeats: [TimeInterval]) -> Int? {
        let currentTime = Double(currentPosition) / sampleRate
        
        // Find next downbeat
        for downbeat in downbeats {
            if downbeat > currentTime {
                let deltaTime = downbeat - currentTime
                return Int(deltaTime * sampleRate)
            }
        }
        
        return nil
    }
    
    /// Calculate transition duration in seconds
    func transitionDuration() -> TimeInterval {
        let beatsPerBar = 4.0
        let secondsPerBeat = 60.0 / config.tempo
        return Double(config.durationBars) * beatsPerBar * secondsPerBeat
    }
}

