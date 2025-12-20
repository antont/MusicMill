import SwiftUI
import AppKit
import CreateML
import UniformTypeIdentifiers

struct TrainingView: View {
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var trainingDataManager: TrainingDataManager
    
    @State private var selectedDirectory: URL?
    @State private var isSelectingDirectory = false
    @State private var isTraining = false
    @State private var trainingProgress: Double = 0.0
    @State private var trainingStatus: String = ""
    @State private var modelName: String = "MyModel"
    
    private let analyzer = AudioAnalyzer()
    private let featureExtractor = FeatureExtractor()
    private let trainer = ModelTrainer()
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Model Training")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top)
            
            // Directory selection
            VStack(alignment: .leading, spacing: 12) {
                Text("Music Collection Directory")
                    .font(.headline)
                
                HStack {
                    Text(selectedDirectory?.path ?? "No directory selected")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Button("Select Directory") {
                        isSelectingDirectory = true
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            // Analysis section
            if let directory = selectedDirectory {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Analysis")
                        .font(.headline)
                    
                    if trainingDataManager.isProcessing {
                        ProgressView(value: trainingDataManager.progress) {
                            Text(trainingDataManager.currentStatus)
                        }
                    } else {
                        Button("Analyze Collection") {
                            Task {
                                await analyzeCollection(directory: directory)
                            }
                        }
                        .disabled(trainingDataManager.isProcessing)
                    }
                    
                    if !trainingDataManager.trainingData.isEmpty {
                        Text("Found \(trainingDataManager.trainingData.count) training samples")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("Styles: \(trainingDataManager.uniqueLabels.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Divider()
            
            // Training section
            VStack(alignment: .leading, spacing: 12) {
                Text("Model Training")
                    .font(.headline)
                
                HStack {
                    TextField("Model Name", text: $modelName)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Train Model") {
                        Task {
                            await trainModel()
                        }
                    }
                    .disabled(trainingDataManager.trainingData.isEmpty || isTraining)
                }
                
                if isTraining {
                    ProgressView(value: trainingProgress) {
                        Text(trainingStatus)
                    }
                }
            }
            
            Divider()
            
            // Model management
            VStack(alignment: .leading, spacing: 12) {
                Text("Saved Models")
                    .font(.headline)
                
                let savedModels = modelManager.listModels()
                if savedModels.isEmpty {
                    Text("No saved models")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(savedModels, id: \.self) { modelName in
                        HStack {
                            Text(modelName)
                            Spacer()
                            Button("Load") {
                                try? modelManager.loadModel(name: modelName)
                            }
                        }
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: 800)
        .fileImporter(
            isPresented: $isSelectingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                selectedDirectory = urls.first
            case .failure:
                break
            }
        }
    }
    
    private func analyzeCollection(directory: URL) async {
        do {
            // Scan directory
            let audioFiles = try await analyzer.scanDirectory(at: directory)
            
            // Organize by directory structure
            let organized = trainingDataManager.organizeByDirectoryStructure(
                audioFiles: audioFiles,
                baseURL: directory
            )
            
            // Prepare training samples
            await trainingDataManager.prepareTrainingSamples(
                from: organized,
                analyzer: analyzer,
                featureExtractor: featureExtractor
            )
        } catch {
            print("Error analyzing collection: \(error)")
        }
    }
    
    private func trainModel() async {
        isTraining = true
        trainingStatus = "Training model..."
        trainingProgress = 0.0
        
        do {
            let classifier = try await trainer.trainModel(
                from: trainingDataManager.trainingData
            )
            
            // Convert MLSoundClassifier to MLModel and save
            trainingStatus = "Saving model..."
            trainingProgress = 0.9
            
            // MLSoundClassifier provides access to the underlying MLModel
            // The exact property name may vary - common options: .model, .coreMLModel, etc.
            // If compilation fails here, check the actual MLSoundClassifier API documentation
            let mlModel = classifier.model
            try modelManager.saveModel(mlModel, name: modelName)
            
            trainingStatus = "Model trained successfully!"
            trainingProgress = 1.0
            
            isTraining = false
        } catch {
            trainingStatus = "Error: \(error.localizedDescription)"
            isTraining = false
        }
    }
}

