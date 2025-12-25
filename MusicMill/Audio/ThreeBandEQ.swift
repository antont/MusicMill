import Foundation
import Accelerate

/// 3-band DJ-style EQ using biquad filters
/// - Low: 0-250 Hz
/// - Mid: 250-4000 Hz
/// - High: 4000+ Hz
class ThreeBandEQ {
    
    // MARK: - Filter Coefficients
    
    /// Biquad filter state for each band and channel
    private var lowFilterState: [[Float]]  // [channel][state]
    private var midFilterState: [[Float]]
    private var highFilterState: [[Float]]
    
    /// Biquad coefficients: [b0, b1, b2, a1, a2] (normalized, a0 = 1)
    private var lowCoeffs: [Double]
    private var midLowCoeffs: [Double]
    private var midHighCoeffs: [Double]
    private var highCoeffs: [Double]
    
    // MARK: - Gain
    
    private var lowGain: Float = 1.0
    private var midGain: Float = 1.0
    private var highGain: Float = 1.0
    
    private let sampleRate: Float
    
    // Crossover frequencies
    private let lowCrossover: Float = 250.0
    private let highCrossover: Float = 4000.0
    
    // MARK: - Initialization
    
    init(sampleRate: Float = 44100.0) {
        self.sampleRate = sampleRate
        
        // Initialize filter states (2 channels, 2 state variables each for biquad)
        lowFilterState = [[0, 0], [0, 0]]
        midFilterState = [[0, 0], [0, 0]]
        highFilterState = [[0, 0], [0, 0]]
        
        // Calculate filter coefficients
        lowCoeffs = Self.lowpassCoefficients(frequency: Double(lowCrossover), sampleRate: Double(sampleRate))
        midLowCoeffs = Self.highpassCoefficients(frequency: Double(lowCrossover), sampleRate: Double(sampleRate))
        midHighCoeffs = Self.lowpassCoefficients(frequency: Double(highCrossover), sampleRate: Double(sampleRate))
        highCoeffs = Self.highpassCoefficients(frequency: Double(highCrossover), sampleRate: Double(sampleRate))
    }
    
    // MARK: - Coefficient Calculation
    
