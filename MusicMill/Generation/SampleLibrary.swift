import Foundation
import AVFoundation
import Combine

/// Catalogs and indexes segments with metadata for efficient matching and retrieval
class SampleLibrary: ObservableObject {
    
    struct Sample {
        let id: String
        let url: URL
        let buffer: AVAudioPCMBuffer?  // Lazy loaded
        let metadata: SampleMetadata
    }
    
    struct SampleMetadata {
        let style: String?
        let tempo: Double?
        let key: String?
        let energy: Double
        let spectralCentroid: Double
        let duration: TimeInterval
        let sourceTrack: String? // Original track identifier
        let segmentStart: TimeInterval // Start time in original track
        let segmentEnd: TimeInterval // End time in original track
        let isBeat: Bool
        let isPhrase: Bool
        let isLoop: Bool
    }
    
    @Published private(set) var isLoading = false
    @Published private(set) var loadingProgress: Double = 0.0
    @Published private(set) var loadingStatus: String = ""
    
    private var samples: [String: Sample] = [:]
    private var loadedBuffers: [String: AVAudioPCMBuffer] = [:] // Cache of loaded buffers
    private var styleIndex: [String: [String]] = [:] // style -> sample IDs
    private var tempoIndex: [Int: [String]] = [:] // rounded BPM -> sample IDs
    private var keyIndex: [String: [String]] = [:] // key -> sample IDs
    // Note: No FeatureExtractor here - all features come from pre-analyzed data
    
    /// Adds a sample to the library
    func addSample(_ sample: Sample) {
        samples[sample.id] = sample
        
        // Index by style
        if let style = sample.metadata.style {
            if styleIndex[style] == nil {
                styleIndex[style] = []
            }
            styleIndex[style]?.append(sample.id)
        }
        
        // Index by tempo (rounded to nearest 5 BPM)
        if let tempo = sample.metadata.tempo {
            let roundedTempo = Int(round(tempo / 5.0) * 5.0)
            if tempoIndex[roundedTempo] == nil {
                tempoIndex[roundedTempo] = []
            }
            tempoIndex[roundedTempo]?.append(sample.id)
        }
        
        // Index by key
        if let key = sample.metadata.key {
            if keyIndex[key] == nil {
                keyIndex[key] = []
            }
            keyIndex[key]?.append(sample.id)
        }
    }
    
    /// Finds samples matching criteria
    func findSamples(style: String? = nil, tempo: Double? = nil, key: String? = nil, energy: Double? = nil, limit: Int = 10) -> [Sample] {
        var candidateIDs: Set<String>?
        
        // Filter by style
        if let style = style, let styleSamples = styleIndex[style] {
            candidateIDs = Set(styleSamples)
        } else {
            candidateIDs = Set(samples.keys)
        }
        
        // Filter by tempo
        if let tempo = tempo {
            let roundedTempo = Int(round(tempo / 5.0) * 5.0)
            let tempoRange = (roundedTempo - 5)...(roundedTempo + 5)
            let tempoSamples = tempoRange.compactMap { tempoIndex[$0] }.flatMap { $0 }
            
            if let candidates = candidateIDs {
                candidateIDs = candidates.intersection(Set(tempoSamples))
            } else {
                candidateIDs = Set(tempoSamples)
            }
        }
        
        // Filter by key
        if let key = key, let keySamples = keyIndex[key] {
            if let candidates = candidateIDs {
                candidateIDs = candidates.intersection(Set(keySamples))
            } else {
                candidateIDs = Set(keySamples)
            }
        }
        
        // Get samples and sort by relevance
        guard let candidateIDs = candidateIDs else {
            return []
        }
        
        var matchedSamples = candidateIDs.compactMap { samples[$0] }
        
        // Sort by energy if specified
        if let energy = energy {
            matchedSamples.sort { abs($0.metadata.energy - energy) < abs($1.metadata.energy - energy) }
        }
        
        // Limit results
        return Array(matchedSamples.prefix(limit))
    }
    
    /// Gets a random sample matching criteria
    func getRandomSample(style: String? = nil, tempo: Double? = nil, key: String? = nil) -> Sample? {
        let matches = findSamples(style: style, tempo: tempo, key: key, limit: 100)
        return matches.randomElement()
    }
    
    /// Gets all samples for a style
    func getSamples(forStyle style: String) -> [Sample] {
        guard let sampleIDs = styleIndex[style] else {
            return []
        }
        return sampleIDs.compactMap { samples[$0] }
    }
    
    /// Gets all samples
    func getAllSamples() -> [Sample] {
        return Array(samples.values)
    }
    
