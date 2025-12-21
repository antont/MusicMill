import Foundation
import AVFoundation
import Accelerate

/// Extracts audio features like tempo, key, energy, and spectral characteristics
class FeatureExtractor {
    
    private let sampleRate: Double = 44100.0
    private let fftSize: Int = 2048
    private let hopSize: Int = 512
    
    // Musical note names for key detection
    private let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    
    struct AudioFeatures {
        let tempo: Double? // BPM
        let key: String? // Musical key (e.g., "C", "Am", "D#m")
        let energy: Double // 0.0 to 1.0
        let spectralCentroid: Double // Brightness in Hz
        let zeroCrossingRate: Double // Roughness
        let rmsEnergy: Double // Overall loudness
        let duration: TimeInterval
    }
    
    /// Extracts features from an audio file
    func extractFeatures(from url: URL) async throws -> AudioFeatures {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw FeatureExtractorError.noAudioTrack
        }
        
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        // Load audio data (mono, for analysis)
        let audioData = try await loadAudioData(from: audioTrack, asset: asset)
        
        // Convert stereo to mono if needed
        let monoData = convertToMono(audioData)
        
        // Extract features
        let energy = calculateEnergy(audioData: monoData)
        let spectralCentroid = calculateSpectralCentroidFFT(audioData: monoData)
        let zeroCrossingRate = calculateZeroCrossingRate(audioData: monoData)
        let rmsEnergy = calculateRMSEnergy(audioData: monoData)
        let tempo = estimateTempoAutocorrelation(audioData: monoData)
        let key = estimateKeyChromagram(audioData: monoData)
        
