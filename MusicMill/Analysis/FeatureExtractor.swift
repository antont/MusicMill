import Foundation
import AVFoundation
import Accelerate

/// Extracts audio features like tempo, key, energy, and spectral characteristics
class FeatureExtractor {
    
    struct AudioFeatures {
        let tempo: Double? // BPM
        let key: String? // Musical key (e.g., "C", "Am", "D#m")
        let energy: Double // 0.0 to 1.0
        let spectralCentroid: Double // Brightness
        let zeroCrossingRate: Double // Roughness
        let rmsEnergy: Double // Overall loudness
        let duration: TimeInterval
    }
    
    /// Extracts features from an audio file
    func extractFeatures(from url: URL) async throws -> AudioFeatures {
        let asset = AVAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw FeatureExtractorError.noAudioTrack
        }
        
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        // Load audio data
        let audioData = try await loadAudioData(from: audioTrack, asset: asset)
        
        // Extract features
        let energy = calculateEnergy(audioData: audioData)
        let spectralCentroid = calculateSpectralCentroid(audioData: audioData)
        let zeroCrossingRate = calculateZeroCrossingRate(audioData: audioData)
        let rmsEnergy = calculateRMSEnergy(audioData: audioData)
        let tempo = estimateTempo(audioData: audioData, sampleRate: 44100)
        let key = estimateKey(audioData: audioData)
        
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
    
    /// Calculates spectral centroid (brightness)
    private func calculateSpectralCentroid(audioData: [Float]) -> Double {
        guard !audioData.isEmpty else { return 0.0 }
        
        // Simple approximation using FFT would be better, but this is a simplified version
        let windowSize = 1024
        var centroidSum: Double = 0.0
        var magnitudeSum: Double = 0.0
        
        for i in stride(from: 0, to: audioData.count - windowSize, by: windowSize) {
            let window = Array(audioData[i..<min(i + windowSize, audioData.count)])
            let magnitude = window.map { abs(Double($0)) }
            
            for (index, mag) in magnitude.enumerated() {
                centroidSum += Double(index) * mag
                magnitudeSum += mag
            }
        }
        
        return magnitudeSum > 0 ? centroidSum / magnitudeSum : 0.0
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
    
    /// Estimates tempo using autocorrelation (simplified)
    private func estimateTempo(audioData: [Float], sampleRate: Double) -> Double? {
        // Simplified tempo estimation - in production, use more sophisticated methods
        // This is a placeholder that would need proper autocorrelation implementation
        guard audioData.count > Int(sampleRate) else { return nil }
        
        // For now, return nil - proper tempo detection requires more complex algorithms
        // This would typically use autocorrelation or onset detection
        return nil
    }
    
    /// Estimates musical key (simplified)
    private func estimateKey(audioData: [Float]) -> String? {
        // Simplified key detection - in production, use chromagram analysis
        // This is a placeholder
        return nil
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

