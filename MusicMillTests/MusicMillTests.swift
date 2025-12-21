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
        
        // Configure synthesis parameters
        var params = GranularSynthesizer.GrainParameters()
        params.grainSize = 0.05 // 50ms grains
        params.grainDensity = 30.0 // 30 grains per second
        params.amplitude = 0.8
        params.positionJitter = 0.2
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
        
        // Configure synthesis
        var params = GranularSynthesizer.GrainParameters()
        params.grainSize = 0.05
        params.grainDensity = 25.0
        params.amplitude = 0.8
        params.positionJitter = 0.2
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
}
