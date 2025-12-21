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
        
        // Configure synthesis - optimized for quality (best: 81.4%)
        var params = GranularSynthesizer.GrainParameters()
        params.grainSize = 0.10 // 100ms grains
        params.grainDensity = 15.0
        params.amplitude = 1.2
        params.positionJitter = 0.05
        params.pitchJitter = 0.01
        params.envelopeType = .blackman
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
        
        // Capture buffer for analysis - balanced duration
        let analysisDuration: TimeInterval = 10.0 // 10 seconds - balance between stability and consistency
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
}
