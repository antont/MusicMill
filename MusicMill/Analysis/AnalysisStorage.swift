import Foundation

/// Manages persistent storage of analysis results in Documents directory
class AnalysisStorage {
    
    private let baseDirectory: URL
    
    init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        baseDirectory = documentsURL.appendingPathComponent("MusicMill/Analysis", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Directory Analysis Storage
    
    /// Generates a unique identifier for a directory based on its path
    private func directoryID(for url: URL) -> String {
        // Create a hash from the directory path
        let path = url.path
        let hash = path.hashValue
        // Also include a sanitized version of the last component for readability
        let lastComponent = url.lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "\(lastComponent)_\(abs(hash))"
    }
    
    /// Gets the storage directory for a specific collection
    func storageDirectory(for collectionURL: URL) -> URL {
        let dirID = directoryID(for: collectionURL)
        return baseDirectory.appendingPathComponent(dirID, isDirectory: true)
    }
    
    /// Gets the segments directory for a specific collection
    func segmentsDirectory(for collectionURL: URL) -> URL {
        let storageDir = storageDirectory(for: collectionURL)
        return storageDir.appendingPathComponent("Segments", isDirectory: true)
    }
    
    // MARK: - Save Analysis Results
    
    struct AnalysisResult: Codable {
        let collectionPath: String
        let analyzedDate: Date
        let audioFiles: [AudioFileInfo]
        let organizedStyles: [String: [String]] // Style -> [file paths]
        let totalFiles: Int
        let totalSamples: Int
    }
    
    struct AudioFileInfo: Codable {
        let path: String
        let duration: TimeInterval
        let format: String
        let features: AudioFeaturesInfo?
    }
    
    struct AudioFeaturesInfo: Codable {
        let tempo: Double?
        let key: String?
        let energy: Double
        let spectralCentroid: Double
        let zeroCrossingRate: Double
        let rmsEnergy: Double
        let duration: TimeInterval
    }
    
    /// Saves analysis results for a collection
    func saveAnalysis(
        collectionURL: URL,
        audioFiles: [AudioAnalyzer.AudioFile],
        organizedStyles: [String: [AudioAnalyzer.AudioFile]],
        trainingSamples: [TrainingDataManager.TrainingSample]
    ) throws {
        let storageDir = storageDirectory(for: collectionURL)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        
        // Convert to serializable format
        let audioFileInfos = audioFiles.map { file -> AudioFileInfo in
            // Find features for this file from training samples
            let features = trainingSamples.first(where: { $0.sourceFile == file.url })?.features
            
            return AudioFileInfo(
                path: file.url.path,
                duration: file.duration,
                format: file.format.rawValue,
                features: features.map { AudioFeaturesInfo(
                    tempo: $0.tempo,
                    key: $0.key,
                    energy: $0.energy,
                    spectralCentroid: $0.spectralCentroid,
                    zeroCrossingRate: $0.zeroCrossingRate,
                    rmsEnergy: $0.rmsEnergy,
                    duration: $0.duration
                )}
            )
        }
        
        let organizedPaths = organizedStyles.mapValues { files in
            files.map { $0.url.path }
        }
        
        let result = AnalysisResult(
            collectionPath: collectionURL.path,
            analyzedDate: Date(),
            audioFiles: audioFileInfos,
            organizedStyles: organizedPaths,
            totalFiles: audioFiles.count,
            totalSamples: trainingSamples.count
        )
        
        // Save as JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        
        let jsonData = try encoder.encode(result)
        let jsonURL = storageDir.appendingPathComponent("analysis.json")
        
        // Ensure directory exists
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        
        // Write file
        try jsonData.write(to: jsonURL)
        
        // Verify file was written
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw NSError(domain: "AnalysisStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create analysis.json file"])
        }
        
        print("Saved analysis results to: \(jsonURL.path)")
        print("  File size: \(jsonData.count) bytes")
        print("  Verified: File exists at path")
    }
    
    /// Loads previously saved analysis results
    func loadAnalysis(for collectionURL: URL) throws -> AnalysisResult? {
        let storageDir = storageDirectory(for: collectionURL)
        let jsonURL = storageDir.appendingPathComponent("analysis.json")
        
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return nil
        }
        
        let jsonData = try Data(contentsOf: jsonURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        return try decoder.decode(AnalysisResult.self, from: jsonData)
    }
    
    /// Checks if a collection has been analyzed before
    func hasAnalysis(for collectionURL: URL) -> Bool {
        let storageDir = storageDirectory(for: collectionURL)
        let jsonURL = storageDir.appendingPathComponent("analysis.json")
        return FileManager.default.fileExists(atPath: jsonURL.path)
    }
    
    // MARK: - Segment Storage
    
    /// Saves a training segment to persistent storage
    func saveSegment(
        segmentURL: URL,
        sourceFile: URL,
        collectionURL: URL,
        label: String,
        segmentIndex: Int
    ) throws -> URL {
        let segmentsDir = segmentsDirectory(for: collectionURL)
        try FileManager.default.createDirectory(at: segmentsDir, withIntermediateDirectories: true)
        
        // Create a readable filename
        let sourceName = sourceFile.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let segmentName = "\(sourceName)_\(label)_seg\(segmentIndex).m4a"
        let destinationURL = segmentsDir.appendingPathComponent(segmentName)
        
        // Copy segment from temp to persistent location
        if FileManager.default.fileExists(atPath: segmentURL.path) {
            try FileManager.default.copyItem(at: segmentURL, to: destinationURL)
        }
        
        return destinationURL
    }
    
    /// Gets all saved segments for a collection
    func getSegments(for collectionURL: URL) -> [URL] {
        let segmentsDir = segmentsDirectory(for: collectionURL)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: segmentsDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return files.filter { $0.pathExtension == "m4a" }
    }
    
    // MARK: - Cleanup
    
    /// Deletes all analysis data for a collection
    func deleteAnalysis(for collectionURL: URL) throws {
        let storageDir = storageDirectory(for: collectionURL)
        if FileManager.default.fileExists(atPath: storageDir.path) {
            try FileManager.default.removeItem(at: storageDir)
        }
    }
    
    /// Gets the total size of stored analysis data
    func getStorageSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }
}


