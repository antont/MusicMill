import Foundation

/// HyperMusic Phrase Graph - navigable graph of musical phrases.
/// Produced by `scripts/build_phrase_graph.py` (`save_phrase_graph`); JSON keys match the Swift property names.

// MARK: - Transition Types

public enum TransitionType: String, Codable, Sendable {
    case crossfade      // Simple volume crossfade
    case eqSwap         // DJ-style EQ mixing (bass swap)
    case cut            // Hard cut on beat
    case filter         // Filter sweep transition
}

// MARK: - Phrase Link

/// Weighted edge connecting two phrases
public struct PhraseLink: Codable, Identifiable, Sendable {
    public var id: String { targetId }

    public let targetId: String              // ID of target phrase
    public let weight: Double                // 0-1 compatibility score
    public let isOriginalSequence: Bool      // True if next phrase in same song
    public let suggestedTransition: TransitionType

    // Compatibility breakdown for UI display
    public let tempoScore: Double
    public let keyScore: Double
    public let energyScore: Double
    public let spectralScore: Double
}

// MARK: - Waveform Data

/// RGB waveform data for DJ-style display
/// Blue = bass, Green = mids, Orange/Red = highs
public struct WaveformData: Codable, Sendable {
    public let low: [Float]    // Bass amplitude (0-1) per point
    public let mid: [Float]    // Mid amplitude (0-1) per point
    public let high: [Float]   // High amplitude (0-1) per point
    public let points: Int     // Number of data points (typically 150)

    public init(low: [Float], mid: [Float], high: [Float], points: Int) {
        self.low = low
        self.mid = mid
        self.high = high
        self.points = points
    }
}

// MARK: - Phrase Node

/// A musical phrase with its features and outgoing links
public struct PhraseNode: Codable, Identifiable, Sendable {
    public let id: String                    // Stable 16-char hex ID (graph v2)
    public let sourceTrack: String           // Original song path
    public let sourceTrackName: String       // Display name
    public let trackIndex: Int               // Position in original song (0, 1, 2...)
    public let audioFile: String             // Path to extracted audio segment

    // Musical features
    public let tempo: Double
    public let key: String?
    public let energy: Double                // 0-1
    public let spectralCentroid: Double
    public let segmentType: String           // intro, verse, chorus, drop, outro
    public let duration: TimeInterval
    public let startTime: TimeInterval?      // Start time in original track (seconds)
    public let endTime: TimeInterval?        // End time in original track (seconds)

    // Beat grid (phrase-relative seconds: song time = startTime + beat)
    public let beats: [TimeInterval]
    public let downbeats: [TimeInterval]

    // RGB waveform for display
    public let waveform: WaveformData?

    // Graph edges - outgoing connections
    public var links: [PhraseLink]

    public init(
        id: String,
        sourceTrack: String,
        sourceTrackName: String,
        trackIndex: Int,
        audioFile: String,
        tempo: Double,
        key: String?,
        energy: Double,
        spectralCentroid: Double,
        segmentType: String,
        duration: TimeInterval,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        beats: [TimeInterval],
        downbeats: [TimeInterval],
        waveform: WaveformData?,
        links: [PhraseLink]
    ) {
        self.id = id
        self.sourceTrack = sourceTrack
        self.sourceTrackName = sourceTrackName
        self.trackIndex = trackIndex
        self.audioFile = audioFile
        self.tempo = tempo
        self.key = key
        self.energy = energy
        self.spectralCentroid = spectralCentroid
        self.segmentType = segmentType
        self.duration = duration
        self.startTime = startTime
        self.endTime = endTime
        self.beats = beats
        self.downbeats = downbeats
        self.waveform = waveform
        self.links = links
    }

    // MARK: Time conversion

    /// Song-absolute frame where this phrase starts, at `sampleRate`.
    public func startFrame(sampleRate: Double) -> Int {
        Int(((startTime ?? 0) * sampleRate).rounded())
    }