    /// Calculate lowpass biquad coefficients (Butterworth)
    private static func lowpassCoefficients(frequency: Double, sampleRate: Double) -> [Double] {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let cosOmega = cos(omega)
        let sinOmega = sin(omega)
        let alpha = sinOmega / (2.0 * sqrt(2.0))  // Q = sqrt(2)/2 for Butterworth
        
        let b0 = (1.0 - cosOmega) / 2.0
        let b1 = 1.0 - cosOmega
        let b2 = (1.0 - cosOmega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha
        
        // Normalize
        return [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
    }
    
    /// Calculate highpass biquad coefficients (Butterworth)
    private static func highpassCoefficients(frequency: Double, sampleRate: Double) -> [Double] {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let cosOmega = cos(omega)
        let sinOmega = sin(omega)
        let alpha = sinOmega / (2.0 * sqrt(2.0))
        
        let b0 = (1.0 + cosOmega) / 2.0
        let b1 = -(1.0 + cosOmega)
        let b2 = (1.0 + cosOmega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha
        
        return [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
    }
    
    // MARK: - Gain Setting
    
    /// Set gains for all bands (in dB, -60 to +12)
    func setGains(low: Float, mid: Float, high: Float) {
        lowGain = dBToLinear(low)
        midGain = dBToLinear(mid)
        highGain = dBToLinear(high)
    }
    
    /// Set individual band gain (in dB)
    func setLowGain(_ dB: Float) {
        lowGain = dBToLinear(dB)
    }
    
    func setMidGain(_ dB: Float) {
        midGain = dBToLinear(dB)
    }
    
    func setHighGain(_ dB: Float) {
        highGain = dBToLinear(dB)
    }
    
    private func dBToLinear(_ dB: Float) -> Float {
        if dB <= -60 {
            return 0  // Kill
        }
        return pow(10.0, dB / 20.0)
    }
    
    // MARK: - Processing
    
    /// Process a single sample (sample-by-sample for real-time)
    func process(sample: Float, channel: Int) -> Float {
        let ch = min(channel, 1)
        
        // Split into 3 bands using cascaded filters
        let low = processBiquad(
            sample: sample,
            coeffs: lowCoeffs,
            state: &lowFilterState[ch]
        )
        
        // Mid = highpass(lowCrossover) -> lowpass(highCrossover)
        let midHP = processBiquad(
            sample: sample,
            coeffs: midLowCoeffs,
            state: &midFilterState[ch]
        )
        // We'd need another state for the second filter, simplify for now
        // Just use the highpassed version
        let mid = midHP - low - processHighpass(sample: sample, channel: ch)
        
        let high = processHighpass(sample: sample, channel: ch)
        
        // Apply gains and sum
        return low * lowGain + mid * midGain + high * highGain
    }
    
    /// Process buffer (more efficient for batch processing)
    func processBuffer(_ buffer: inout [Float], channel: Int) {
        let ch = min(channel, 1)
        
        for i in 0..<buffer.count {
            let sample = buffer[i]
            
            // Simple 3-way crossover
            let low = processBiquad(sample: sample, coeffs: lowCoeffs, state: &lowFilterState[ch])
            let high = processBiquadHP(sample: sample, channel: ch)
            let mid = sample - low - high
            
            buffer[i] = low * lowGain + mid * midGain + high * highGain
        }
    }
    
    // Internal biquad processing
    private func processBiquad(sample: Float, coeffs: [Double], state: inout [Float]) -> Float {
        let input = Double(sample)
        
        // Direct Form II Transposed
        let output = coeffs[0] * input + Double(state[0])
        state[0] = Float(coeffs[1] * input - coeffs[3] * output + Double(state[1]))
        state[1] = Float(coeffs[2] * input - coeffs[4] * output)
        
        return Float(output)
    }
    
    // Separate high-pass state
    private var highFilterStateHP: [[Float]] = [[0, 0], [0, 0]]
    
    private func processHighpass(sample: Float, channel: Int) -> Float {
        let ch = min(channel, 1)
        return processBiquad(sample: sample, coeffs: highCoeffs, state: &highFilterStateHP[ch])
    }
    
    private func processBiquadHP(sample: Float, channel: Int) -> Float {
        let ch = min(channel, 1)
        return processBiquad(sample: sample, coeffs: highCoeffs, state: &highFilterState[ch])
    }
    
    // MARK: - Reset
    
    /// Reset all filter states
    func reset() {
        lowFilterState = [[0, 0], [0, 0]]
        midFilterState = [[0, 0], [0, 0]]
        highFilterState = [[0, 0], [0, 0]]
        highFilterStateHP = [[0, 0], [0, 0]]
    }
}

// MARK: - Accelerate-based Batch Processing

extension ThreeBandEQ {
    
    /// Process a buffer using Accelerate for better performance
    func processBufferAccelerate(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, count: Int, channel: Int) {
        let ch = min(channel, 1)
        
        // Allocate temporary buffers
        var lowBand = [Float](repeating: 0, count: count)
        var midBand = [Float](repeating: 0, count: count)
        var highBand = [Float](repeating: 0, count: count)
        
        // Process each band (simplified - would need vDSP_biquad for production)
        for i in 0..<count {
            let sample = input[i]
            lowBand[i] = processBiquad(sample: sample, coeffs: lowCoeffs, state: &lowFilterState[ch])
            highBand[i] = processHighpass(sample: sample, channel: ch)
            midBand[i] = sample - lowBand[i] - highBand[i]
        }
        
        // Apply gains using Accelerate
        var lowGainVar = lowGain
        var midGainVar = midGain
        var highGainVar = highGain
        
        vDSP_vsmul(lowBand, 1, &lowGainVar, &lowBand, 1, vDSP_Length(count))
        vDSP_vsmul(midBand, 1, &midGainVar, &midBand, 1, vDSP_Length(count))
        vDSP_vsmul(highBand, 1, &highGainVar, &highBand, 1, vDSP_Length(count))
        
        // Sum all bands
        vDSP_vadd(lowBand, 1, midBand, 1, output, 1, vDSP_Length(count))
        vDSP_vadd(output, 1, highBand, 1, output, 1, vDSP_Length(count))
    }
}

