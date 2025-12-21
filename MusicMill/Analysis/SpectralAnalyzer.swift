import Foundation
import AVFoundation
import Accelerate

/// Analyzes spectral representations (STFT, mel-spectrograms, chromagrams) for neural generation approaches
class SpectralAnalyzer {
    
    struct SpectralFeatures {
        let melSpectrogram: [[Float]] // Mel-spectrogram frames
        let chromagram: [[Float]] // Chromagram (12 pitch classes)
        let stft: [[Float]] // Short-Time Fourier Transform magnitude
        let harmonicComponent: [[Float]] // Harmonic component
        let percussiveComponent: [[Float]] // Percussive component
        let sampleRate: Double
        let hopLength: Int
        let nFFT: Int
    }
    
    /// Analyzes spectral features from an audio file
    func analyzeSpectralFeatures(from url: URL, nFFT: Int = 2048, hopLength: Int = 512, nMelBands: Int = 128) async throws -> SpectralFeatures {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SpectralAnalyzerError.noAudioTrack
        }
        
        let sampleRate = 44100.0
        let audioData = try await loadAudioData(from: audioTrack, asset: asset, sampleRate: sampleRate)
        
        // Compute STFT
        let stft = computeSTFT(audioData: audioData, nFFT: nFFT, hopLength: hopLength, sampleRate: sampleRate)
        
        // Compute mel-spectrogram
        let melSpectrogram = computeMelSpectrogram(stft: stft, sampleRate: sampleRate, nMelBands: nMelBands, nFFT: nFFT)
        
        // Compute chromagram
        let chromagram = computeChromagram(stft: stft, sampleRate: sampleRate, nFFT: nFFT)
        
        // Separate harmonic and percussive components
        let (harmonic, percussive) = separateHarmonicPercussive(stft: stft)
        
