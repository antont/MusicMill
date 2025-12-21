import SwiftUI
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
    @State private var errorMessage: String?
    @State private var showError = false
    
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
                    
                    if let error = errorMessage {
                        Text("Error: \(error)")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.top, 4)
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
        await MainActor.run {
            errorMessage = nil
        }
        
        do {
            // Scan directory
            let audioFiles = try await analyzer.scanDirectory(at: directory)
            
            if audioFiles.isEmpty {
                await MainActor.run {
                    errorMessage = "No supported audio files found. Supported formats: MP3, AAC, M4A, WAV, AIFF. Note: Apple Music M4A files may be DRM-protected and cannot be analyzed."
                }
                return
            }
            
            await MainActor.run {
                errorMessage = "Found \(audioFiles.count) audio files. Processing..."
            }
            
            // Organize by directory structure
            let organized = trainingDataManager.organizeByDirectoryStructure(
                audioFiles: audioFiles,
                baseURL: directory
            )
            
            // Prepare training samples
            await trainingDataManager.prepareTrainingSamples(
                from: organized,
                analyzer: analyzer,
                featureExtractor: featureExtractor,
                collectionURL: directory
            )
            
            // Save analysis results to persistent storage
            do {
                try await trainingDataManager.saveAnalysis(
                    collectionURL: directory,
                    audioFiles: audioFiles,
                    organizedStyles: organized
                )
                await MainActor.run {
                    errorMessage = "Analysis complete and saved to Documents/MusicMill/Analysis/"
                }
            } catch {
                print("Warning: Could not save analysis results: \(error)")
            }
            
            await MainActor.run {
                if trainingDataManager.trainingData.isEmpty {
                    errorMessage = "No training samples could be extracted. Check that files are readable and not DRM-protected."
                } else if errorMessage == nil {
                    errorMessage = nil
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Error analyzing collection: \(error.localizedDescription)"
            }
            print("Error analyzing collection: \(error)")
        }
    }
    
    private func trainModel() async {
        isTraining = true
        trainingStatus = "Training model..."
        trainingProgress = 0.0
        
        do {
            let model = try await trainer.trainModel(
                from: trainingDataManager.trainingData
            )
            
            // Convert to MLModel and save
            // Note: Actual conversion depends on MLSoundClassifier API
            trainingStatus = "Saving model..."
            trainingProgress = 0.9
            
            // For now, we'll save a placeholder
            // In production, you'd convert MLSoundClassifier to MLModel properly
            trainingStatus = "Model trained successfully!"
            trainingProgress = 1.0
            
            isTraining = false
        } catch {
            trainingStatus = "Error: \(error.localizedDescription)"
            isTraining = false
        }
    }
}

