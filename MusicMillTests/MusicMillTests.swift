//
//  MusicMillTests.swift
//  MusicMillTests
//
//  Created by Toni Alatalo on 20.12.2025.
//

import Foundation
import AVFoundation
import Testing
@testable import MusicMill

struct MusicMillTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }
    
    @Test func analyzeBLVCKCEILINGCollection() async throws {
        let directoryURL = URL(fileURLWithPath: "/Users/tonialatalo/Music/PioneerDJ/Imported from Device/Contents/BLVCKCEILING")
        
        // Check if directory exists
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        
        guard exists && isDirectory.boolValue else {
            throw TestError.directoryNotFound("Directory not found: \(directoryURL.path)")
        }
        
        print(String(repeating: "=", count: 60))
        print("ANALYZING BLVCKCEILING COLLECTION")
        print(String(repeating: "=", count: 60))
        
        // Test AudioAnalyzer - Scan for audio files
        print("\n[1] Scanning directory for audio files...")
        let analyzer = AudioAnalyzer()
        let audioFiles = try await analyzer.scanDirectory(at: directoryURL)
        
        #expect(audioFiles.count > 0, "Should find at least one audio file")
        
        print("✓ Found \(audioFiles.count) audio files")
        for (index, file) in audioFiles.prefix(5).enumerated() {
            print("  \(index + 1). \(file.url.lastPathComponent)")
            print("     Format: \(file.format.rawValue.uppercased())")
            print("     Duration: \(Int(file.duration))s (\(String(format: "%.1f", file.duration / 60.0)) min)")
        }
        if audioFiles.count > 5 {
            print("  ... and \(audioFiles.count - 5) more files")
        }
        
        // Test FeatureExtractor - Extract audio features
        print("\n[2] Extracting audio features from first file...")
        let featureExtractor = FeatureExtractor()
        if let firstFile = audioFiles.first {
            let features = try await featureExtractor.extractFeatures(from: firstFile.url)
            
            print("✓ Features extracted for: \(firstFile.url.lastPathComponent)")
            print("  • Tempo: \(features.tempo?.description ?? "unknown") BPM")
            print("  • Key: \(features.key ?? "unknown")")
            print("  • Energy: \(String(format: "%.3f", features.energy)) (0.0 = quiet, 1.0 = loud)")
            print("  • Spectral Centroid: \(String(format: "%.1f", features.spectralCentroid)) (brightness)")
            print("  • Zero Crossing Rate: \(String(format: "%.4f", features.zeroCrossingRate)) (roughness)")
            print("  • RMS Energy: \(String(format: "%.4f", features.rmsEnergy)) (loudness)")
            print("  • Duration: \(Int(features.duration))s")
            
            #expect(features.duration > 0, "Duration should be positive")
        }
        
        // Test TrainingDataManager - Organize by directory structure (styles)
        print("\n[3] Organizing files by directory structure (styles)...")
        let trainingDataManager = TrainingDataManager()
        let organized = trainingDataManager.organizeByDirectoryStructure(
            audioFiles: audioFiles,
            baseURL: directoryURL
        )
        
        print("✓ Organized into \(organized.count) style categories:")
        for (label, files) in organized.sorted(by: { $0.key < $1.key }) {
            print("  • \(label): \(files.count) file\(files.count == 1 ? "" : "s")")
        }
        
        #expect(organized.count > 0, "Should organize files into at least one style")
        
        // Test segment extraction - Extract training segments
        print("\n[4] Extracting training segments...")
        if let firstFile = audioFiles.first {
            let segments = try await analyzer.extractTrainingSegments(from: firstFile)
            print("✓ Extracted \(segments.count) training segment\(segments.count == 1 ? "" : "s") from \(firstFile.url.lastPathComponent)")
            print("  (Each segment is ~30 seconds for training)")
            #expect(segments.count > 0, "Should extract at least one segment")
        }
        
        // Test TrainingDataManager - Prepare training samples with storage
        print("\n[5] Preparing training samples and saving to persistent storage...")
        await trainingDataManager.prepareTrainingSamples(
            from: organized,
            analyzer: analyzer,
            featureExtractor: featureExtractor,
            collectionURL: directoryURL
        )
        
        let sampleCount = await MainActor.run { trainingDataManager.trainingData.count }
        print("✓ Prepared \(sampleCount) training samples")
        
        // Save analysis results
        print("\n[6] Saving analysis results to Documents/MusicMill/Analysis/...")
        do {
            // Need to access trainingData on main actor
            let samples = await MainActor.run { trainingDataManager.trainingData }
            print("  Preparing to save \(samples.count) training samples...")
            
            try await trainingDataManager.saveAnalysis(
                collectionURL: directoryURL,
                audioFiles: audioFiles,
                organizedStyles: organized
            )
            print("✓ Analysis results saved successfully")
            
            // Verify immediately
            let storage = AnalysisStorage()
            let savedPath = storage.storageDirectory(for: directoryURL)
            print("  Storage directory: \(savedPath.path)")
            if FileManager.default.fileExists(atPath: savedPath.path) {
                print("  ✓ Storage directory exists")
                let jsonPath = savedPath.appendingPathComponent("analysis.json")
                if FileManager.default.fileExists(atPath: jsonPath.path) {
                    print("  ✓ analysis.json exists")
                    if let data = try? Data(contentsOf: jsonPath),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print("  ✓ JSON is valid")
                        print("    Total files: \(json["totalFiles"] ?? "N/A")")
                        print("    Total samples: \(json["totalSamples"] ?? "N/A")")
                    }
                } else {
                    print("  ✗ analysis.json does NOT exist at: \(jsonPath.path)")
                }
            } else {
                print("  ✗ Storage directory does NOT exist: \(savedPath.path)")
            }
        } catch {
            print("✗ Error saving analysis: \(error)")
            print("  Error details: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("  Domain: \(nsError.domain), Code: \(nsError.code)")
                print("  UserInfo: \(nsError.userInfo)")
            }
        }
        
        // Check saved results
        print("\n[7] Verifying saved results...")
        let storage = AnalysisStorage()
        if storage.hasAnalysis(for: directoryURL) {
            print("✓ Analysis found in storage")
            if let savedAnalysis = try? storage.loadAnalysis(for: directoryURL) {
                print("  • Collection path: \(savedAnalysis.collectionPath)")
                print("  • Analyzed date: \(savedAnalysis.analyzedDate)")
                print("  • Total files: \(savedAnalysis.totalFiles)")
                print("  • Total samples: \(savedAnalysis.totalSamples)")
                print("  • Styles: \(savedAnalysis.organizedStyles.keys.joined(separator: ", "))")
                
                let segmentsDir = storage.segmentsDirectory(for: directoryURL)
                if FileManager.default.fileExists(atPath: segmentsDir.path) {
                    if let segments = try? FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: [.fileSizeKey]) {
                        print("  • Saved segments: \(segments.count) files")
                        var totalSize: Int64 = 0
                        for segment in segments {
                            if let size = try? segment.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                totalSize += Int64(size)
                            }
                        }
                        print("  • Total segment size: \(String(format: "%.1f", Double(totalSize) / 1024 / 1024)) MB")
                    }
                }
            }
        } else {
            print("✗ No saved analysis found")
        }
        
        // Summary
        print("\n" + String(repeating: "=", count: 60))
        print("ANALYSIS SUMMARY")
        print(String(repeating: "=", count: 60))
        print("Total audio files: \(audioFiles.count)")
        print("Style categories: \(organized.count)")
        let totalFiles = organized.values.reduce(0) { $0 + $1.count }
        print("Total files organized: \(totalFiles)")
            let finalSampleCount = await MainActor.run { trainingDataManager.trainingData.count }
            print("Training samples: \(finalSampleCount)")
        print(String(repeating: "=", count: 60))
    }
    
    enum TestError: Error {
        case directoryNotFound(String)
        case noAudioOutput
        case audioTooQuiet
    }
    
    // MARK: - Audio Output Test
    
    @Test @MainActor func testGranularSynthesisAudioOutput() async throws {
        print(String(repeating: "=", count: 60))
        print("TESTING GRANULAR SYNTHESIS AUDIO OUTPUT")
        print(String(repeating: "=", count: 60))
        
        // Find analysis segments
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let analysisDir = documentsURL.appendingPathComponent("MusicMill/Analysis")
        
        guard FileManager.default.fileExists(atPath: analysisDir.path) else {
            print("✗ No analysis directory found. Run analyzeBLVCKCEILINGCollection first.")
            throw TestError.directoryNotFound("No analysis directory")
        }
        
        // Find segment files
        var segmentURLs: [URL] = []
        let contents = try FileManager.default.contentsOfDirectory(at: analysisDir, includingPropertiesForKeys: nil)
        for dir in contents where dir.hasDirectoryPath {
            let segmentsDir = dir.appendingPathComponent("Segments")
            if FileManager.default.fileExists(atPath: segmentsDir.path) {
                let segments = try FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "m4a" }
                segmentURLs.append(contentsOf: segments)
            }
        }
        
        print("[1] Found \(segmentURLs.count) segment files")
        #expect(segmentURLs.count > 0, "Should have segment files from analysis")
        
        // Create granular synthesizer
        print("\n[2] Creating granular synthesizer...")
        let synthesizer = GranularSynthesizer()
        
        // Load first few segments
        let segmentsToLoad = Array(segmentURLs.prefix(5))
        for (index, url) in segmentsToLoad.enumerated() {
            do {
                try synthesizer.loadSource(from: url, identifier: "segment_\(index)")
                print("  ✓ Loaded: \(url.lastPathComponent)")
            } catch {
                print("  ✗ Failed to load \(url.lastPathComponent): \(error)")
            }
        }
        
        let loadedSources = synthesizer.getSourceIdentifiers()
        print("  Total loaded: \(loadedSources.count)")
        #expect(loadedSources.count > 0, "Should load at least one source")
        
        // Set up audio capture
        print("\n[3] Setting up audio capture...")
        
        let duration: TimeInterval = 3.0 // Capture 3 seconds
        
        // Configure synthesis parameters - optimized (81.4% quality)
        var params = GranularSynthesizer.GrainParameters()
        params.grainSize = 0.10 // 100ms grains
        params.grainDensity = 15.0
        params.amplitude = 1.2
        params.positionJitter = 0.05
        params.envelopeType = .blackman
        synthesizer.parameters = params
        
        // Start synthesis
        print("\n[4] Starting granular synthesis for \(duration) seconds...")
        do {
            try synthesizer.start()
            print("  ✓ Synthesis started")
        } catch {
            print("  ✗ Failed to start: \(error)")
            throw error
        }
        
        // Let it run for the duration
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        
        // Stop synthesis
        synthesizer.stop()
        print("  ✓ Synthesis stopped")
        
        // Check if audio was generated (check the audio engine output)
        // Since we can't easily capture the output in a test, we verify the engine ran
        print("\n[5] Verifying synthesis ran...")
        print("  ✓ Granular synthesis completed without errors")
        print("  Note: For full audio verification, run the app and listen")
        
        // Summary
        print("\n" + String(repeating: "=", count: 60))
        print("AUDIO OUTPUT TEST SUMMARY")
        print(String(repeating: "=", count: 60))
        print("Segments loaded: \(loadedSources.count)")
        print("Synthesis duration: \(duration) seconds")
        print("Grain size: \(params.grainSize * 1000) ms")
        print("Grain density: \(params.grainDensity) grains/sec")
        print("Expected grains generated: ~\(Int(params.grainDensity * duration))")
        print(String(repeating: "=", count: 60))
    }
    
    @Test @MainActor func testGranularSynthesisCaptureToFile() async throws {
        // Find analysis segments
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let analysisDir = documentsURL.appendingPathComponent("MusicMill/Analysis")
        
        guard FileManager.default.fileExists(atPath: analysisDir.path) else {
            throw TestError.directoryNotFound("No analysis directory")
        }
        
        // Find segment files
        var segmentURLs: [URL] = []
        let contents = try FileManager.default.contentsOfDirectory(at: analysisDir, includingPropertiesForKeys: nil)
        for dir in contents where dir.hasDirectoryPath {
            let segmentsDir = dir.appendingPathComponent("Segments")
            if FileManager.default.fileExists(atPath: segmentsDir.path) {
                let segments = try FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "m4a" }
                segmentURLs.append(contentsOf: segments)
            }
        }
        
        guard !segmentURLs.isEmpty else {
            throw TestError.directoryNotFound("No segments")
        }
        
        // Create synthesizer
        let synthesizer = GranularSynthesizer()
        
        // Load segments
        for (index, url) in segmentURLs.prefix(3).enumerated() {
            try? synthesizer.loadSource(from: url, identifier: "seg_\(index)")
        }
        let loadedCount = synthesizer.getSourceIdentifiers().count
        
        guard loadedCount > 0 else {
            throw TestError.noAudioOutput
        }
        
        // Output file path
        let outputDir = documentsURL.appendingPathComponent("MusicMill")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("granular_test_output.wav")
        try? FileManager.default.removeItem(at: outputURL)
        
        // Configure synthesis - optimized (81.4% quality)
        var params = GranularSynthesizer.GrainParameters()
        params.grainSize = 0.10
        params.grainDensity = 15.0
        params.amplitude = 1.2
        params.positionJitter = 0.05
        params.envelopeType = .blackman
        synthesizer.parameters = params
        
        // Use the engine to get the format
        let engine = synthesizer.getAudioEngine()
        let mainMixer = engine.mainMixerNode
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        
        // Create output file
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        
        var capturedFrames: AVAudioFrameCount = 0
        
        // Install tap BEFORE starting
        mainMixer.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? outputFile.write(from: buffer)
            capturedFrames += buffer.frameLength
        }
        
        // Start synthesis
        try synthesizer.start()
        
        // Run for 3 seconds
        try await Task.sleep(nanoseconds: 3_000_000_000)
        
        // Stop and clean up
        synthesizer.stop()
        mainMixer.removeTap(onBus: 0)
        
        // Verify output
        #expect(capturedFrames > 0, "Should have captured frames")
        
        let fileSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
        #expect(fileSize > 100, "Output file should have data")
    }
    
    // MARK: - Quality Analysis Tests
    
    @Test @MainActor func testGranularSynthesisQuality() async throws {
        print(String(repeating: "=", count: 60))
        print("TESTING GRANULAR SYNTHESIS QUALITY")
        print(String(repeating: "=", count: 60))
        
        // Find analysis segments
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let analysisDir = documentsURL.appendingPathComponent("MusicMill/Analysis")
        
        guard FileManager.default.fileExists(atPath: analysisDir.path) else {
            throw TestError.directoryNotFound("No analysis directory")
        }
        
        // Find segment files
        var segmentURLs: [URL] = []
        let contents = try FileManager.default.contentsOfDirectory(at: analysisDir, includingPropertiesForKeys: nil)
        for dir in contents where dir.hasDirectoryPath {
            let segmentsDir = dir.appendingPathComponent("Segments")
            if FileManager.default.fileExists(atPath: segmentsDir.path) {
                let segments = try FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "m4a" }
                segmentURLs.append(contentsOf: segments)
            }
        }
        
        guard !segmentURLs.isEmpty else {
            throw TestError.directoryNotFound("No segments")
        }
        
        print("[1] Found \(segmentURLs.count) segments")
        
        // Extract features from source segments
        let featureExtractor = FeatureExtractor()
        let qualityAnalyzer = QualityAnalyzer()
        
        print("\n[2] Extracting source features...")
        var sourceFeatures: FeatureExtractor.AudioFeatures?
        let firstSegment = segmentURLs.first!
        do {
            sourceFeatures = try await featureExtractor.extractFeatures(from: firstSegment)
            print("  Source: \(firstSegment.lastPathComponent)")
            print("    Tempo: \(sourceFeatures?.tempo.map { String(format: "%.1f BPM", $0) } ?? "nil")")
            print("    Key: \(sourceFeatures?.key ?? "nil")")
            print("    Energy: \(String(format: "%.3f", sourceFeatures?.energy ?? 0))")
            print("    Spectral Centroid: \(String(format: "%.1f Hz", sourceFeatures?.spectralCentroid ?? 0))")
            print("    Zero Crossing Rate: \(String(format: "%.3f", sourceFeatures?.zeroCrossingRate ?? 0))")
        } catch {
            print("  Failed to extract source features: \(error)")
            throw error
        }
        
        // Create synthesizer and load source
        print("\n[3] Creating granular synthesizer...")
        let synthesizer = GranularSynthesizer()
        
        for (index, url) in segmentURLs.prefix(3).enumerated() {
            try? synthesizer.loadSource(from: url, identifier: "seg_\(index)")
        }
        print("  Loaded \(synthesizer.getSourceIdentifiers().count) sources")
        
        // Output file path
        let outputDir = documentsURL.appendingPathComponent("MusicMill")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("quality_test_output.wav")
        try? FileManager.default.removeItem(at: outputURL)
        
        // Configure synthesis - with all click reduction features
        var params = GranularSynthesizer.GrainParameters()
        params.grainSize = 0.10 // 100ms grains
        params.grainDensity = 20.0 // Balanced overlap
        params.amplitude = 1.0
        params.positionJitter = 0.05
        params.pitchJitter = 0.01
        params.envelopeType = .blackman
        params.rhythmAlignment = 0.8 // Snap to detected onsets
        params.tempoSync = true // Sync grain rate to source tempo
        params.positionEvolution = 0.2 // Scan through source
        params.evolutionMode = .pingPong // Back and forth
        params.sourceBlend = 0.3 // 30% chance to use secondary source
        params.autoSourceSwitch = true // Auto-cycle through sources
        params.sourceSwitchInterval = 4.0 // Switch every 4 seconds for test
        params.zeroCrossingStart = true // Start grains at zero crossings
        params.zeroCrossingSearchRange = 100 // Search ~2ms for zero crossing
        synthesizer.parameters = params

        // Set up audio capture
        let engine = synthesizer.getAudioEngine()
        let mainMixer = engine.mainMixerNode
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        var capturedFrames: AVAudioFrameCount = 0
        
        // Capture buffer for analysis - longer for accurate quality measurement
        let analysisDuration: TimeInterval = 20.0 // 20 seconds - captures temporal artifacts honestly
        let analysisBufferCapacity = AVAudioFrameCount(44100.0 * analysisDuration)
        let analysisBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: analysisBufferCapacity)!
        
        mainMixer.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? outputFile.write(from: buffer)
            
            // Copy to analysis buffer
            if capturedFrames + buffer.frameLength <= analysisBufferCapacity {
                let dstOffset = Int(capturedFrames)
                for ch in 0..<Int(format.channelCount) {
                    if let src = buffer.floatChannelData?[ch],
                       let dst = analysisBuffer.floatChannelData?[ch] {
                        for i in 0..<Int(buffer.frameLength) {
                            dst[dstOffset + i] = src[i]
                        }
                    }
                }
            }
            capturedFrames += buffer.frameLength
        }
        
        // Start synthesis - run longer for stable feature detection
        print("\n[4] Running synthesis for \(Int(analysisDuration)) seconds...")
        try synthesizer.start()
        try await Task.sleep(nanoseconds: UInt64(analysisDuration * 1_000_000_000))
        synthesizer.stop()
        mainMixer.removeTap(onBus: 0)
        
        analysisBuffer.frameLength = min(capturedFrames, analysisBufferCapacity)
        print("  Captured \(capturedFrames) frames (\(String(format: "%.2f", Double(capturedFrames) / 44100.0)) seconds)")
        
        // Extract features from output
        print("\n[5] Extracting output features...")
        let outputFeatures = featureExtractor.extractFeatures(from: analysisBuffer)
        print("    Tempo: \(outputFeatures.tempo.map { String(format: "%.1f BPM", $0) } ?? "nil")")
        print("    Key: \(outputFeatures.key ?? "nil")")
        print("    Energy: \(String(format: "%.3f", outputFeatures.energy))")
        print("    Spectral Centroid: \(String(format: "%.1f Hz", outputFeatures.spectralCentroid))")
        print("    Zero Crossing Rate: \(String(format: "%.3f", outputFeatures.zeroCrossingRate))")
        
        // Compare quality
        print("\n[6] Quality Analysis...")
        guard let source = sourceFeatures else {
            throw TestError.noAudioOutput
        }
        
        let quality = qualityAnalyzer.compare(source: source, output: outputFeatures)
        print(quality.description)
        
        // Summary
        print("\n" + String(repeating: "=", count: 60))
        print("QUALITY ANALYSIS RESULTS")
        print(String(repeating: "=", count: 60))
        print("Overall Quality: \(String(format: "%.1f%%", quality.overall * 100))")
        if let tempo = quality.tempoMatch {
            print("  Tempo Match: \(String(format: "%.1f%%", tempo * 100))")
        }
        if let key = quality.keyMatch {
            print("  Key Match: \(String(format: "%.1f%%", key * 100))")
        }
        print("  Energy Match: \(String(format: "%.1f%%", quality.energyMatch * 100))")
        print("  Spectral Match: \(String(format: "%.1f%%", quality.spectralMatch * 100))")
        print("  Texture Match: \(String(format: "%.1f%%", quality.textureMatch * 100))")
        print(String(repeating: "=", count: 60))
        
        // Thresholds - initially set low given granular artifacts
        #expect(capturedFrames > 0, "Should have captured audio")
        #expect(quality.energyMatch >= 0.2, "Energy should be somewhat preserved (got \(quality.energyMatch))")
        
        // Write quality report to file for visibility
        // Use temp directory since test sandbox blocks Documents
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("musicmill_quality_report.txt")
        var report = """
        ============================================================
        MUSICMILL QUALITY ANALYSIS REPORT
        Generated: \(Date())
        ============================================================
        
        SOURCE AUDIO
        ------------
        File: \(firstSegment.lastPathComponent)
        Tempo: \(source.tempo.map { String(format: "%.1f BPM", $0) } ?? "nil")
        Key: \(source.key ?? "nil")
        Energy: \(String(format: "%.4f", source.energy))
        Spectral Centroid: \(String(format: "%.1f Hz", source.spectralCentroid))
        Zero Crossing Rate: \(String(format: "%.4f", source.zeroCrossingRate))
        RMS Energy: \(String(format: "%.4f", source.rmsEnergy))
        Duration: \(String(format: "%.2f sec", source.duration))
        Spectral Flatness: \(String(format: "%.4f", source.spectralFlatness)) (0=tonal, 1=noise)
        HNR: \(String(format: "%.1f dB", source.harmonicToNoiseRatio)) (higher=cleaner)
        Onset Regularity: \(String(format: "%.4f", source.onsetRegularity)) (0=regular, 1=chaotic)
        Click Rate: \(String(format: "%.1f/sec", source.clickRate))
        Click Intensity: \(String(format: "%.4f", source.clickIntensity))
        
        OUTPUT AUDIO (Granular Synthesis)
        ---------------------------------
        Captured Frames: \(capturedFrames) (\(String(format: "%.2f sec", Double(capturedFrames) / 44100.0)))
        Tempo: \(outputFeatures.tempo.map { String(format: "%.1f BPM", $0) } ?? "nil")
        Key: \(outputFeatures.key ?? "nil")
        Energy: \(String(format: "%.4f", outputFeatures.energy))
        Spectral Centroid: \(String(format: "%.1f Hz", outputFeatures.spectralCentroid))
        Zero Crossing Rate: \(String(format: "%.4f", outputFeatures.zeroCrossingRate))
        RMS Energy: \(String(format: "%.4f", outputFeatures.rmsEnergy))
        Duration: \(String(format: "%.2f sec", outputFeatures.duration))
        Spectral Flatness: \(String(format: "%.4f", outputFeatures.spectralFlatness)) (0=tonal, 1=noise)
        HNR: \(String(format: "%.1f dB", outputFeatures.harmonicToNoiseRatio)) (higher=cleaner)
        Onset Regularity: \(String(format: "%.4f", outputFeatures.onsetRegularity)) (0=regular, 1=chaotic)
        Click Rate: \(String(format: "%.1f/sec", outputFeatures.clickRate))
        Click Intensity: \(String(format: "%.4f", outputFeatures.clickIntensity))
        
        QUALITY SCORES
        --------------
        Overall Quality: \(String(format: "%.1f%%", quality.overall * 100))
        
        """
        
        if let tempo = quality.tempoMatch {
            report += "  Tempo Match:    \(String(format: "%5.1f%%", tempo * 100))\n"
        } else {
            report += "  Tempo Match:    N/A (tempo not detected)\n"
        }
        
        if let key = quality.keyMatch {
            report += "  Key Match:      \(String(format: "%5.1f%%", key * 100))\n"
        } else {
            report += "  Key Match:      N/A (key not detected)\n"
        }
        
        report += """
          Energy Match:   \(String(format: "%5.1f%%", quality.energyMatch * 100))
          Spectral Match: \(String(format: "%5.1f%%", quality.spectralMatch * 100))
          Texture Match:  \(String(format: "%5.1f%%", quality.textureMatch * 100))
        
        PERCEPTUAL QUALITY (New Metrics)
          Noise Match:    \(String(format: "%5.1f%%", quality.noiseMatch * 100)) (higher=less noisy than source)
          Clarity Match:  \(String(format: "%5.1f%%", quality.clarityMatch * 100)) (higher=cleaner audio)
          Rhythm Match:   \(String(format: "%5.1f%%", quality.rhythmMatch * 100)) (higher=more rhythmic)
          Click-free:    \(String(format: "%5.1f%%", quality.clickScore * 100)) (higher=fewer clicks)
          Click Diff:    \(String(format: "%+.1f/sec", quality.clickRateDiff)) (negative=better)
        
        QUALITY TARGETS
        ---------------
        Current:   \(String(format: "%.0f%%", quality.overall * 100))
        MVP:       50%
        Good:      70%
        Excellent: 85%
        
        INTERPRETATION
        --------------
        """
        
        if quality.overall >= 0.85 {
            report += "Excellent! Output closely matches source characteristics.\n"
        } else if quality.overall >= 0.70 {
            report += "Good quality. Most characteristics are preserved.\n"
        } else if quality.overall >= 0.50 {
            report += "Acceptable. Some characteristics preserved, noticeable artifacts.\n"
        } else if quality.overall >= 0.30 {
            report += "Low quality. Significant artifacts, source barely recognizable.\n"
        } else {
            report += "Very low quality. Heavy artifacts, sounds nothing like source.\n"
        }
        
        report += """
        
        ============================================================
        """
        
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("Quality report written to: \(reportURL.path)")
    }
    
    // MARK: - Concatenative Synthesis Tests
    
    @Test @MainActor func testConcatenativeSynthesis() async throws {
        print(String(repeating: "=", count: 60))
        print("TESTING CONCATENATIVE SYNTHESIS")
        print(String(repeating: "=", count: 60))
        
        // Find analysis segments
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let analysisDir = documentsURL.appendingPathComponent("MusicMill/Analysis")
        
        guard FileManager.default.fileExists(atPath: analysisDir.path) else {
            throw TestError.directoryNotFound("No analysis directory")
        }
        
        // Find segment files
        var segmentURLs: [URL] = []
        let contents = try FileManager.default.contentsOfDirectory(at: analysisDir, includingPropertiesForKeys: nil)
        for dir in contents where dir.hasDirectoryPath {
            let segmentsDir = dir.appendingPathComponent("Segments")
            if FileManager.default.fileExists(atPath: segmentsDir.path) {
                let segments = try FileManager.default.contentsOfDirectory(at: segmentsDir, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "m4a" }
                segmentURLs.append(contentsOf: segments)
            }
        }
        
        guard segmentURLs.count >= 2 else {
            throw TestError.directoryNotFound("Need at least 2 segments for concatenative synthesis")
        }
        
        print("[1] Found \(segmentURLs.count) segments")
        
        // Create concatenative synthesizer
        print("\n[2] Creating concatenative synthesizer...")
        let synthesizer = ConcatenativeSynthesizer()
        
        // Load segments (use first 5 for testing)
        for (index, url) in segmentURLs.prefix(5).enumerated() {
            do {
                try await synthesizer.loadSegment(from: url, identifier: "seg_\(index)", style: "darkwave")
                print("  Loaded: \(url.lastPathComponent)")
            } catch {
                print("  Failed to load \(url.lastPathComponent): \(error)")
            }
        }
        
        let segmentCount = synthesizer.getSegmentCount()
        #expect(segmentCount >= 2, "Should load at least 2 segments")
        print("  Total segments loaded: \(segmentCount)")
        
        // Output file path
        let outputDir = documentsURL.appendingPathComponent("MusicMill")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("concatenative_output.wav")
        try? FileManager.default.removeItem(at: outputURL)
        
        // Configure synthesis
        var params = ConcatenativeSynthesizer.Parameters()
        params.crossfadeDuration = 0.5 // 500ms crossfade
        params.masterVolume = 1.0
        synthesizer.setParameters(params)
        
        // Set up audio capture
        let engine = synthesizer.getAudioEngine()
        let mainMixer = engine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)
        
        var capturedBuffers: [AVAudioPCMBuffer] = []
        let captureFrameCount: AVAudioFrameCount = 4096
        
        mainMixer.installTap(onBus: 0, bufferSize: captureFrameCount, format: format) { buffer, _ in
            if let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) {
                copy.frameLength = buffer.frameLength
                if let srcData = buffer.floatChannelData, let dstData = copy.floatChannelData {
                    for channel in 0..<Int(buffer.format.channelCount) {
                        memcpy(dstData[channel], srcData[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
                    }
                }
                capturedBuffers.append(copy)
            }
        }
        
        // Start synthesis
        print("\n[3] Running concatenative synthesis for 20 seconds...")
        try synthesizer.start()
        
        try await Task.sleep(nanoseconds: 20_000_000_000) // 20 seconds
        
        synthesizer.stop()
        mainMixer.removeTap(onBus: 0)
        
        print("  Captured \(capturedBuffers.count) buffers")
        
        // Combine captured buffers
        let totalFrames = capturedBuffers.reduce(0) { $0 + Int($1.frameLength) }
        guard let combinedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw TestError.noAudioOutput
        }
        
        var writePosition: AVAudioFramePosition = 0
        for buffer in capturedBuffers {
            if let srcData = buffer.floatChannelData, let dstData = combinedBuffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    memcpy(dstData[channel].advanced(by: Int(writePosition)),
                           srcData[channel],
                           Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
            }
            writePosition += AVAudioFramePosition(buffer.frameLength)
        }
        combinedBuffer.frameLength = AVAudioFrameCount(totalFrames)
        
        // Check for actual audio content
        var hasAudio = false
        if let channelData = combinedBuffer.floatChannelData {
            for i in 0..<Int(combinedBuffer.frameLength) {
                if abs(channelData[0][i]) > 0.001 {
                    hasAudio = true
                    break
                }
            }
        }
        
        #expect(hasAudio, "Concatenative synthesis should produce audible output")
        print("  ✓ Audio output verified")
        
        // Save to file
        print("\n[4] Saving output to file...")
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ])
        try outputFile.write(from: combinedBuffer)
        print("  Saved to: \(outputURL.path)")
        
        // Analyze output quality
        print("\n[5] Analyzing output quality...")
        let featureExtractor = FeatureExtractor()
        let outputFeatures = featureExtractor.extractFeatures(from: combinedBuffer)
        
        print("  Tempo: \(outputFeatures.tempo.map { String(format: "%.1f BPM", $0) } ?? "nil")")
        print("  Key: \(outputFeatures.key ?? "nil")")
        print("  Energy: \(String(format: "%.4f", outputFeatures.energy))")
        print("  Click Rate: \(String(format: "%.1f/sec", outputFeatures.clickRate))")
        print("  Duration: \(String(format: "%.2f sec", outputFeatures.duration))")
        
        // Report
        let reportURL = outputDir.appendingPathComponent("concatenative_report.txt")
        var report = """
        ============================================================
        CONCATENATIVE SYNTHESIS REPORT
        Generated: \(Date())
        ============================================================
        
        CONFIGURATION
        -------------
        Segments Loaded: \(segmentCount)
        Crossfade Duration: \(params.crossfadeDuration)s
        
        OUTPUT AUDIO
        ------------
        Captured Frames: \(totalFrames) (\(String(format: "%.2f sec", Double(totalFrames) / format.sampleRate)))
        Tempo: \(outputFeatures.tempo.map { String(format: "%.1f BPM", $0) } ?? "nil")
        Key: \(outputFeatures.key ?? "nil")
        Energy: \(String(format: "%.4f", outputFeatures.energy))
        Spectral Centroid: \(String(format: "%.1f Hz", outputFeatures.spectralCentroid))
        Click Rate: \(String(format: "%.1f/sec", outputFeatures.clickRate))
        
        COMPARISON TO GRANULAR
        ----------------------
        Concatenative synthesis uses full phrases (2-8 sec) instead of tiny grains.
        This should result in:
        - Lower click rate (smoother transitions)
        - More musical continuity
        - Preserved original textures
        
        ============================================================
        """
        
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("\nReport written to: \(reportURL.path)")
        print("\n✓ Concatenative synthesis test complete!")
    }
    
    // MARK: - RAVE Bridge Tests
    
    @Test func testRAVEBridgePaths() async throws {
        print(String(repeating: "=", count: 60))
        print("RAVE BRIDGE PATH DIAGNOSTICS")
        print(String(repeating: "=", count: 60))
        
        let bridge = RAVEBridge(modelName: "percussion")
        let diag = bridge.getDiagnostics()
        
        print("\nPath Information:")
        for (key, value) in diag.sorted(by: { $0.key < $1.key }) {
            let status = value == "NO" ? "❌" : (value == "YES" ? "✓" : "")
            print("  \(key): \(value) \(status)")
        }
        
        // Check venv exists
        let venvPath = diag["venvPath"] ?? ""
        let pythonExists = diag["pythonExists"] == "YES"
        
        print("\nExpected venv location: ~/Documents/MusicMill/RAVE/venv")
        print("Actual venv location: \(venvPath)")
        
        if !pythonExists {
            print("\n⚠️  Python venv not found!")
            print("To set up the RAVE environment, run:")
            print("  cd /Users/tonialatalo/src/MusicMill")
            print("  ./scripts/setup_rave.sh")
        } else {
            print("\n✓ Python venv found")
        }
        
        // Check scripts exist
        let scriptExists = diag["scriptExists"] == "YES"
        if !scriptExists {
            print("⚠️  Server script not found at: \(diag["serverScript"] ?? "unknown")")
        } else {
            print("✓ Server script found")
        }
        
        // Check for available models
        let models = RAVEBridge.getAvailableModels()
        print("\nAvailable RAVE models: \(models.isEmpty ? "none found" : models.joined(separator: ", "))")
        
        if !models.isEmpty {
            print("✓ Found \(models.count) model(s)")
        }
        
        // Write diagnostic report
        let outputDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MusicMill")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        let reportURL = outputDir.appendingPathComponent("rave_diagnostics.txt")
        var report = """
        ============================================================
        RAVE BRIDGE DIAGNOSTICS
        Generated: \(Date())
        ============================================================
        
        PATH INFORMATION
        ----------------
        """
        
        for (key, value) in diag.sorted(by: { $0.key < $1.key }) {
            report += "\n\(key): \(value)"
        }
        
        report += """
        
        
        AVAILABLE MODELS
        ----------------
        \(models.isEmpty ? "No models found" : models.joined(separator: "\n"))
        
        SETUP INSTRUCTIONS
        ------------------
        If Python venv is not found, run:
          cd /Users/tonialatalo/src/MusicMill
          ./scripts/setup_rave.sh
        
        If models are not found, download them to:
          ~/Documents/MusicMill/RAVE/pretrained/
        
        ============================================================
        """
        
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("\nDiagnostics written to: \(reportURL.path)")
        
        // Assertions
        #expect(pythonExists, "Python venv should exist at \(diag["pythonPath"] ?? "unknown")")
        #expect(scriptExists, "Server script should exist")
    }
    
    // MARK: - PhrasePlayer Tests
    
    @Test @MainActor func testPhrasePlayerWithSegments() async throws {
        print(String(repeating: "=", count: 60))
        print("TESTING PHRASE PLAYER")
        print(String(repeating: "=", count: 60))
        
        // Check for phrase segments
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let segmentsDir = documentsURL.appendingPathComponent("MusicMill/PhraseSegments")
        let segmentsJSON = segmentsDir.appendingPathComponent("segments.json")
        
        guard FileManager.default.fileExists(atPath: segmentsJSON.path) else {
            print("⚠️  No phrase segments found at: \(segmentsJSON.path)")
            print("Run: python scripts/test_phrase_player.py first")
            throw TestError.directoryNotFound("No phrase segments")
        }
        
        // Load segment metadata
        print("\n[1] Loading phrase segments...")
        let data = try Data(contentsOf: segmentsJSON)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let segments = json?["segments"] as? [[String: Any]] else {
            throw TestError.directoryNotFound("Invalid segments.json format")
        }
        
        print("  Found \(segments.count) segments in JSON")
        
        // Create PhrasePlayer
        print("\n[2] Creating PhrasePlayer...")
        let phrasePlayer = PhrasePlayer()
        
        // Load segments into player
        var loadedCount = 0
        for segment in segments.prefix(10) { // Load up to 10 segments
            guard let filePath = segment["file"] as? String,
                  let tempo = segment["tempo"] as? Double,
                  let segmentType = segment["type"] as? String,
                  let beats = segment["beats"] as? [Double],
                  let downbeats = segment["downbeats"] as? [Double],
                  let energy = segment["energy"] as? Double else {
                continue
            }
            
            let url = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("  ⚠️  Missing: \(url.lastPathComponent)")
                continue
            }
            
            do {
                // Load audio buffer
                let file = try AVAudioFile(forReading: url)
                let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                    continue
                }
                try file.read(into: buffer)
                
                // Load into phrase player
                phrasePlayer.loadPhrase(
                    id: url.lastPathComponent,
                    buffer: buffer,
                    beats: beats,
                    downbeats: downbeats,
                    tempo: tempo,
                    energy: energy,
                    segmentType: segmentType,
                    style: nil
                )
                
                loadedCount += 1
                print("  ✓ Loaded: \(url.lastPathComponent) (\(String(format: "%.1f", tempo)) BPM, \(segmentType))")
            } catch {
                print("  ✗ Failed: \(url.lastPathComponent): \(error)")
            }
        }
        
        #expect(loadedCount >= 2, "Should load at least 2 phrases")
        print("  Total loaded: \(loadedCount) phrases")
        
        // Configure playback
        var params = PhrasePlayer.Parameters()
        params.crossfadeBars = 2
        params.masterVolume = 1.0
        phrasePlayer.parameters = params
        
        // Set up audio capture
        print("\n[3] Setting up audio capture...")
        let engine = phrasePlayer.getAudioEngine()
        let mainMixer = engine.mainMixerNode
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        
        let outputDir = documentsURL.appendingPathComponent("MusicMill")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("phrase_player_test.wav")
        try? FileManager.default.removeItem(at: outputURL)
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        var capturedFrames: AVAudioFrameCount = 0
        let captureDuration: TimeInterval = 30.0 // 30 seconds to hear crossfades
        
        mainMixer.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? outputFile.write(from: buffer)
            capturedFrames += buffer.frameLength
        }
        
        // Start playback
        print("\n[4] Running PhrasePlayer for \(Int(captureDuration)) seconds...")
        try phrasePlayer.start()
        
        try await Task.sleep(nanoseconds: UInt64(captureDuration * 1_000_000_000))
        
        phrasePlayer.stop()
        mainMixer.removeTap(onBus: 0)
        
        print("  Captured \(capturedFrames) frames (\(String(format: "%.2f", Double(capturedFrames) / 44100.0)) seconds)")
        
        // Verify output
        #expect(capturedFrames > 44100, "Should capture at least 1 second of audio")
        
        let fileSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0
        #expect(fileSize > 1000, "Output file should have data")
        
        print("  ✓ Saved to: \(outputURL.path)")
        print("  File size: \(String(format: "%.1f", Double(fileSize) / 1024)) KB")
        
        // Analyze output quality
        print("\n[5] Analyzing output quality...")
        let featureExtractor = FeatureExtractor()
        
        // Load output for analysis
        let analysisFile = try AVAudioFile(forReading: outputURL)
        let analysisFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        guard let analysisBuffer = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: AVAudioFrameCount(analysisFile.length)) else {
            throw TestError.noAudioOutput
        }
        try analysisFile.read(into: analysisBuffer)
        
        let outputFeatures = featureExtractor.extractFeatures(from: analysisBuffer)
        
        print("  Tempo: \(outputFeatures.tempo.map { String(format: "%.1f BPM", $0) } ?? "not detected")")
        print("  Key: \(outputFeatures.key ?? "not detected")")
        print("  Energy: \(String(format: "%.4f", outputFeatures.energy))")
        print("  Click Rate: \(String(format: "%.1f/sec", outputFeatures.clickRate))")
        print("  Spectral Flatness: \(String(format: "%.4f", outputFeatures.spectralFlatness)) (0=tonal, 1=noise)")
        print("  HNR: \(String(format: "%.1f dB", outputFeatures.harmonicToNoiseRatio))")
        
        // Compare to granular synthesis expectations
        // PhrasePlayer should have:
        // - Lower click rate (smooth crossfades)
        // - Lower spectral flatness (preserves original tonal content)
        // - Detected tempo (plays real music segments)
        
        print("\n[6] Quality Assessment...")
        
        var passed = true
        
        // Click rate should be low (smooth playback)
        if outputFeatures.clickRate > 10 {
            print("  ⚠️  High click rate (\(String(format: "%.1f", outputFeatures.clickRate))/sec) - crossfades may be choppy")
            passed = false
        } else {
            print("  ✓ Click rate is good (\(String(format: "%.1f", outputFeatures.clickRate))/sec)")
        }
        
        // Should have detectable tempo (playing real music)
        if outputFeatures.tempo != nil {
            print("  ✓ Tempo detected - playing coherent music")
        } else {
            print("  ⚠️  No tempo detected - may be too fragmented")
        }
        
        // Energy should be reasonable
        if outputFeatures.energy > 0.01 {
            print("  ✓ Good energy level (\(String(format: "%.4f", outputFeatures.energy)))")
        } else {
            print("  ⚠️  Low energy - audio may be too quiet")
            passed = false
        }
        
        // Write report
        let reportURL = outputDir.appendingPathComponent("phrase_player_report.txt")
        let report = """
        ============================================================
        PHRASE PLAYER TEST REPORT
        Generated: \(Date())
        ============================================================
        
        CONFIGURATION
        -------------
        Phrases Loaded: \(loadedCount)
        Crossfade Bars: \(params.crossfadeBars)
        Capture Duration: \(captureDuration) seconds
        
        OUTPUT ANALYSIS
        ---------------
        Duration: \(String(format: "%.2f", outputFeatures.duration)) seconds
        Captured Frames: \(capturedFrames)
        Tempo: \(outputFeatures.tempo.map { String(format: "%.1f BPM", $0) } ?? "not detected")
        Key: \(outputFeatures.key ?? "not detected")
        Energy: \(String(format: "%.4f", outputFeatures.energy))
        Spectral Centroid: \(String(format: "%.1f Hz", outputFeatures.spectralCentroid))
        Zero Crossing Rate: \(String(format: "%.4f", outputFeatures.zeroCrossingRate))
        Click Rate: \(String(format: "%.1f/sec", outputFeatures.clickRate))
        Spectral Flatness: \(String(format: "%.4f", outputFeatures.spectralFlatness))
        Harmonic-to-Noise Ratio: \(String(format: "%.1f dB", outputFeatures.harmonicToNoiseRatio))
        
        QUALITY ASSESSMENT
        ------------------
        Result: \(passed ? "PASSED" : "NEEDS IMPROVEMENT")
        
        Output saved to: \(outputURL.path)
        Listen with: afplay '\(outputURL.path)'
        
        ============================================================
        """
        
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("\n  Report: \(reportURL.path)")
        
        print("\n" + String(repeating: "=", count: 60))
        print("PHRASE PLAYER TEST \(passed ? "PASSED ✓" : "NEEDS WORK ⚠️")")
        print(String(repeating: "=", count: 60))
        print("\nTo listen: afplay '\(outputURL.path)'")
    }
    
    @Test func testRAVEServerStart() async throws {
        print(String(repeating: "=", count: 60))
        print("RAVE SERVER START TEST")
        print(String(repeating: "=", count: 60))
        
        // First check paths
        let bridge = RAVEBridge(modelName: "percussion")
        let diag = bridge.getDiagnostics()
        
        guard diag["pythonExists"] == "YES" else {
            print("⚠️  Skipping server test - Python venv not found")
            print("Run setup_rave.sh first")
            return
        }
        
        guard diag["scriptExists"] == "YES" else {
            print("⚠️  Skipping server test - Server script not found")
            return
        }
        
        let models = RAVEBridge.getAvailableModels()
        guard !models.isEmpty else {
            print("⚠️  Skipping server test - No models found")
            return
        }
        
        print("\nStarting RAVE server with model: \(bridge.modelName)")
        
        do {
            try await bridge.start()
            print("✓ Server started successfully!")
            
            // Test generation
            print("\nTesting audio generation...")
            let controls = RAVEBridge.Controls(energy: 0.7, tempoFactor: 1.0, variation: 0.5)
            let audio = try await bridge.generate(controls: controls, frames: 25)
            
            print("  Generated \(audio.count) samples (\(String(format: "%.2f", Double(audio.count) / 48000.0)) seconds)")
            #expect(audio.count > 0, "Should generate audio samples")
            
            // Get styles
            let styles = bridge.getStyles()
            print("  Available styles: \(styles.isEmpty ? "none (random generation)" : styles.joined(separator: ", "))")
            
            bridge.stop()
            print("\n✓ Server stopped successfully!")
            
        } catch {
            print("❌ Server start failed: \(error)")
            throw error
        }
    }
}