        return SpectralFeatures(
            melSpectrogram: melSpectrogram,
            chromagram: chromagram,
            stft: stft,
            harmonicComponent: harmonic,
            percussiveComponent: percussive,
            sampleRate: sampleRate,
            hopLength: hopLength,
            nFFT: nFFT
        )
    }
    
    /// Computes Short-Time Fourier Transform
    private func computeSTFT(audioData: [Float], nFFT: Int, hopLength: Int, sampleRate: Double) -> [[Float]] {
        var stftFrames: [[Float]] = []
        
        let windowSize = nFFT
        let window = createHannWindow(size: windowSize)
        
        for i in stride(from: 0, to: audioData.count - windowSize, by: hopLength) {
            let frame = Array(audioData[i..<min(i + windowSize, audioData.count)])
            
            // Apply window
            var windowedFrame = frame
            vDSP_vmul(frame, 1, window, 1, &windowedFrame, 1, vDSP_Length(windowSize))
            
            // Zero-pad if necessary
            var paddedFrame = windowedFrame
            if paddedFrame.count < nFFT {
                paddedFrame.append(contentsOf: Array(repeating: 0.0, count: nFFT - paddedFrame.count))
            }
            
            // Compute FFT
            let fft = computeFFT(samples: paddedFrame, nFFT: nFFT)
            stftFrames.append(fft)
        }
        
        return stftFrames
    }
    
    /// Computes FFT using Accelerate framework
    private func computeFFT(samples: [Float], nFFT: Int) -> [Float] {
        let log2n = vDSP_Length(log2(Double(nFFT)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        
        defer {
            vDSP_destroy_fftsetup(fftSetup)
        }
        
        var realp = [Float](repeating: 0, count: nFFT / 2)
        var imagp = [Float](repeating: 0, count: nFFT / 2)
        
        var input = samples
        input.withUnsafeMutableBufferPointer { inputPtr in
            var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
            
            inputPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { complexInput in
                vDSP_ctoz(complexInput, 2, &splitComplex, 1, vDSP_Length(nFFT / 2))
            }
            
            vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
        }
        
        // Compute magnitude spectrum
        var magnitudes = [Float](repeating: 0, count: nFFT / 2)
        var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(nFFT / 2))
        
        // Convert to linear scale and take square root
        var sqrtMagnitudes = magnitudes
        vvsqrtf(&sqrtMagnitudes, &magnitudes, [Int32(nFFT / 2)])
        
        return sqrtMagnitudes
    }
    
    /// Computes mel-spectrogram
    private func computeMelSpectrogram(stft: [[Float]], sampleRate: Double, nMelBands: Int, nFFT: Int) -> [[Float]] {
        // Create mel filter bank
        let melFilters = createMelFilterBank(sampleRate: sampleRate, nFFT: nFFT, nMelBands: nMelBands)
        
        var melSpectrogram: [[Float]] = []
        
        for frame in stft {
            var melFrame = [Float](repeating: 0, count: nMelBands)
            
            for (melBand, filter) in melFilters.enumerated() {
                var sum: Float = 0.0
                for (freqBin, weight) in filter.enumerated() {
                    if freqBin < frame.count {
                        sum += frame[freqBin] * weight
                    }
                }
                melFrame[melBand] = sum
            }
            
            melSpectrogram.append(melFrame)
        }
        
        return melSpectrogram
    }
    
    /// Creates mel filter bank
    private func createMelFilterBank(sampleRate: Double, nFFT: Int, nMelBands: Int) -> [[Float]] {
        let nyquist = sampleRate / 2.0
        let melMax = hzToMel(nyquist)
        let melMin = 0.0
        
        var filters: [[Float]] = []
        
        for i in 0..<nMelBands {
            let melCenter = melMin + (melMax - melMin) * Double(i + 1) / Double(nMelBands + 1)
            let hzCenter = melToHz(melCenter)
            
            var filter = [Float](repeating: 0, count: nFFT / 2)
            
            for j in 0..<nFFT / 2 {
                let freq = Double(j) * sampleRate / Double(nFFT)
                let melFreq = hzToMel(freq)
                
                // Triangular filter
                let distance = abs(melFreq - melCenter)
                let bandwidth = (melMax - melMin) / Double(nMelBands + 1)
                
                if distance < bandwidth {
                    filter[j] = Float(1.0 - distance / bandwidth)
                }
            }
            
            filters.append(filter)
        }
        
        return filters
    }
    
    /// Converts Hz to mel scale
    private func hzToMel(_ hz: Double) -> Double {
        return 2595.0 * log10(1.0 + hz / 700.0)
    }
    
    /// Converts mel to Hz scale
    private func melToHz(_ mel: Double) -> Double {
        return 700.0 * (pow(10, mel / 2595.0) - 1.0)
    }
    
    /// Computes chromagram (12 pitch classes)
    private func computeChromagram(stft: [[Float]], sampleRate: Double, nFFT: Int) -> [[Float]] {
        let nChroma = 12
        var chromagram: [[Float]] = []
        
        // Create chroma filter bank
        let chromaFilters = createChromaFilterBank(sampleRate: sampleRate, nFFT: nFFT, nChroma: nChroma)
        
        for frame in stft {
            var chromaFrame = [Float](repeating: 0, count: nChroma)
            
            for (chromaBin, filter) in chromaFilters.enumerated() {
                var sum: Float = 0.0
                for (freqBin, weight) in filter.enumerated() {
                    if freqBin < frame.count {
                        sum += frame[freqBin] * weight
                    }
                }
                chromaFrame[chromaBin] = sum
            }
            
            chromagram.append(chromaFrame)
        }
        
        return chromagram
    }
    
    /// Creates chroma filter bank
    private func createChromaFilterBank(sampleRate: Double, nFFT: Int, nChroma: Int) -> [[Float]] {
        var filters: [[Float]] = []
        
        // A4 = 440 Hz
        let a4Freq = 440.0
        let a4Bin = Int(a4Freq * Double(nFFT) / sampleRate)
        
        for chroma in 0..<nChroma {
            var filter = [Float](repeating: 0, count: nFFT / 2)
            
            // Each chroma corresponds to a pitch class (C, C#, D, D#, E, F, F#, G, G#, A, A#, B)
            // Map to frequency bins
            for octave in 1..<8 {
                let semitoneOffset = Double(chroma)
                let freq = a4Freq * pow(2.0, (semitoneOffset - 9.0 + Double(octave - 4) * 12.0) / 12.0)
                let bin = Int(freq * Double(nFFT) / sampleRate)
                
                if bin < nFFT / 2 {
                    filter[bin] = 1.0
                }
            }
            
            filters.append(filter)
        }
        
        return filters
    }
    
    /// Separates harmonic and percussive components
    private func separateHarmonicPercussive(stft: [[Float]]) -> (harmonic: [[Float]], percussive: [[Float]]) {
        // Simplified harmonic/percussive separation
        // Production would use more sophisticated methods like median filtering
        
        var harmonic: [[Float]] = []
        var percussive: [[Float]] = []
        
        for frame in stft {
            // Harmonic: smooth across frequency (vertical)
            var harmonicFrame = frame
            // Simple smoothing - production would use median filter
            for i in 1..<frame.count - 1 {
                harmonicFrame[i] = (frame[i-1] + frame[i] + frame[i+1]) / 3.0
            }
            
            // Percussive: smooth across time (horizontal)
            // For now, use original frame as percussive
            let percussiveFrame = frame
            
            harmonic.append(harmonicFrame)
            percussive.append(percussiveFrame)
        }
        
        return (harmonic, percussive)
    }
    
    /// Creates Hann window
    private func createHannWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        for i in 0..<size {
            window[i] = Float(0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(size - 1))))
        }
        return window
    }
    
    /// Loads audio data from a track
    private func loadAudioData(from track: AVAssetTrack, asset: AVAsset, sampleRate: Double) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1 // Mono for analysis
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
    
    enum SpectralAnalyzerError: LocalizedError {
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

