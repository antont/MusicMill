import Foundation
import Combine

/// Manages training dataset organization and metadata
class TrainingDataManager: ObservableObject {
    @Published var trainingData: [TrainingSample] = []
    @Published var isProcessing = false
    @Published var progress: Double = 0.0
    @Published var currentStatus: String = ""
    
    private let storage = AnalysisStorage()
    
    struct TrainingSample {
        let audioURL: URL
        let label: String // Style/genre label
        let features: FeatureExtractor.AudioFeatures?
        let sourceFile: URL
    }
    
    /// Organizes audio files by directory structure (folders = labels)
    func organizeByDirectoryStructure(audioFiles: [AudioAnalyzer.AudioFile], baseURL: URL) -> [String: [AudioAnalyzer.AudioFile]] {
        var organized: [String: [AudioAnalyzer.AudioFile]] = [:]
        
        for audioFile in audioFiles {
            let relativePath = audioFile.url.path.replacingOccurrences(of: baseURL.path + "/", with: "")
            let pathComponents = relativePath.split(separator: "/")
            
            // Use first directory as label, or "Unknown" if in root
            let label = pathComponents.count > 1 ? String(pathComponents[0]) : "Unknown"
            
            if organized[label] == nil {
                organized[label] = []
            }
            organized[label]?.append(audioFile)
        }
        
        return organized
    }
    
    /// Prepares training samples from organized audio files
    func prepareTrainingSamples(
        from organizedFiles: [String: [AudioAnalyzer.AudioFile]],
        analyzer: AudioAnalyzer,
        featureExtractor: FeatureExtractor,
        collectionURL: URL? = nil
    ) async {
        await MainActor.run {
            isProcessing = true
            progress = 0.0
            trainingData = []
        }
        
        var samples: [TrainingSample] = []
        let totalFiles = organizedFiles.values.flatMap { $0 }.count
        var processedFiles = 0
        
        for (label, files) in organizedFiles {
            await MainActor.run {
                currentStatus = "Processing \(label)..."
            }
            
            for file in files {
                do {
                    // Extract segments for training
                    let segments = try await analyzer.extractTrainingSegments(from: file)
                    
                    // Extract features from first segment (or whole file if short)
                    if let firstSegment = segments.first {
                        let features = try? await featureExtractor.extractFeatures(from: firstSegment)
                        
                        for (index, segment) in segments.enumerated() {
                            // Save segment to persistent storage if collection URL is provided
                            let finalSegmentURL: URL
                            if let collectionURL = collectionURL {
                                do {
                                    finalSegmentURL = try storage.saveSegment(
                                        segmentURL: segment,
                                        sourceFile: file.url,
                                        collectionURL: collectionURL,
                                        label: label,
                                        segmentIndex: index
                                    )
                                } catch {
                                    print("Warning: Could not save segment to persistent storage: \(error)")
                                    finalSegmentURL = segment
                                }
                            } else {
                                finalSegmentURL = segment
                            }
                            
                            samples.append(TrainingSample(
                                audioURL: finalSegmentURL,
                                label: label,
                                features: features,
                                sourceFile: file.url
                            ))
                        }
                    }
                    
                    processedFiles += 1
                    await MainActor.run {
                        progress = Double(processedFiles) / Double(totalFiles)
                    }
                } catch {
                    print("Error processing \(file.url.lastPathComponent): \(error)")
                }
            }
        }
        
        await MainActor.run {
            trainingData = samples
            isProcessing = false
            currentStatus = "Ready: \(samples.count) training samples"
            progress = 1.0
        }
    }
    
    /// Saves analysis results to persistent storage
    func saveAnalysis(
        collectionURL: URL,
        audioFiles: [AudioAnalyzer.AudioFile],
        organizedStyles: [String: [AudioAnalyzer.AudioFile]]
    ) async throws {
        // Access trainingData on main actor
        let samples = await MainActor.run { trainingData }
        try storage.saveAnalysis(
            collectionURL: collectionURL,
            audioFiles: audioFiles,
            organizedStyles: organizedStyles,
            trainingSamples: samples
        )
    }
    
    /// Loads previously saved analysis results
    func loadAnalysis(for collectionURL: URL) throws -> AnalysisStorage.AnalysisResult? {
        return try storage.loadAnalysis(for: collectionURL)
    }
    
    /// Checks if analysis exists for a collection
    func hasAnalysis(for collectionURL: URL) -> Bool {
        return storage.hasAnalysis(for: collectionURL)
    }
    
    /// Gets unique labels from training data
    var uniqueLabels: [String] {
        Array(Set(trainingData.map { $0.label })).sorted()
    }
    
    /// Gets samples for a specific label
    func samples(for label: String) -> [TrainingSample] {
        trainingData.filter { $0.label == label }
    }
}

