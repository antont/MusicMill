import Foundation
import AVFoundation

/// Standalone tool to run analysis and save results
@main
struct RunAnalysis {
    static func main() async {
        let directoryPath = "/Users/tonialatalo/Music/PioneerDJ/Imported from Device/Contents/BLVCKCEILING"
        let directoryURL = URL(fileURLWithPath: directoryPath)
        
        print("=" * 60)
        print("RUNNING ANALYSIS")
        print("=" * 60)
        print("Directory: \(directoryPath)")
        print("")
        
        // Check if directory exists
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        
        guard exists && isDirectory.boolValue else {
            print("✗ Error: Directory not found: \(directoryPath)")
            exit(1)
        }
        
        do {
            // Step 1: Scan directory
            print("[1/6] Scanning directory for audio files...")
            let analyzer = AudioAnalyzer()
            let audioFiles = try await analyzer.scanDirectory(at: directoryURL)
            
            guard !audioFiles.isEmpty else {
                print("✗ Error: No audio files found")
                exit(1)
            }
            
            print("✓ Found \(audioFiles.count) audio files")
            for (index, file) in audioFiles.prefix(3).enumerated() {
                print("  \(index + 1). \(file.url.lastPathComponent) (\(file.format.rawValue.uppercased()), \(Int(file.duration))s)")
            }
            if audioFiles.count > 3 {
                print("  ... and \(audioFiles.count - 3) more")
            }
            
            // Step 2: Extract features from first file
            print("\n[2/6] Extracting audio features...")
            let featureExtractor = FeatureExtractor()
            var featuresExtracted = 0
            if let firstFile = audioFiles.first {
                do {
                    let features = try await featureExtractor.extractFeatures(from: firstFile.url)
                    print("✓ Features extracted for: \(firstFile.url.lastPathComponent)")
                    print("  • Tempo: \(features.tempo?.description ?? "unknown") BPM")
                    print("  • Key: \(features.key ?? "unknown")")
                    print("  • Energy: \(String(format: "%.3f", features.energy))")
                    featuresExtracted = 1
                } catch {
                    print("⚠ Warning: Could not extract features from first file: \(error)")
                }
            }
            
            // Step 3: Organize by directory structure
            print("\n[3/6] Organizing files by directory structure (styles)...")
            let trainingDataManager = TrainingDataManager()
            let organized = trainingDataManager.organizeByDirectoryStructure(
                audioFiles: audioFiles,
                baseURL: directoryURL
            )
            
            print("✓ Organized into \(organized.count) style categories:")
            for (label, files) in organized.sorted(by: { $0.key < $1.key }) {
                print("  • \(label): \(files.count) file\(files.count == 1 ? "" : "s")")
            }
            
            // Step 4: Extract training segments
            print("\n[4/6] Extracting training segments...")
            var totalSegments = 0
            for (index, file) in audioFiles.prefix(5).enumerated() {
                do {
                    let segments = try await analyzer.extractTrainingSegments(from: file)
                    totalSegments += segments.count
                    if index == 0 {
                        print("  ✓ Extracted \(segments.count) segment(s) from \(file.url.lastPathComponent)")
                    }
                } catch {
                    print("  ⚠ Warning: Could not extract segments from \(file.url.lastPathComponent): \(error)")
                }
            }
            print("  (Processed \(min(5, audioFiles.count)) files, extracted \(totalSegments) segments total)")
            
            // Step 5: Prepare training samples with storage
            print("\n[5/6] Preparing training samples and saving to persistent storage...")
            await trainingDataManager.prepareTrainingSamples(
                from: organized,
                analyzer: analyzer,
                featureExtractor: featureExtractor,
                collectionURL: directoryURL
            )
            
            print("✓ Prepared \(trainingDataManager.trainingData.count) training samples")
            
            // Step 6: Save analysis results
            print("\n[6/6] Saving analysis results to Documents/MusicMill/Analysis/...")
            do {
                try trainingDataManager.saveAnalysis(
                    collectionURL: directoryURL,
                    audioFiles: audioFiles,
                    organizedStyles: organized
                )
                print("✓ Analysis results saved successfully")
            } catch {
                print("✗ Error saving analysis: \(error)")
                exit(1)
            }
            
            // Verify saved results
            print("\n[Verification] Checking saved results...")
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
                            
                            // Show a few example segment files
                            print("\n  Example segment files:")
                            for segment in segments.prefix(3) {
                                print("    - \(segment.lastPathComponent)")
                            }
                        }
                    }
                }
            } else {
                print("✗ No saved analysis found")
            }
            
            // Summary
            print("\n" + String(repeating: "=", count: 60))
            print("ANALYSIS COMPLETE")
            print(String(repeating: "=", count: 60))
            print("Total audio files: \(audioFiles.count)")
            print("Style categories: \(organized.count)")
            print("Training samples: \(trainingDataManager.trainingData.count)")
            print("Results saved to: ~/Documents/MusicMill/Analysis/")
            print(String(repeating: "=", count: 60))
            
        } catch {
            print("✗ Error during analysis: \(error)")
            exit(1)
        }
    }
}