    /// Converts a phrase-relative time (e.g. an entry of `beats`) to song-absolute seconds.
    public func songTime(ofPhraseRelative t: TimeInterval) -> TimeInterval {
        (startTime ?? 0) + t
    }

    // MARK: Display helpers

    public var displayName: String {
        let trackName = URL(fileURLWithPath: sourceTrackName).deletingPathExtension().lastPathComponent
        return "\(trackName) [\(segmentType) \(trackIndex + 1)]"
    }

    public var bpm: Int {
        Int(tempo.rounded())
    }

    /// Sequence number for display (1-indexed)
    public var sequenceNumber: Int {
        trackIndex + 1
    }

    /// Format time as mm:ss
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// Formatted time range (e.g., "1:30-2:05")
    public var timeRange: String {
        if let start = startTime, let end = endTime {
            return "\(formatTime(start))-\(formatTime(end))"
        } else {
            // Fallback: calculate from index and duration (approximate)
            return "~\(formatTime(duration))"
        }
    }

    /// Formatted start time (e.g., "1:30")
    public var formattedStartTime: String {
        if let start = startTime {
            return formatTime(start)
        }
        return "--:--"
    }

    /// Formatted end time (e.g., "2:05")
    public var formattedEndTime: String {
        if let end = endTime {
            return formatTime(end)
        }
        return "--:--"
    }

    public var energyPercent: Int {
        Int(energy * 100)
    }
}

// MARK: - Phrase Graph

/// The complete phrase graph with all nodes and metadata
public struct PhraseGraph: Codable, Sendable {
    public let version: String
    public let createdAt: Date
    public let collectionPath: String
    public var nodes: [PhraseNode]

    /// Major version of the graph JSON this build understands.
    public static let supportedMajorVersion = 2

    /// `~/Documents/MusicMill/PhraseGraph/phrase_graph.json`
    public static let defaultURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MusicMill/PhraseGraph/phrase_graph.json")

    // Quick lookup
    public var nodeById: [String: PhraseNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    public var nodesByTrack: [String: [PhraseNode]] {
        Dictionary(grouping: nodes, by: { $0.sourceTrack })
    }

    /// Loads a graph file, rejecting graphs whose major version is not `supportedMajorVersion`.
    public static func load(from url: URL) throws -> PhraseGraph {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GraphError.fileNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GraphError.decodingFailed(error.localizedDescription)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseISO8601(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Cannot decode date: \(string)")
            }
            return date
        }

        // Check the version before decoding the rest, so old schemas give a clear message.
        let version: String
        do {
            version = try decoder.decode(VersionProbe.self, from: data).version
        } catch {
            throw GraphError.decodingFailed(String(describing: error))
        }
        guard majorVersion(of: version) == supportedMajorVersion else {
            throw GraphError.unsupportedVersion(found: version)
        }

        do {
            return try decoder.decode(PhraseGraph.self, from: data)
        } catch {
            throw GraphError.decodingFailed(String(describing: error))
        }
    }

    private struct VersionProbe: Decodable {
        let version: String
    }

    private static func majorVersion(of version: String) -> Int? {
        version.split(separator: ".", maxSplits: 1).first.flatMap { Int($0) }
    }

    /// Parses ISO-8601 dates as written by Python's `datetime.isoformat()`,
    /// including microsecond fractions and missing time zones (treated as local time).
    static func parseISO8601(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        if let date = try? Date.ISO8601FormatStyle().parse(string) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}

// MARK: - Errors

public enum GraphError: Error, Equatable, LocalizedError {
    case fileNotFound(URL)
    case unsupportedVersion(found: String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Phrase graph not found at \(url.path). Build it with scripts/build_phrase_graph.py."
        case .unsupportedVersion(let found):
            return "Phrase graph version \(found) is not supported (need \(PhraseGraph.supportedMajorVersion).x). "
                + "Rebuild it with scripts/build_phrase_graph.py."
        case .decodingFailed(let detail):
            return "Could not read phrase graph: \(detail)"
        }
    }
}
