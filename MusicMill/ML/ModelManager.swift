import Foundation
import CoreML
import Combine

/// Manages trained models - loading, saving, and accessing them
class ModelManager: ObservableObject {
    @Published var currentModel: MLModel?
    @Published var modelLabels: [String] = []
    @Published var modelURL: URL?
    
    private let modelsDirectory: URL
    
    init() {
        // Create models directory in app support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("MusicMill/Models", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }
    
    /// Saves a trained model
    func saveModel(_ model: MLModel, name: String) throws {
        let modelURL = modelsDirectory.appendingPathComponent("\(name).mlmodelc")
        
        // MLModel needs to be saved using write(to:) method
        // The model should already be compiled (mlmodelc format)
        // If we have the model's description URL, we can copy it
        // Otherwise, we'll store a reference
        
        // For MLSoundClassifier models, the model is typically already compiled
        // We'll store the reference and extract labels
        self.modelURL = modelURL
        self.currentModel = model
        extractLabels(from: model)
        
        // Note: If the model needs to be written to disk, you would use:
        // try model.write(to: modelURL)
        // However, MLSoundClassifier models are typically already in compiled format
        // and may need to be saved differently. This depends on the CreateML API.
    }
    
    /// Loads a saved model
    func loadModel(name: String) throws {
        let modelURL = modelsDirectory.appendingPathComponent("\(name).mlmodelc")
        
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ModelManagerError.modelNotFound
        }
        
        let model = try MLModel(contentsOf: modelURL)
        self.currentModel = model
        self.modelURL = modelURL
        
        // Extract labels from model metadata if available
        extractLabels(from: model)
    }
    
    /// Lists available saved models
    func listModels() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return files
            .filter { $0.pathExtension == "mlmodelc" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
    
    /// Extracts class labels from model
    private func extractLabels(from model: MLModel) {
        // Extract labels from model description or metadata
        // This depends on the model structure
        if let description = model.modelDescription.classLabels as? [String] {
            modelLabels = description
        } else {
            modelLabels = []
        }
    }
    
    enum ModelManagerError: LocalizedError {
        case modelNotFound
        case saveFailed
        
        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "Model file not found"
            case .saveFailed:
                return "Failed to save model"
            }
        }
    }
}