    /// Removes a sample from the library
    func removeSample(id: String) {
        guard let sample = samples[id] else { return }
        
        samples.removeValue(forKey: id)
        
        // Remove from indices
        if let style = sample.metadata.style {
            styleIndex[style]?.removeAll { $0 == id }
        }
        
        if let tempo = sample.metadata.tempo {
            let roundedTempo = Int(round(tempo / 5.0) * 5.0)
            tempoIndex[roundedTempo]?.removeAll { $0 == id }
        }
        
        if let key = sample.metadata.key {
            keyIndex[key]?.removeAll { $0 == id }
        }
    }
    
    /// Clears all samples
    func clear() {
        samples.removeAll()
        styleIndex.removeAll()
        tempoIndex.removeAll()
        keyIndex.removeAll()
    }
    
    /// Gets statistics about the library
    func getStatistics() -> LibraryStatistics {
        let totalSamples = samples.count
        let styles = Set(samples.values.compactMap { $0.metadata.style })
        let avgTempo = samples.values.compactMap { $0.metadata.tempo }.reduce(0.0, +) / Double(totalSamples)
        let totalDuration = samples.values.reduce(0.0) { $0 + $1.metadata.duration }
        
        return LibraryStatistics(
            totalSamples: totalSamples,
            uniqueStyles: styles.count,
            averageTempo: avgTempo,
            totalDuration: totalDuration
        )
    }
    
    struct LibraryStatistics {
        let totalSamples: Int
        let uniqueStyles: Int
        let averageTempo: Double
        let totalDuration: TimeInterval
    }
    
    // MARK: - Loading from Analysis Storage
    
    /// Loads samples from a previously analyzed collection using PRE-ANALYZED data
    /// No feature extraction happens here - all features come from analysis.json
    func loadFromAnalysis(collectionURL: URL) async throws {
        let storage = AnalysisStorage()
        
        guard storage.hasAnalysis(for: collectionURL) else {
            throw LibraryError.noAnalysisFound
        }
        
        guard let analysis = try storage.loadAnalysis(for: collectionURL) else {
            throw LibraryError.analysisLoadFailed
        }
        
        await MainActor.run {
            isLoading = true
            loadingProgress = 0.0
            loadingStatus = "Loading pre-analyzed segments..."
        }
        
        // Get segments directory
        let segmentsDir = storage.segmentsDirectory(for: collectionURL)
        guard FileManager.default.fileExists(atPath: segmentsDir.path) else {
            await MainActor.run { isLoading = false }
            throw LibraryError.segmentsNotFound
        }
        
        // Build a lookup map from audio file paths to their pre-analyzed features
        var featuresLookup: [String: AnalysisStorage.AudioFeaturesInfo] = [:]
        for audioFile in analysis.audioFiles {
            if let features = audioFile.features {
                // Map by filename (without extension) for matching
                let filename = URL(fileURLWithPath: audioFile.path).deletingPathExtension().lastPathComponent
                featuresLookup[filename] = features
            }
        }
        
        // List all segment files
        let segmentFiles = try FileManager.default.contentsOfDirectory(
            at: segmentsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "m4a" }
        
        let totalSegments = segmentFiles.count
        var loadedCount = 0
        
        for segmentURL in segmentFiles {
            let filename = segmentURL.deletingPathExtension().lastPathComponent
            let parts = filename.components(separatedBy: "_")
            
            // Infer style from filename or organized styles
            var style: String? = nil
            if parts.count >= 2 {
                for i in (0..<parts.count).reversed() {
                    if parts[i].hasPrefix("seg") { continue }
                    style = parts[i]
                    break
                }
            }
            
            // Try to find pre-analyzed features for the source track
            let sourceTrack = parts.first ?? filename
            let preAnalyzedFeatures = featuresLookup[sourceTrack]
            
            // Use pre-analyzed data (NO feature extraction!)
            let metadata = SampleMetadata(
                style: style,
                tempo: preAnalyzedFeatures?.tempo,
                key: preAnalyzedFeatures?.key,
                energy: preAnalyzedFeatures?.energy ?? 0.5,
                spectralCentroid: preAnalyzedFeatures?.spectralCentroid ?? 1000.0,
                duration: preAnalyzedFeatures?.duration ?? 30.0,
                sourceTrack: sourceTrack,
                segmentStart: 0,
                segmentEnd: preAnalyzedFeatures?.duration ?? 30.0,
                isBeat: false,
                isPhrase: true,
                isLoop: false
            )
            
            let sample = Sample(
                id: UUID().uuidString,
                url: segmentURL,
                buffer: nil, // Load lazily when needed for playback
                metadata: metadata
            )
            
            addSample(sample)
            
            loadedCount += 1
            // Update progress less frequently
            if loadedCount % 50 == 0 || loadedCount == totalSegments {
                await MainActor.run {
                    loadingProgress = Double(loadedCount) / Double(totalSegments)
                    loadingStatus = "Cataloged \(loadedCount)/\(totalSegments) segments"
                }
            }
        }
        
        await MainActor.run {
            isLoading = false
            loadingStatus = "Ready: \(samples.count) samples loaded"
        }
    }
    