        return AudioFeatures(
            tempo: tempo,
            key: key,
            energy: energy,
            spectralCentroid: spectralCentroid,
            zeroCrossingRate: zeroCrossingRate,
            rmsEnergy: rmsEnergy,
            duration: durationSeconds
        )
    }
    
    /// Extracts features from an in-memory audio buffer
    func extractFeatures(from buffer: AVAudioPCMBuffer) -> AudioFeatures {
        // Get audio data from buffer
        guard let channelData = buffer.floatChannelData else {
            return AudioFeatures(
                tempo: nil,
                key: nil,
                energy: 0,
                spectralCentroid: 0,
                zeroCrossingRate: 0,
                rmsEnergy: 0,
                duration: 0
            )
        }
        
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let bufferSampleRate = buffer.format.sampleRate
        let durationSeconds = Double(frameLength) / bufferSampleRate
        
        // Convert to mono
        var monoData = [Float](repeating: 0, count: frameLength)
        if channelCount >= 2 {
            // Average stereo channels
            let left = channelData[0]
            let right = channelData[1]
            for i in 0..<frameLength {
                monoData[i] = (left[i] + right[i]) / 2.0
            }
        } else {
            // Copy mono channel
            let mono = channelData[0]
            for i in 0..<frameLength {
                monoData[i] = mono[i]
            }
        }
        
        // Resample if needed (our analysis expects 44100 Hz)
        var analysisData = monoData
        if bufferSampleRate != sampleRate {
            analysisData = resample(monoData, from: bufferSampleRate, to: sampleRate)
        }
        
        // Extract features
        let energy = calculateEnergy(audioData: analysisData)
        let spectralCentroid = calculateSpectralCentroidFFT(audioData: analysisData)
        let zeroCrossingRate = calculateZeroCrossingRate(audioData: analysisData)
        let rmsEnergy = calculateRMSEnergy(audioData: analysisData)
        let tempo = estimateTempoAutocorrelation(audioData: analysisData)
        let key = estimateKeyChromagram(audioData: analysisData)
        
        return AudioFeatures(
            tempo: tempo,
            key: key,
            energy: energy,
            spectralCentroid: spectralCentroid,
            zeroCrossingRate: zeroCrossingRate,
            rmsEnergy: rmsEnergy,
            duration: durationSeconds
        )
    }
    
    /// Simple linear resampling for different sample rates
    private func resample(_ data: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        let ratio = targetSampleRate / sourceSampleRate
        let newLength = Int(Double(data.count) * ratio)
        var resampled = [Float](repeating: 0, count: newLength)
        
        for i in 0..<newLength {
            let sourceIndex = Double(i) / ratio
            let lowerIndex = Int(sourceIndex)
            let upperIndex = min(lowerIndex + 1, data.count - 1)
            let fraction = Float(sourceIndex - Double(lowerIndex))
            
            resampled[i] = data[lowerIndex] * (1 - fraction) + data[upperIndex] * fraction
        }
        
        return resampled
    }
    
    /// Converts stereo audio to mono by averaging channels
    private func convertToMono(_ audioData: [Float]) -> [Float] {
        // Assume interleaved stereo: L R L R L R...
        let frameCount = audioData.count / 2
        if frameCount < 1 { return audioData }
        
        var mono = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            mono[i] = (audioData[i * 2] + audioData[i * 2 + 1]) / 2.0
        }
        return mono
    }
    
    /// Loads audio data from a track
    private func loadAudioData(from track: AVAssetTrack, asset: AVAsset) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2
        ])
        
        reader.add(output)
        reader.startReading()
        
        var audioData: [Float] = []
        
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                
                let status = CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &dataPointer
                )
                
                guard status == noErr, let pointer = dataPointer else {
                    continue
                }
                
                let floatPointer = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)
                let floatCount = length / MemoryLayout<Float>.size
                audioData.append(contentsOf: Array(UnsafeBufferPointer(start: floatPointer, count: floatCount)))
            }
        }
        
        return audioData
    }
    
    /// Calculates energy (amplitude-based)
    private func calculateEnergy(audioData: [Float]) -> Double {
        guard !audioData.isEmpty else { return 0.0 }
        
        var sum: Float = 0.0
        vDSP_svesq(audioData, 1, &sum, vDSP_Length(audioData.count))
        let meanSquare = Double(sum) / Double(audioData.count)
        return sqrt(meanSquare)
    }
    
    /// Calculates spectral centroid using FFT (brightness in Hz)
    private func calculateSpectralCentroidFFT(audioData: [Float]) -> Double {
        guard audioData.count >= fftSize else { return 0.0 }
        
        // Take a representative segment from the middle
        let startIdx = max(0, audioData.count / 2 - fftSize / 2)
        let segment = Array(audioData[startIdx..<min(startIdx + fftSize, audioData.count)])
        
        // Apply Hann window
        var windowed = [Float](repeating: 0, count: fftSize)
        for i in 0..<min(segment.count, fftSize) {
            let window = Float(0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(fftSize - 1))))
            windowed[i] = segment[i] * window
        }
        
        // Perform FFT
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return 0.0
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        
        // Pack data for FFT
        windowed.withUnsafeBufferPointer { windowedPtr in
            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }
        
        // Calculate magnitude spectrum
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeBufferPointer { realPtr in
            imag.withUnsafeBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: realPtr.baseAddress!),
                                                   imagp: UnsafeMutablePointer(mutating: imagPtr.baseAddress!))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        
        // Calculate spectral centroid
        var weightedSum: Float = 0.0
        var magnitudeSum: Float = 0.0
        let binFrequency = Float(sampleRate) / Float(fftSize)
        
        for i in 0..<(fftSize / 2) {
            let frequency = Float(i) * binFrequency
            let mag = sqrt(magnitudes[i])
            weightedSum += frequency * mag
            magnitudeSum += mag
        }
        
        return magnitudeSum > 0 ? Double(weightedSum / magnitudeSum) : 0.0
    }
    
    /// Calculates zero crossing rate (roughness/noisiness)
    private func calculateZeroCrossingRate(audioData: [Float]) -> Double {
        guard audioData.count > 1 else { return 0.0 }
        
        var crossings = 0
        for i in 1..<audioData.count {
            if (audioData[i-1] >= 0 && audioData[i] < 0) || (audioData[i-1] < 0 && audioData[i] >= 0) {
                crossings += 1
            }
        }
        
        return Double(crossings) / Double(audioData.count)
    }
    
    /// Calculates RMS energy
    private func calculateRMSEnergy(audioData: [Float]) -> Double {
        guard !audioData.isEmpty else { return 0.0 }
        
        var sum: Float = 0.0
        vDSP_svesq(audioData, 1, &sum, vDSP_Length(audioData.count))
        return sqrt(Double(sum) / Double(audioData.count))
    }
    
    /// Estimates tempo using onset detection and autocorrelation
    private func estimateTempoAutocorrelation(audioData: [Float]) -> Double? {
        guard audioData.count > Int(sampleRate * 2) else { return nil } // Need at least 2 seconds
        
        // 1. Calculate onset strength envelope
        let onsetEnvelope = calculateOnsetStrength(audioData: audioData)
        guard onsetEnvelope.count > 100 else { return nil }
        
        // 2. Autocorrelation to find periodicity
        // Look for periods corresponding to 60-200 BPM
        let minLag = Int(60.0 / 200.0 * sampleRate / Double(hopSize)) // 200 BPM
        let maxLag = Int(60.0 / 60.0 * sampleRate / Double(hopSize))  // 60 BPM
        
        guard maxLag < onsetEnvelope.count && minLag > 0 else { return nil }
        
        var bestLag = minLag
        var bestCorrelation: Float = 0.0
        
        for lag in minLag..<min(maxLag, onsetEnvelope.count / 2) {
            var correlation: Float = 0.0
            var count = 0
            
            for i in 0..<(onsetEnvelope.count - lag) {
                correlation += onsetEnvelope[i] * onsetEnvelope[i + lag]
                count += 1
            }
            
            if count > 0 {
                correlation /= Float(count)
            }
            
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }
        
        // Convert lag to BPM
        let lagInSeconds = Double(bestLag) * Double(hopSize) / sampleRate
        let bpm = 60.0 / lagInSeconds
        
        // Sanity check: BPM should be reasonable
        guard bpm >= 60.0 && bpm <= 200.0 else { return nil }
        
        // Round to nearest integer and check for octave errors
        // (e.g., if we detect 60 BPM but it's actually 120)
        var adjustedBPM = bpm
        if adjustedBPM < 90 && bestCorrelation > 0 {
            // Check if double tempo has higher correlation
            let doubleLag = bestLag / 2
            if doubleLag >= minLag {
                var doubleCorrelation: Float = 0.0
                var count = 0
                for i in 0..<(onsetEnvelope.count - doubleLag) {
                    doubleCorrelation += onsetEnvelope[i] * onsetEnvelope[i + doubleLag]
                    count += 1
                }
                if count > 0 { doubleCorrelation /= Float(count) }
                if doubleCorrelation > bestCorrelation * 0.9 {
                    adjustedBPM = bpm * 2
                }
            }
        }
        
        return round(adjustedBPM)
    }
    
    /// Calculates onset strength envelope for tempo detection
    private func calculateOnsetStrength(audioData: [Float]) -> [Float] {
        let frameCount = (audioData.count - fftSize) / hopSize
        guard frameCount > 0 else { return [] }
        
        var onsetStrength = [Float](repeating: 0, count: frameCount)
        var previousSpectrum = [Float](repeating: 0, count: fftSize / 2)
        
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        for frame in 0..<frameCount {
            let startIdx = frame * hopSize
            guard startIdx + fftSize <= audioData.count else { break }
            
            // Extract and window frame
            var windowed = [Float](repeating: 0, count: fftSize)
            for i in 0..<fftSize {
                let window = Float(0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(fftSize - 1))))
                windowed[i] = audioData[startIdx + i] * window
            }
            
            // FFT
            var real = [Float](repeating: 0, count: fftSize / 2)
            var imag = [Float](repeating: 0, count: fftSize / 2)
            
            windowed.withUnsafeBufferPointer { windowedPtr in
                real.withUnsafeMutableBufferPointer { realPtr in
                    imag.withUnsafeMutableBufferPointer { imagPtr in
                        var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                        windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                        }
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }
            
            // Calculate magnitude
            var magnitudes = [Float](repeating: 0, count: fftSize / 2)
            real.withUnsafeBufferPointer { realPtr in
                imag.withUnsafeBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: realPtr.baseAddress!),
                                                       imagp: UnsafeMutablePointer(mutating: imagPtr.baseAddress!))
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                }
            }
            
            // Convert to amplitude
            for i in 0..<magnitudes.count {
                magnitudes[i] = sqrt(magnitudes[i])
            }
            
            // Onset strength = sum of positive spectral flux (half-wave rectified difference)
            var onset: Float = 0.0
            for i in 0..<magnitudes.count {
                let diff = magnitudes[i] - previousSpectrum[i]
                if diff > 0 {
                    onset += diff
                }
            }
            
            onsetStrength[frame] = onset
            previousSpectrum = magnitudes
        }
        
        return onsetStrength
    }
    
    /// Estimates musical key using chromagram analysis
    private func estimateKeyChromagram(audioData: [Float]) -> String? {
        guard audioData.count > fftSize else { return nil }
        
        // Calculate chromagram (pitch class distribution)
        let chroma = calculateChromagram(audioData: audioData)
        guard chroma.count == 12 else { return nil }
        
        // Key profiles (Krumhansl-Schmuckler)
        // Major key profile
        let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        // Minor key profile  
        let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        
        var bestKey = 0
        var bestMode = "major"
        var bestCorrelation: Float = -Float.infinity
        
        // Try all 12 keys for both major and minor
        for key in 0..<12 {
            // Rotate chroma to match key
            var rotatedChroma = [Float](repeating: 0, count: 12)
            for i in 0..<12 {
                rotatedChroma[i] = chroma[(i + key) % 12]
            }
            
            // Correlate with major profile
            let majorCorr = correlate(rotatedChroma, majorProfile)
            if majorCorr > bestCorrelation {
                bestCorrelation = majorCorr
                bestKey = key
                bestMode = "major"
            }
            
            // Correlate with minor profile
            let minorCorr = correlate(rotatedChroma, minorProfile)
            if minorCorr > bestCorrelation {
                bestCorrelation = minorCorr
                bestKey = key
                bestMode = "minor"
            }
        }
        
        // Format key name
        let keyName = noteNames[bestKey]
        if bestMode == "minor" {
            return "\(keyName)m"
        } else {
            return keyName
        }
    }
    
    /// Calculates chromagram (12-bin pitch class distribution)
    private func calculateChromagram(audioData: [Float]) -> [Float] {
        var chroma = [Float](repeating: 0, count: 12)
        let frameCount = (audioData.count - fftSize) / hopSize
        guard frameCount > 0 else { return chroma }
        
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return chroma
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        // Process frames
        for frame in stride(from: 0, to: frameCount, by: 4) { // Sample every 4th frame for speed
            let startIdx = frame * hopSize
            guard startIdx + fftSize <= audioData.count else { break }
            
            // Extract and window frame
            var windowed = [Float](repeating: 0, count: fftSize)
            for i in 0..<fftSize {
                let window = Float(0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(fftSize - 1))))
                windowed[i] = audioData[startIdx + i] * window
            }
            
            // FFT
            var real = [Float](repeating: 0, count: fftSize / 2)
            var imag = [Float](repeating: 0, count: fftSize / 2)
            
            windowed.withUnsafeBufferPointer { windowedPtr in
                real.withUnsafeMutableBufferPointer { realPtr in
                    imag.withUnsafeMutableBufferPointer { imagPtr in
                        var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                        windowedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                        }
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }
            
            // Calculate magnitude
            var magnitudes = [Float](repeating: 0, count: fftSize / 2)
            real.withUnsafeBufferPointer { realPtr in
                imag.withUnsafeBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: realPtr.baseAddress!),
                                                       imagp: UnsafeMutablePointer(mutating: imagPtr.baseAddress!))
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                }
            }
            
            // Map FFT bins to chroma
            let binFrequency = Float(sampleRate) / Float(fftSize)
            for bin in 1..<(fftSize / 2) {
                let frequency = Float(bin) * binFrequency
                
                // Only consider frequencies in musical range (50 Hz - 5000 Hz)
                guard frequency >= 50 && frequency <= 5000 else { continue }
                
                // Convert frequency to pitch class (0-11)
                // A4 = 440 Hz, A = pitch class 9
                let midiNote = 12 * log2(frequency / 440.0) + 69
                let pitchClass = Int(round(midiNote)) % 12
                let validPitchClass = pitchClass < 0 ? pitchClass + 12 : pitchClass
                
                chroma[validPitchClass] += sqrt(magnitudes[bin])
            }
        }
        
        // Normalize
        var maxChroma: Float = 0.0
        vDSP_maxv(chroma, 1, &maxChroma, vDSP_Length(12))
        if maxChroma > 0 {
            var scale = 1.0 / maxChroma
            vDSP_vsmul(chroma, 1, &scale, &chroma, 1, vDSP_Length(12))
        }
        
        return chroma
    }
    
    /// Pearson correlation between two vectors
    private func correlate(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count && a.count > 0 else { return 0 }
        
        let n = Float(a.count)
        var sumA: Float = 0, sumB: Float = 0
        var sumAB: Float = 0, sumA2: Float = 0, sumB2: Float = 0
        
        for i in 0..<a.count {
            sumA += a[i]
            sumB += b[i]
            sumAB += a[i] * b[i]
            sumA2 += a[i] * a[i]
            sumB2 += b[i] * b[i]
        }
        
        let numerator = n * sumAB - sumA * sumB
        let denominator = sqrt((n * sumA2 - sumA * sumA) * (n * sumB2 - sumB * sumB))
        
        return denominator > 0 ? numerator / denominator : 0
    }
    
    enum FeatureExtractorError: LocalizedError {
        case noAudioTrack
        case audioLoadFailed
        
        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "No audio track found in file"
            case .audioLoadFailed:
                return "Failed to load audio data"
            }
        }
    }
}

