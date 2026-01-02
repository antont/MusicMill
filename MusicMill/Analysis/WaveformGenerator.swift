import Foundation
import AVFoundation
import Accelerate
import CoreMedia

/// Generates RGB waveform data from audio files
/// Runs asynchronously to avoid blocking UI or audio playback
class WaveformGenerator {
    
    static let shared = WaveformGenerator()
    
    // Cache for generated waveforms (by file path)
    private var waveformCache: [String: WaveformData] = [:]
    private let cacheQueue = DispatchQueue(label: "com.musicmill.waveform.cache", attributes: .concurrent)
    
    // Active generation tasks to avoid duplicate work
    private var activeTasks: Set<String> = []
    private let taskQueue = DispatchQueue(label: "com.musicmill.waveform.tasks")
    
    private init() {}
    
    /// Generate waveform from audio file asynchronously
    /// - Parameters:
    ///   - filePath: Path to audio file
    ///   - numPoints: Number of waveform points (default: 500)
    ///   - completion: Called with waveform data or nil on error
    func generateWaveform(
        from filePath: String,
        numPoints: Int = 500,
        completion: @escaping (WaveformData?) -> Void
    ) {
        // Check cache first
        cacheQueue.async { [weak self] in
            if let cached = self?.waveformCache[filePath] {
                DispatchQueue.main.async {
                    completion(cached)
                }
                return
            }
            
            // Check if task is already in progress
            self?.taskQueue.async {
                guard let self = self else { return }
                
                if self.activeTasks.contains(filePath) {
                    // Task already in progress, wait a bit and check cache again
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                        self.generateWaveform(from: filePath, numPoints: numPoints, completion: completion)
                    }
                    return
                }
                
                self.activeTasks.insert(filePath)
                
                // Generate on background queue with lower priority to not interfere with audio playback
                DispatchQueue.global(qos: .utility).async {
                    let waveform = self.generateWaveformSync(from: filePath, numPoints: numPoints)
                    
                    // Cache result
                    if let waveform = waveform {
                        self.cacheQueue.async(flags: .barrier) {
                            self.waveformCache[filePath] = waveform
                        }
                    }
                    
                    // Remove from active tasks
                    self.taskQueue.async {
                        self.activeTasks.remove(filePath)
                    }
                    
                    // Call completion on main queue
                    DispatchQueue.main.async {
                        completion(waveform)
                    }
                }
            }
        }
    }
    
    /// Synchronous waveform generation (runs on background queue)
    private func generateWaveformSync(from filePath: String, numPoints: Int) -> WaveformData? {
        let url = URL(fileURLWithPath: filePath)
        
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[WaveformGenerator] File not found: \(filePath)")
            return nil
        }
        
        do {
            // Try to load with AVAudioFile first (for PCM formats)
            let file = try AVAudioFile(forReading: url)
            let fileFormat = file.fileFormat
            let sampleRate = fileFormat.sampleRate
            let frameCount = AVAudioFrameCount(file.length)
            
            guard frameCount > 0 else {
                print("[WaveformGenerator] Empty file: \(filePath)")
                return nil
            }
            
            // Check if format is PCM-compatible
            // AVAudioFile can only read PCM formats, so if we got here, it should be PCM
            // But we need to ensure it's a standard format we can work with
            guard fileFormat.isStandard else {
                // Non-standard format - use AVAssetReader instead
                print("[WaveformGenerator] Non-standard format, using AVAssetReader")
                return generateWaveformFromAsset(url: url, numPoints: numPoints)
            }
            
            // Read in file's native format (should be PCM since AVAudioFile succeeded)
            guard let nativeBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
                print("[WaveformGenerator] Failed to create native buffer - format may not be PCM")
                // Fallback to AVAssetReader
                return generateWaveformFromAsset(url: url, numPoints: numPoints)
            }
            
            // Read audio data
            try file.read(into: nativeBuffer)
            
            // Convert to mono float format for analysis
            var audioData: [Float]
            let audioFrameCount = Int(nativeBuffer.frameLength)
            
            guard let channelData = nativeBuffer.floatChannelData else {
                return nil
            }
            
            if fileFormat.channelCount == 1 {
                // Already mono
                audioData = Array(UnsafeBufferPointer(start: channelData[0], count: audioFrameCount))
            } else {
                // Stereo or multi-channel - convert to mono by averaging
                audioData = [Float](repeating: 0, count: audioFrameCount)
                let numChannels = Int(fileFormat.channelCount)
                
                // Average all channels
                for channel in 0..<numChannels {
                    guard channel < numChannels else { break }
                    let channelPtr = channelData[channel]
                    for i in 0..<audioFrameCount {
                        audioData[i] += channelPtr[i]
                    }
                }
                
                // Divide by channel count to get average
                let channelCount = Float(numChannels)
                for i in 0..<audioFrameCount {
                    audioData[i] /= channelCount
                }
            }
            
            return processAudioData(audioData, sampleRate: sampleRate, numPoints: numPoints)
            
        } catch {
            print("[WaveformGenerator] Error loading file: \(error)")
            return nil
        }
    }
    
    /// Generate waveform using AVAssetReader (for non-PCM formats like MP3, AAC)
    /// Uses synchronous API to avoid blocking issues with async/await + semaphores
    private func generateWaveformFromAsset(url: URL, numPoints: Int) -> WaveformData? {
        let asset = AVURLAsset(url: url)
        
        // Use deprecated but synchronous API to avoid blocking issues
        // The async API with semaphores was causing 17fps frame drops
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            print("[WaveformGenerator] No audio track found")
            return nil
        }
        
        let sampleRate = 22050.0 // Lower sample rate for faster processing
        
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
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
            audioData.reserveCapacity(Int(sampleRate * 300)) // Pre-allocate for ~5 min track
            
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
            
            guard !audioData.isEmpty else {
                print("[WaveformGenerator] Empty audio data from asset reader")
                return nil
            }
            
            return processAudioData(audioData, sampleRate: sampleRate, numPoints: numPoints)
            
        } catch {
            print("[WaveformGenerator] Error reading asset: \(error)")
            return nil
        }
    }
    
    /// Process audio data to generate waveform
    private func processAudioData(_ audioData: [Float], sampleRate: Double, numPoints: Int) -> WaveformData {
        // Compute STFT
        let stft = computeSTFT(audioData: audioData, sampleRate: sampleRate)
        
        // Split into frequency bands
        let (low, mid, high) = splitFrequencyBands(stft: stft, sampleRate: sampleRate)
        
        // Resample to target number of points
        let lowResampled = resample(low, to: numPoints)
        let midResampled = resample(mid, to: numPoints)
        let highResampled = resample(high, to: numPoints)
        
        // Normalize each band independently (0-1)
        let lowNormalized = normalize(lowResampled)
        let midNormalized = normalize(midResampled)
        let highNormalized = normalize(highResampled)
        
        return WaveformData(
            low: lowNormalized,
            mid: midNormalized,
            high: highNormalized,
            points: numPoints
        )
    }
    
    /// Compute STFT (Short-Time Fourier Transform)
    private func computeSTFT(audioData: [Float], sampleRate: Double) -> [[Float]] {
        let nFFT = 2048
        let hopLength = 512
        
        var stft: [[Float]] = []
        let numFrames = (audioData.count - nFFT) / hopLength + 1
        
        for i in 0..<max(0, numFrames) {
            let startIdx = i * hopLength
            let endIdx = min(startIdx + nFFT, audioData.count)
            
            if endIdx - startIdx < nFFT {
                break
            }
            
            // Extract frame
            var frame = Array(audioData[startIdx..<endIdx])
            
            // Apply window (Hann window)
            applyHannWindow(&frame)
            
            // Compute FFT (returns magnitude spectrum)
            let magnitude = computeFFT(frame, nFFT: nFFT)
            stft.append(magnitude)
        }
        
        return stft
    }
    
    /// Apply Hann window to frame
    private func applyHannWindow(_ frame: inout [Float]) {
        let n = frame.count
        for i in 0..<n {
            let window = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(n - 1)))
            frame[i] *= Float(window)
        }
    }
    
    /// Compute FFT using Accelerate (returns magnitude spectrum)
    private func computeFFT(_ frame: [Float], nFFT: Int) -> [Float] {
        let log2n = vDSP_Length(log2(Double(nFFT)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        // Prepare input (zero-pad if needed)
        var input = frame
        if input.count < nFFT {
            input.append(contentsOf: Array(repeating: 0.0, count: nFFT - input.count))
        }
        
        // Convert to split complex format
        var realp = [Float](repeating: 0, count: nFFT / 2)
        var imagp = [Float](repeating: 0, count: nFFT / 2)
        
        input.withUnsafeMutableBufferPointer { inputPtr in
            realp.withUnsafeMutableBufferPointer { realpPtr in
                imagp.withUnsafeMutableBufferPointer { imagpPtr in
                    var splitComplex = DSPSplitComplex(realp: realpPtr.baseAddress!, imagp: imagpPtr.baseAddress!)
                    inputPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(nFFT / 2))
                    }
                    
                    // Perform FFT
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }
        
        // Compute magnitude spectrum
        var magnitudes = [Float](repeating: 0, count: nFFT / 2)
        realp.withUnsafeMutableBufferPointer { realpPtr in
            imagp.withUnsafeMutableBufferPointer { imagpPtr in
                var splitComplex = DSPSplitComplex(realp: realpPtr.baseAddress!, imagp: imagpPtr.baseAddress!)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(nFFT / 2))
            }
        }
        
        // Convert to linear scale (square root of squared magnitudes)
        var sqrtMagnitudes = magnitudes
        vvsqrtf(&sqrtMagnitudes, &magnitudes, [Int32(nFFT / 2)])
        
        return sqrtMagnitudes
    }
    
    /// Split STFT into frequency bands
    private func splitFrequencyBands(stft: [[Float]], sampleRate: Double) -> (low: [Float], mid: [Float], high: [Float]) {
        guard !stft.isEmpty else { return ([], [], []) }
        
        let nFFT = 2048
        let freqResolution = sampleRate / Double(nFFT)
        
        // Frequency band boundaries
        let lowFreq = 250.0
        let midFreq = 4000.0
        
        let lowEnd = Int(lowFreq / freqResolution)
        let midEnd = Int(midFreq / freqResolution)
        let numBins = stft[0].count
        
        var low: [Float] = []
        var mid: [Float] = []
        var high: [Float] = []
        
        for frame in stft {
            // Sum energy in each band
            var lowEnergy: Float = 0
            var midEnergy: Float = 0
            var highEnergy: Float = 0
            
            for i in 0..<min(lowEnd, numBins) {
                lowEnergy += frame[i]
            }
            
            for i in lowEnd..<min(midEnd, numBins) {
                midEnergy += frame[i]
            }
            
            for i in midEnd..<numBins {
                highEnergy += frame[i]
            }
            
            low.append(lowEnergy / Float(lowEnd))
            mid.append(midEnergy / Float(max(1, midEnd - lowEnd)))
            high.append(highEnergy / Float(max(1, numBins - midEnd)))
        }
        
        return (low, mid, high)
    }
    
    /// Resample array to target length
    private func resample(_ array: [Float], to targetLength: Int) -> [Float] {
        guard !array.isEmpty else { return Array(repeating: 0, count: targetLength) }
        
        if array.count == targetLength {
            return array
        }
        
        if array.count < targetLength {
            // Upsample: linear interpolation
            var result: [Float] = []
            for i in 0..<targetLength {
                let pos = Double(i) * Double(array.count - 1) / Double(targetLength - 1)
                let idx = Int(pos)
                let frac = pos - Double(idx)
                
                if idx < array.count - 1 {
                    let val = array[idx] * Float(1.0 - frac) + array[idx + 1] * Float(frac)
                    result.append(val)
                } else {
                    result.append(array[array.count - 1])
                }
            }
            return result
        } else {
            // Downsample: linear indexing
            var result: [Float] = []
            for i in 0..<targetLength {
                let idx = Int(Double(i) * Double(array.count - 1) / Double(targetLength - 1))
                result.append(array[min(idx, array.count - 1)])
            }
            return result
        }
    }
    
    /// Normalize array to 0-1 range
    private func normalize(_ array: [Float]) -> [Float] {
        guard !array.isEmpty else { return array }
        
        let maxVal = array.max() ?? 1.0
        guard maxVal > 0 else { return Array(repeating: 0, count: array.count) }
        
        return array.map { $0 / maxVal }
    }
    
    /// Clear cache (useful for memory management)
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.waveformCache.removeAll()
        }
    }
    
    /// Remove specific waveform from cache
    func removeFromCache(filePath: String) {
        cacheQueue.async(flags: .barrier) {
            self.waveformCache.removeValue(forKey: filePath)
        }
    }
}