    /// Loads the audio buffer for a sample (if not already loaded)
    func loadBuffer(for sampleID: String) throws -> AVAudioPCMBuffer? {
        // Check cache first
        if let cached = loadedBuffers[sampleID] {
            return cached
        }
        
        guard let sample = samples[sampleID] else {
            return nil
        }
        
        // Load from file
        let file = try AVAudioFile(forReading: sample.url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw LibraryError.bufferCreationFailed
        }
        
        try file.read(into: buffer)
        
        // Cache buffer
        loadedBuffers[sampleID] = buffer
        
        return buffer
    }
    
    /// Preloads buffers for samples matching criteria
    func preloadBuffers(style: String? = nil, limit: Int = 20) async {
        let matchingSamples = findSamples(style: style, limit: limit)
        
        for sample in matchingSamples {
            do {
                _ = try loadBuffer(for: sample.id)
            } catch {
                print("Warning: Could not preload buffer for \(sample.id): \(error)")
            }
        }
    }
    
    /// Gets available styles in the library
    func getAvailableStyles() -> [String] {
        return Array(styleIndex.keys).sorted()
    }
    
    /// Loads samples from an array of segment URLs (for direct loading)
    /// This is a FAST catalog-only operation - NO feature extraction!
    /// All features should be pre-computed during analysis phase
    func loadFromSegments(_ segmentURLs: [URL], style: String? = nil) async throws {
        await MainActor.run {
            isLoading = true
            loadingProgress = 0.0
            loadingStatus = "Cataloging \(segmentURLs.count) segments..."
        }
        
        let total = segmentURLs.count
        
        // Fast cataloging only - just index files for playback
        // Features are NOT extracted here - they should come from pre-analyzed data
        for (index, url) in segmentURLs.enumerated() {
            let sampleID = UUID().uuidString
            let metadata = SampleMetadata(
                style: style ?? inferStyle(from: url),
                tempo: nil,  // Will be extracted lazily if needed
                key: nil,
                energy: 0.5,
                spectralCentroid: 1000.0,
                duration: 30.0,  // Default duration
                sourceTrack: url.deletingPathExtension().lastPathComponent,
                segmentStart: 0,
                segmentEnd: 30.0,
                isBeat: false,
                isPhrase: true,
                isLoop: false
            )
            
            let sample = Sample(
                id: sampleID,
                url: url,
                buffer: nil,
                metadata: metadata
            )
            
            addSample(sample)
            
            // Update progress less frequently to reduce UI overhead
            if index % 50 == 0 || index == total - 1 {
                await MainActor.run {
                    loadingProgress = Double(index + 1) / Double(total)
                    loadingStatus = "Cataloging \(index + 1)/\(total) segments..."
                }
            }
        }
        
        await MainActor.run {
            isLoading = false
            loadingStatus = "Ready: \(samples.count) samples cataloged"
        }
    }
    
    /// Infers style from URL path components
    private func inferStyle(from url: URL) -> String? {
        let pathComponents = url.pathComponents
        // Try to find album or artist name from path
        if let albumIndex = pathComponents.lastIndex(where: { $0.lowercased().contains("album") || pathComponents.count > 3 }) {
            // Use parent directory name as style hint
            let parentIndex = pathComponents.index(before: pathComponents.endIndex - 1)
            if parentIndex >= pathComponents.startIndex {
                return pathComponents[parentIndex]
            }
        }
        return nil
    }
    
    /// Clears the buffer cache to free memory
    func clearBufferCache() {
        loadedBuffers.removeAll()
    }
    
    enum LibraryError: LocalizedError {
        case noAnalysisFound
        case analysisLoadFailed
        case segmentsNotFound
        case bufferCreationFailed
        
        var errorDescription: String? {
            switch self {
            case .noAnalysisFound:
                return "No analysis found for this collection"
            case .analysisLoadFailed:
                return "Failed to load analysis data"
            case .segmentsNotFound:
                return "Segments directory not found"
            case .bufferCreationFailed:
                return "Failed to create audio buffer"
            }
        }
    }
}


