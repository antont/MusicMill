import Foundation
import CreateML
import CoreML

/// Trains MLSoundClassifier models on the music collection
class ModelTrainer {
    
    /// Trains a sound classifier model from training samples
    func trainModel(
        from samples: [TrainingDataManager.TrainingSample],
        parameters: TrainingParameters = TrainingParameters()
    ) async throws -> MLSoundClassifier {
        
        // Organize samples by label
        var labeledData: [String: [URL]] = [:]
        for sample in samples {
            if labeledData[sample.label] == nil {
                labeledData[sample.label] = []
            }
            labeledData[sample.label]?.append(sample.audioURL)
        }
        
        // Create training data structure
        var trainingData: [String: [URL]] = [:]
        var validationData: [String: [URL]] = [:]
        
        // Split into training and validation (80/20)
        for (label, urls) in labeledData {
            let shuffled = urls.shuffled()
            let splitIndex = Int(Double(shuffled.count) * 0.8)
            trainingData[label] = Array(shuffled.prefix(splitIndex))
            validationData[label] = Array(shuffled.suffix(shuffled.count - splitIndex))
        }
        
        // Create temporary directory structure for training
        // MLSoundClassifier expects a directory where subdirectories are class labels
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicMillTraining-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Create labeled directories and copy files
        for (label, urls) in trainingData {
            let labelDir = tempDir.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: labelDir, withIntermediateDirectories: true)
            
            for url in urls {
                let destURL = labelDir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: destURL)
            }
        }
        
        // Train using directory structure
        // MLSoundClassifier initializer expects a DataSource, not a URL directly
        let classifier = try await MLSoundClassifier(trainingData: .labeledDirectories(at: tempDir))
        
        // Clean up temp directory after training (optional)
        // try? FileManager.default.removeItem(at: tempDir)
        
        return classifier
    }
    
    struct TrainingParameters {
        var maxIterations: Int = 100
        
        init() {}
    }
}
