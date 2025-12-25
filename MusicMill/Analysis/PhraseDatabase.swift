import Foundation

/// HyperMusic Phrase Graph - navigable DAG of musical phrases
/// Enables DJ-style transitions across an entire music collection

// MARK: - Transition Types

enum TransitionType: String, Codable {
    case crossfade      // Simple volume crossfade
    case eqSwap         // DJ-style EQ mixing (bass swap)
    case cut            // Hard cut on beat
    case filter         // Filter sweep transition
}

// MARK: - Phrase Link

/// Weighted edge connecting two phrases
struct PhraseLink: Codable, Identifiable {
    var id: String { targetId }
    
    let targetId: String              // UUID of target phrase
    let weight: Double                // 0-1 compatibility score
    let isOriginalSequence: Bool      // True if next phrase in same song
    let suggestedTransition: TransitionType
    
    // Compatibility breakdown for UI display
    let tempoScore: Double
    let keyScore: Double
    let energyScore: Double
    let spectralScore: Double
}

// MARK: - Waveform Data

/// RGB waveform data for DJ-style display
/// Blue = bass, Green = mids, Orange/Red = highs
struct WaveformData: Codable {
    let low: [Float]    // Bass amplitude (0-1) per point
    let mid: [Float]    // Mid amplitude (0-1) per point
    let high: [Float]   // High amplitude (0-1) per point
    let points: Int     // Number of data points (typically 150)
}

// MARK: - Phrase Node

/// A musical phrase with its features and outgoing links
struct PhraseNode: Codable, Identifiable {
    let id: String                    // UUID
    let sourceTrack: String           // Original song path
    let sourceTrackName: String       // Display name
    let trackIndex: Int               // Position in original song (0, 1, 2...)
    let audioFile: String             // Path to extracted audio segment
    
    // Musical features
    let tempo: Double
    let key: String?
    let energy: Double                // 0-1
    let spectralCentroid: Double
    let segmentType: String           // intro, verse, chorus, drop, outro
    let duration: TimeInterval
    let startTime: TimeInterval?      // Start time in original track (seconds)
    let endTime: TimeInterval?        // End time in original track (seconds)
    
    // Beat grid (relative to segment start)
    let beats: [TimeInterval]
    let downbeats: [TimeInterval]
    
    // RGB waveform for display
    let waveform: WaveformData?
    
    // Graph edges - outgoing connections
    var links: [PhraseLink]
    
    // Computed properties
    var displayName: String {
        let trackName = URL(fileURLWithPath: sourceTrackName).deletingPathExtension().lastPathComponent
        return "\(trackName) [\(segmentType) \(trackIndex + 1)]"
    }
    
    var bpm: Int {
        Int(tempo.rounded())
    }
    
    /// Sequence number for display (1-indexed)
    var sequenceNumber: Int {
        trackIndex + 1
    }
    
    /// Format time as mm:ss
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    /// Formatted time range (e.g., "1:30-2:05")
    var timeRange: String {
        if let start = startTime, let end = endTime {
            return "\(formatTime(start))-\(formatTime(end))"
        } else {
            // Fallback: calculate from index and duration (approximate)
            return "~\(formatTime(duration))"
        }
    }
    
    /// Formatted start time (e.g., "1:30")
    var formattedStartTime: String {
        if let start = startTime {
            return formatTime(start)
        }
        return "--:--"
    }
    
    /// Formatted end time (e.g., "2:05")
    var formattedEndTime: String {
        if let end = endTime {
            return formatTime(end)
        }
        return "--:--"
    }
    
    var energyPercent: Int {
        Int(energy * 100)
    }
}

// MARK: - Phrase Graph

/// The complete phrase graph with all nodes and metadata
struct PhraseGraph: Codable {
    let version: String
    let createdAt: Date
    let collectionPath: String
    var nodes: [PhraseNode]
    
