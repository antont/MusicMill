import Foundation

/// Parses Rekordbox collection metadata (cue points, play history, play counts, etc.)
class RekordboxParser {
    
    struct RekordboxTrack {
        let trackID: String
        let title: String
        let artist: String
        let filePath: String
        let bpm: Double?
        let key: String?
        let cuePoints: [CuePoint]
        let playCount: Int
        let lastPlayed: Date?
        let rating: Int? // 0-5 stars
        let genre: String?
        let label: String?
    }
    
    struct CuePoint {
        let number: Int // Cue point number (1-8 typically)
        let time: TimeInterval // Time in seconds
        let name: String?
        let type: CuePointType
    }
    
    enum CuePointType {
        case cue
        case loop
        case hotCue
        case memory
    }
    
    struct RekordboxCollection {
        let tracks: [RekordboxTrack]
        let playlists: [Playlist]
    }
    
    struct Playlist {
        let name: String
        let trackIDs: [String]
    }
    
    /// Parses Rekordbox collection from database file
    /// Rekordbox stores data in SQLite database, typically at:
    /// ~/Library/Pioneer/rekordbox/rekordbox.db (or similar location)
    func parseCollection(from databaseURL: URL) throws -> RekordboxCollection {
        // Rekordbox uses SQLite database
        // This is a simplified parser - production would need full SQLite integration
        
        // For now, return empty collection
        // In production, this would:
        // 1. Open SQLite database
        // 2. Query tracks table
        // 3. Query cue points table
        // 4. Query play history table
        // 5. Build RekordboxCollection structure
        
        return RekordboxCollection(tracks: [], playlists: [])
    }
    
    /// Parses Rekordbox collection from XML export
    /// Rekordbox can export collection as XML
    func parseCollectionFromXML(_ xmlURL: URL) throws -> RekordboxCollection {
        let xmlData = try Data(contentsOf: xmlURL)
        let parser = XMLParser(data: xmlData)
        let delegate = RekordboxXMLParserDelegate()
        parser.delegate = delegate
        
        if !parser.parse() {
            throw RekordboxParserError.parseFailed
        }
        
        return delegate.collection
    }
    
    /// Finds Rekordbox database in default locations
    func findRekordboxDatabase() -> URL? {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        
        // Common Rekordbox database locations
        let possiblePaths = [
            homeDirectory.appendingPathComponent("Library/Pioneer/rekordbox/rekordbox.db"),
            homeDirectory.appendingPathComponent("Library/Pioneer/rekordbox/master.db"),
            homeDirectory.appendingPathComponent("Documents/Pioneer/rekordbox/rekordbox.db"),
        ]
        
        for path in possiblePaths {
            if fileManager.fileExists(atPath: path.path) {
                return path
            }
        }
        
        return nil
    }
    
    /// Extracts cue points for a specific track
    func extractCuePoints(for trackID: String, from collection: RekordboxCollection) -> [CuePoint] {
        guard let track = collection.tracks.first(where: { $0.trackID == trackID }) else {
            return []
        }
        return track.cuePoints
    }
    
    /// Gets play history for a track
    func getPlayHistory(for trackID: String, from collection: RekordboxCollection) -> (playCount: Int, lastPlayed: Date?) {
        guard let track = collection.tracks.first(where: { $0.trackID == trackID }) else {
            return (0, nil)
        }
        return (track.playCount, track.lastPlayed)
    }
    
    /// Gets tracks sorted by play count (most played first)
    func getPopularTracks(from collection: RekordboxCollection, limit: Int = 100) -> [RekordboxTrack] {
        return Array(collection.tracks.sorted { $0.playCount > $1.playCount }.prefix(limit))
    }
    
    /// Gets tracks by genre
    func getTracks(byGenre genre: String, from collection: RekordboxCollection) -> [RekordboxTrack] {
        return collection.tracks.filter { $0.genre?.lowercased() == genre.lowercased() }
    }
    
    enum RekordboxParserError: LocalizedError {
        case databaseNotFound
        case parseFailed
        case invalidFormat
        
        var errorDescription: String? {
            switch self {
            case .databaseNotFound:
                return "Rekordbox database not found"
            case .parseFailed:
                return "Failed to parse Rekordbox collection"
            case .invalidFormat:
                return "Invalid Rekordbox collection format"
            }
        }
    }
}

/// XML Parser delegate for Rekordbox XML format
private class RekordboxXMLParserDelegate: NSObject, XMLParserDelegate {
    var collection = RekordboxParser.RekordboxCollection(tracks: [], playlists: [])
    private var currentTrack: RekordboxParser.RekordboxTrack?
    private var currentElement: String?
    private var tracks: [RekordboxParser.RekordboxTrack] = []
    private var playlists: [RekordboxParser.Playlist] = []
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        
        if elementName == "TRACK" {
            currentTrack = RekordboxParser.RekordboxTrack(
                trackID: attributeDict["TrackID"] ?? "",
                title: "",
                artist: "",
                filePath: "",
                bpm: nil,
                key: nil,
                cuePoints: [],
                playCount: 0,
                lastPlayed: nil,
                rating: nil,
                genre: nil,
                label: nil
            )
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Parse track data from XML
        // This is simplified - production would need full XML structure understanding
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "TRACK", let track = currentTrack {
            tracks.append(track)
            currentTrack = nil
        }
        currentElement = nil
    }
    
    func parserDidEndDocument(_ parser: XMLParser) {
        collection = RekordboxParser.RekordboxCollection(tracks: tracks, playlists: playlists)
    }
}