    // Quick lookup
    var nodeById: [String: PhraseNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }
    
    var nodesByTrack: [String: [PhraseNode]] {
        Dictionary(grouping: nodes, by: { $0.sourceTrack })
    }
}

// MARK: - Phrase Database

/// Manages the phrase graph persistence and queries
class PhraseDatabase {
    
    // MARK: - Properties
    
    private var graph: PhraseGraph?
    private var nodeIndex: [String: PhraseNode] = [:]
    
    private let storageURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MusicMill/PhraseGraph")
    }()
    
    private var graphFileURL: URL {
        storageURL.appendingPathComponent("phrase_graph.json")
    }
    
    // MARK: - Initialization
    
    init() {
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }
    
    // MARK: - Persistence
    
    /// Load the phrase graph from disk
    func load() throws {
        guard FileManager.default.fileExists(atPath: graphFileURL.path) else {
            throw PhraseDBError.noGraphFile
        }
        
        let data = try Data(contentsOf: graphFileURL)
        let decoder = JSONDecoder()
        
        // Use flexible date decoding that handles both ISO8601 with and without timezone
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            // Try ISO8601 with fractional seconds and timezone
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Try ISO8601 without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Try without timezone (local time)
            let localFormatter = DateFormatter()
            localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            if let date = localFormatter.date(from: dateString) {
                return date
            }
            
            localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let date = localFormatter.date(from: dateString) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        
        graph = try decoder.decode(PhraseGraph.self, from: data)
        
        // Build index
        nodeIndex = graph?.nodeById ?? [:]
        
        #if DEBUG
        print("[PhraseDatabase] Loaded \(nodeIndex.count) phrase nodes")
        #endif
    }
    
    /// Save the phrase graph to disk
    func save(_ graph: PhraseGraph) throws {
        self.graph = graph
        self.nodeIndex = graph.nodeById
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let data = try encoder.encode(graph)
        try data.write(to: graphFileURL)
        
        #if DEBUG
        print("[PhraseDatabase] Saved \(graph.nodes.count) phrase nodes")
        #endif
    }
    
    /// Check if graph exists
    var hasGraph: Bool {
        FileManager.default.fileExists(atPath: graphFileURL.path)
    }
    
    /// Get the loaded graph
    var currentGraph: PhraseGraph? {
        graph
    }
    
    // MARK: - Queries
    
    /// Get a phrase by ID
    func getPhrase(id: String) -> PhraseNode? {
        nodeIndex[id]
    }
    
    /// Get all phrases from a specific track (in order)
    func getPhrasesForTrack(_ trackPath: String) -> [PhraseNode] {
        guard let graph = graph else { return [] }
        return graph.nodes
            .filter { $0.sourceTrack == trackPath }
            .sorted { $0.trackIndex < $1.trackIndex }
    }
    
    /// Get outgoing links for a phrase, sorted by weight
    func getLinks(for phraseId: String) -> [PhraseLink] {
        guard let phrase = nodeIndex[phraseId] else { return [] }
        return phrase.links.sorted { $0.weight > $1.weight }
    }
    
    /// Get the next phrase in the original song sequence
    func getNextInSequence(for phraseId: String) -> PhraseNode? {
        guard let phrase = nodeIndex[phraseId] else { return nil }
        
        // Find link marked as original sequence
        if let sequenceLink = phrase.links.first(where: { $0.isOriginalSequence }),
           let nextPhrase = nodeIndex[sequenceLink.targetId] {
            return nextPhrase
        }
        
        // Fallback: find next by track index
        let trackPhrases = getPhrasesForTrack(phrase.sourceTrack)
        if let currentIndex = trackPhrases.firstIndex(where: { $0.id == phraseId }),
           currentIndex + 1 < trackPhrases.count {
            return trackPhrases[currentIndex + 1]
        }
        
        return nil
    }
    
    /// Get alternative next phrases (not the original sequence)
    func getAlternatives(for phraseId: String, limit: Int = 10) -> [PhraseNode] {
        guard let phrase = nodeIndex[phraseId] else { return [] }
        
        return phrase.links
            .filter { !$0.isOriginalSequence }
            .sorted { $0.weight > $1.weight }
            .prefix(limit)
            .compactMap { nodeIndex[$0.targetId] }
    }
    
    /// Query phrases by tempo range
    func getPhrases(tempoRange: ClosedRange<Double>) -> [PhraseNode] {
        guard let graph = graph else { return [] }
        return graph.nodes.filter { tempoRange.contains($0.tempo) }
    }
    
    /// Query phrases by key
    func getPhrases(key: String) -> [PhraseNode] {
        guard let graph = graph else { return [] }
        return graph.nodes.filter { $0.key == key }
    }
    
    /// Query phrases by energy range
    func getPhrases(energyRange: ClosedRange<Double>) -> [PhraseNode] {
        guard let graph = graph else { return [] }
        return graph.nodes.filter { energyRange.contains($0.energy) }
    }
    
    /// Query phrases by segment type
    func getPhrases(segmentType: String) -> [PhraseNode] {
        guard let graph = graph else { return [] }
        return graph.nodes.filter { $0.segmentType == segmentType }
    }
    
    /// Get all unique tracks in the graph
    func getAllTracks() -> [String] {
        guard let graph = graph else { return [] }
        return Array(Set(graph.nodes.map { $0.sourceTrack })).sorted()
    }
    
    /// Get all unique segment types
    func getAllSegmentTypes() -> [String] {
        guard let graph = graph else { return [] }
        return Array(Set(graph.nodes.map { $0.segmentType })).sorted()
    }
    
    /// Get phrases sorted by energy (for dimension navigation)
    func getPhrasesSortedByEnergy(around phraseId: String, higherEnergy: Bool, limit: Int = 5) -> [PhraseNode] {
        guard let phrase = nodeIndex[phraseId] else { return [] }
        
        let alternatives = phrase.links
            .filter { !$0.isOriginalSequence }
            .compactMap { link -> (PhraseNode, Double)? in
                guard let target = nodeIndex[link.targetId] else { return nil }
                return (target, link.weight)
            }
        
        if higherEnergy {
            return alternatives
                .filter { $0.0.energy > phrase.energy }
                .sorted { $0.0.energy < $1.0.energy } // Closest first
                .prefix(limit)
                .map { $0.0 }
        } else {
            return alternatives
                .filter { $0.0.energy < phrase.energy }
                .sorted { $0.0.energy > $1.0.energy } // Closest first
                .prefix(limit)
                .map { $0.0 }
        }
    }
    
    /// Get a random starting phrase (prefers intros)
    func getRandomStart() -> PhraseNode? {
        guard let graph = graph, !graph.nodes.isEmpty else { return nil }
        
        // Prefer intros
        let intros = graph.nodes.filter { $0.segmentType == "intro" }
        if !intros.isEmpty {
            return intros.randomElement()
        }
        
        // Otherwise any phrase
        return graph.nodes.randomElement()
    }
    
    // MARK: - Statistics
    
    var nodeCount: Int {
        graph?.nodes.count ?? 0
    }
    
    var linkCount: Int {
        graph?.nodes.reduce(0) { $0 + $1.links.count } ?? 0
    }
    
    var trackCount: Int {
        getAllTracks().count
    }
    
    // MARK: - Errors
    
    enum PhraseDBError: LocalizedError {
        case noGraphFile
        case invalidGraph
        case phraseNotFound(String)
        
        var errorDescription: String? {
            switch self {
            case .noGraphFile:
                return "No phrase graph file found. Run analysis first."
            case .invalidGraph:
                return "Invalid phrase graph format."
            case .phraseNotFound(let id):
                return "Phrase not found: \(id)"
            }
        }
    }
}

