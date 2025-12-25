import Foundation
import Combine
import SQLite3

/// SQLite database for storing user feedback on transitions and phrase tags.
/// Event-sourced design: all events are stored, statistics computed from history.
class RelationshipDatabase: ObservableObject {
    
    // MARK: - Types
    
    enum DatabaseError: Error, LocalizedError {
        case openFailed(String)
        case prepareFailed(String)
        case executeFailed(String)
        case bindFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "Failed to open database: \(msg)"
            case .prepareFailed(let msg): return "Failed to prepare statement: \(msg)"
            case .executeFailed(let msg): return "Failed to execute: \(msg)"
            case .bindFailed(let msg): return "Failed to bind parameter: \(msg)"
            }
        }
    }
    
    /// Transition technique types
    enum TransitionTechnique: String, Codable, CaseIterable {
        case bassSwap = "bass_swap"
        case filterSweep = "filter_sweep"
        case hardCut = "hard_cut"
        case crossfade = "crossfade"
        case eqBlend = "eq_blend"
        case echo = "echo"
        case custom = "custom"
        
        var displayName: String {
            switch self {
            case .bassSwap: return "Bass Swap"
            case .filterSweep: return "Filter Sweep"
            case .hardCut: return "Hard Cut"
            case .crossfade: return "Crossfade"
            case .eqBlend: return "EQ Blend"
            case .echo: return "Echo Out"
            case .custom: return "Custom"
            }
        }
    }
    
    /// Event sources
    enum EventSource: String, Codable {
        case practice = "practice"
        case performance = "performance"
        case manual = "manual"
        case `import` = "import"
    }
    
    /// Event actions
    enum EventAction: String, Codable {
        case played = "played"
        case rated = "rated"
        case skipped = "skipped"
        case aborted = "aborted"
    }
    
    /// Session types
    enum SessionType: String, Codable {
        case practice = "practice"
        case performance = "performance"
    }
    
    /// Rhythm styles
    enum RhythmStyle: String, Codable, CaseIterable {
        case even = "even"          // 4/4 straight
        case broken = "broken"      // breakbeat, IDM
        case swung = "swung"        // shuffle, swing
        case halftime = "halftime"
        
        var displayName: String {
            switch self {
            case .even: return "Even (4/4)"
            case .broken: return "Broken"
            case .swung: return "Swung"
            case .halftime: return "Half-time"
            }
        }
    }
    
    // MARK: - Data Models
    
    /// User-authored transition metadata
    struct Transition: Codable, Identifiable {
        var id: String { "\(fromPhraseId)→\(toPhraseId)" }
        let fromPhraseId: String
        let toPhraseId: String
        var notes: String?
        var technique: TransitionTechnique?
        var suggestedBars: Int?
        var qualityRating: Int?  // -2 to +2
        var tags: [String]
        var properties: [String: String]  // Extensible
        var createdAt: Date
        var updatedAt: Date
    }
    
    /// Single transition event
    struct TransitionEvent: Codable, Identifiable {
        let id: String
        let fromPhraseId: String
        let toPhraseId: String
        let timestamp: Date
        let source: EventSource
        let action: EventAction
        var rating: Int?  // -1, 0, +1
        var context: EventContext?
        var sessionId: String?
        var comment: String?
    }
    
    /// Context when a transition happened
    struct EventContext: Codable {
        var eqLow: Float?
        var eqMid: Float?
        var eqHigh: Float?
        var bars: Int?
        var tempoDiff: Double?
    }
    
    /// Practice/performance session
    struct Session: Codable, Identifiable {
        let id: String
        var startedAt: Date
        var endedAt: Date?
        var type: SessionType
        var notes: String?
    }
    
    /// Phrase-level user tags
    struct PhraseTags: Codable, Identifiable {
        var id: String { phraseId }
        let phraseId: String
        var energyOverride: Double?
        var rhythmStyle: RhythmStyle?
        var mood: [String]
        var customTags: [String]
        var notes: String?
    }
    
    /// Computed feedback statistics for a transition
    struct TransitionFeedback {
        let fromPhraseId: String
        let toPhraseId: String
        var practiceCount: Int = 0
        var performanceCount: Int = 0
        var totalCount: Int { practiceCount + performanceCount }
        var averageRating: Double = 0
        var lastUsed: Date?
        var confidence: Double { min(1.0, Double(totalCount) / 10.0) }
    }
    
    // MARK: - Properties
    
    private var db: OpaquePointer?
    private let dbPath: URL
    
    @Published private(set) var currentSession: Session?
    
    // MARK: - Initialization
    
    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let musicMillPath = documentsPath.appendingPathComponent("MusicMill")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: musicMillPath, withIntermediateDirectories: true)
        
        dbPath = musicMillPath.appendingPathComponent("relationships.db")
    }
    
    deinit {
        close()
    }
    
    // MARK: - Database Lifecycle
    
    /// Open database connection and create tables
    func open() throws {
        if db != nil { return }  // Already open
        
        let result = sqlite3_open(dbPath.path, &db)
        guard result == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.openFailed(errorMsg)
        }
        
        try createTables()
    }
    
    /// Close database connection
    func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }
    
    private func createTables() throws {
        let schema = """
        -- User-authored transition metadata
        CREATE TABLE IF NOT EXISTS transitions (
            from_phrase TEXT NOT NULL,
            to_phrase TEXT NOT NULL,
            notes TEXT,
            technique TEXT,
            suggested_bars INTEGER,
            quality_rating INTEGER,
            tags TEXT,
            properties TEXT,
            created_at REAL,
            updated_at REAL,
            PRIMARY KEY (from_phrase, to_phrase)
        );
        
        -- Event log (append-only)
        CREATE TABLE IF NOT EXISTS transition_events (
            id TEXT PRIMARY KEY,
            from_phrase TEXT NOT NULL,
            to_phrase TEXT NOT NULL,
            timestamp REAL NOT NULL,
            source TEXT NOT NULL,
            action TEXT NOT NULL,
            rating INTEGER,
            context TEXT,
            session_id TEXT,
            comment TEXT
        );
        
        -- Sessions for grouping events
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            started_at REAL,
            ended_at REAL,
            type TEXT,
            notes TEXT
        );
        
        -- Phrase-level user tags
        CREATE TABLE IF NOT EXISTS phrase_tags (
            phrase_id TEXT PRIMARY KEY,
            energy_override REAL,
            rhythm_style TEXT,
            mood TEXT,
            custom_tags TEXT,
            notes TEXT
        );
        
        -- Indexes for efficient queries
        CREATE INDEX IF NOT EXISTS idx_events_timestamp ON transition_events(timestamp);
        CREATE INDEX IF NOT EXISTS idx_events_session ON transition_events(session_id);
        CREATE INDEX IF NOT EXISTS idx_events_rating ON transition_events(rating) WHERE rating IS NOT NULL;
        CREATE INDEX IF NOT EXISTS idx_events_phrases ON transition_events(from_phrase, to_phrase);
        """
        
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, schema, nil, nil, &errorMsg)
        
        if result != SQLITE_OK {
            let error = errorMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMsg)
            throw DatabaseError.executeFailed(error)
        }
    }
    
    // MARK: - Transition CRUD
    
    /// Save or update a transition
    func saveTransition(_ transition: Transition) throws {
        guard let db = db else { throw DatabaseError.openFailed("Database not open") }
        
        let sql = """
        INSERT OR REPLACE INTO transitions 
        (from_phrase, to_phrase, notes, technique, suggested_bars, quality_rating, tags, properties, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        let tagsJson = try? JSONEncoder().encode(transition.tags)
        let propsJson = try? JSONEncoder().encode(transition.properties)
        
        sqlite3_bind_text(stmt, 1, transition.fromPhraseId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, transition.toPhraseId, -1, SQLITE_TRANSIENT)
        
        if let notes = transition.notes {
            sqlite3_bind_text(stmt, 3, notes, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        
        if let technique = transition.technique {
            sqlite3_bind_text(stmt, 4, technique.rawValue, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        
        if let bars = transition.suggestedBars {
            sqlite3_bind_int(stmt, 5, Int32(bars))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        
        if let rating = transition.qualityRating {
            sqlite3_bind_int(stmt, 6, Int32(rating))
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        
        if let json = tagsJson {
            sqlite3_bind_text(stmt, 7, String(data: json, encoding: .utf8), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        
        if let json = propsJson {
            sqlite3_bind_text(stmt, 8, String(data: json, encoding: .utf8), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        
        sqlite3_bind_double(stmt, 9, transition.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 10, transition.updatedAt.timeIntervalSince1970)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
    
    /// Get a transition by phrase IDs
    func getTransition(from: String, to: String) throws -> Transition? {
        guard let db = db else { throw DatabaseError.openFailed("Database not open") }
        
        let sql = "SELECT * FROM transitions WHERE from_phrase = ? AND to_phrase = ?"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, from, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, to, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        return parseTransitionRow(stmt)
    }
    
    private func parseTransitionRow(_ stmt: OpaquePointer?) -> Transition {
        let fromPhrase = String(cString: sqlite3_column_text(stmt, 0))
        let toPhrase = String(cString: sqlite3_column_text(stmt, 1))
        
        var notes: String?
        if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
            notes = String(cString: sqlite3_column_text(stmt, 2))
        }
        
        var technique: TransitionTechnique?
        if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
            let techStr = String(cString: sqlite3_column_text(stmt, 3))
            technique = TransitionTechnique(rawValue: techStr)
        }
        
        var suggestedBars: Int?
        if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
            suggestedBars = Int(sqlite3_column_int(stmt, 4))
        }
        
        var qualityRating: Int?
        if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
            qualityRating = Int(sqlite3_column_int(stmt, 5))
        }
        
        var tags: [String] = []
        if sqlite3_column_type(stmt, 6) != SQLITE_NULL {
            let tagsStr = String(cString: sqlite3_column_text(stmt, 6))
            if let data = tagsStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                tags = decoded
            }
        }
        
        var properties: [String: String] = [:]
        if sqlite3_column_type(stmt, 7) != SQLITE_NULL {
            let propsStr = String(cString: sqlite3_column_text(stmt, 7))
            if let data = propsStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                properties = decoded
            }
        }
        
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        
        return Transition(
            fromPhraseId: fromPhrase,
            toPhraseId: toPhrase,
            notes: notes,
            technique: technique,
            suggestedBars: suggestedBars,
            qualityRating: qualityRating,
            tags: tags,
            properties: properties,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
    
    // MARK: - Event Logging
    
    /// Log a transition event
    func logEvent(_ event: TransitionEvent) throws {
        guard let db = db else { throw DatabaseError.openFailed("Database not open") }
        
        // Ensure transition record exists
        if try getTransition(from: event.fromPhraseId, to: event.toPhraseId) == nil {
            let transition = Transition(
                fromPhraseId: event.fromPhraseId,
                toPhraseId: event.toPhraseId,
                notes: nil,
                technique: nil,
                suggestedBars: nil,
                qualityRating: nil,
                tags: [],
                properties: [:],
                createdAt: Date(),
                updatedAt: Date()
            )
            try saveTransition(transition)
        }
        
        let sql = """
        INSERT INTO transition_events 
        (id, from_phrase, to_phrase, timestamp, source, action, rating, context, session_id, comment)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, event.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, event.fromPhraseId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, event.toPhraseId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 5, event.source.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, event.action.rawValue, -1, SQLITE_TRANSIENT)
        
        if let rating = event.rating {
            sqlite3_bind_int(stmt, 7, Int32(rating))
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        
        if let context = event.context, let json = try? JSONEncoder().encode(context) {
            sqlite3_bind_text(stmt, 8, String(data: json, encoding: .utf8), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        
        if let sessionId = event.sessionId {
            sqlite3_bind_text(stmt, 9, sessionId, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        
        if let comment = event.comment {
            sqlite3_bind_text(stmt, 10, comment, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
    
    /// Convenience: Log a played transition
    func logPlayed(from: String, to: String, source: EventSource, context: EventContext? = nil) throws {
        let event = TransitionEvent(
            id: UUID().uuidString,
            fromPhraseId: from,
            toPhraseId: to,
            timestamp: Date(),
            source: source,
            action: .played,
            rating: nil,
            context: context,
            sessionId: currentSession?.id,
            comment: nil
        )
        try logEvent(event)
    }
    
    /// Convenience: Log a rating
    func logRating(from: String, to: String, rating: Int, source: EventSource = .manual) throws {
        let event = TransitionEvent(
            id: UUID().uuidString,
            fromPhraseId: from,
            toPhraseId: to,
            timestamp: Date(),
            source: source,
            action: .rated,
            rating: rating,
            context: nil,
            sessionId: currentSession?.id,
            comment: nil
        )
        try logEvent(event)
    }
    
    // MARK: - Sessions
    
    /// Start a new session
    func startSession(type: SessionType) throws -> Session {
        guard let db = db else { throw DatabaseError.openFailed("Database not open") }
        
        let session = Session(
            id: UUID().uuidString,
            startedAt: Date(),
            endedAt: nil,
            type: type,
            notes: nil
        )
        
        let sql = "INSERT INTO sessions (id, started_at, type) VALUES (?, ?, ?)"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, session.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, session.startedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, session.type.rawValue, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        
        DispatchQueue.main.async {
            self.currentSession = session
        }
        
        return session
    }
    
    /// End the current session
    func endSession(notes: String? = nil) throws {
        guard let db = db, let session = currentSession else { return }
        
        let sql = "UPDATE sessions SET ended_at = ?, notes = ? WHERE id = ?"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        
        if let notes = notes {
            sqlite3_bind_text(stmt, 2, notes, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        
        sqlite3_bind_text(stmt, 3, session.id, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
        
        DispatchQueue.main.async {
            self.currentSession = nil
        }
    }
    
    // MARK: - Computed Statistics
    
    /// Get feedback statistics for a transition
    func getFeedback(from: String, to: String) throws -> TransitionFeedback {
        guard let db = db else { throw DatabaseError.openFailed("Database not open") }
        
        var feedback = TransitionFeedback(fromPhraseId: from, toPhraseId: to)
        
        // Count by source
        let countSql = """
        SELECT source, COUNT(*) FROM transition_events 
        WHERE from_phrase = ? AND to_phrase = ? AND action = 'played'
        GROUP BY source
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, from, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, to, -1, SQLITE_TRANSIENT)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let source = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            
            if source == EventSource.practice.rawValue {
                feedback.practiceCount = count
            } else if source == EventSource.performance.rawValue {
                feedback.performanceCount = count
            }
        }
        
        // Average rating (weighted by recency)
        let ratingSql = """
        SELECT rating, timestamp FROM transition_events 
        WHERE from_phrase = ? AND to_phrase = ? AND rating IS NOT NULL
        ORDER BY timestamp DESC
        LIMIT 20
        """
        
        var ratingStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, ratingSql, -1, &ratingStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(ratingStmt) }
        
        sqlite3_bind_text(ratingStmt, 1, from, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(ratingStmt, 2, to, -1, SQLITE_TRANSIENT)
        
        var totalWeight = 0.0
        var weightedSum = 0.0
        var index = 0
        
        while sqlite3_step(ratingStmt) == SQLITE_ROW {
            let rating = Int(sqlite3_column_int(ratingStmt, 0))
            let weight = pow(0.9, Double(index))  // Recency decay
            
            weightedSum += Double(rating) * weight
            totalWeight += weight
            index += 1
        }
        
        if totalWeight > 0 {
            feedback.averageRating = weightedSum / totalWeight
        }
        
        // Last used
        let lastSql = """
        SELECT MAX(timestamp) FROM transition_events 
        WHERE from_phrase = ? AND to_phrase = ?
        """
        
        var lastStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, lastSql, -1, &lastStmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(lastStmt) }
        
        sqlite3_bind_text(lastStmt, 1, from, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(lastStmt, 2, to, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(lastStmt) == SQLITE_ROW && sqlite3_column_type(lastStmt, 0) != SQLITE_NULL {
            feedback.lastUsed = Date(timeIntervalSince1970: sqlite3_column_double(lastStmt, 0))
        }
        
        return feedback
    }
    
    /// Calculate adjusted weight incorporating user feedback
    func adjustedWeight(baseWeight: Double, from: String, to: String) throws -> Double {
        let feedback = try getFeedback(from: from, to: to)
        
        guard feedback.totalCount > 0 else { return baseWeight }
        
        // More events = higher confidence in user feedback
        let confidence = feedback.confidence
        
        // Convert rating (-1 to +1) to weight (0 to 1)
        let userWeight = (feedback.averageRating + 1.0) / 2.0
        
        // Blend: more events = trust user more (up to 50% influence)
        return baseWeight * (1 - confidence * 0.5) + userWeight * (confidence * 0.5)
    }
    
    // MARK: - Phrase Tags
    
    /// Save phrase tags
    func savePhraseTags(_ tags: PhraseTags) throws {
        guard let db = db else { throw DatabaseError.openFailed("Database not open") }
        
        let sql = """
        INSERT OR REPLACE INTO phrase_tags 
        (phrase_id, energy_override, rhythm_style, mood, custom_tags, notes)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, tags.phraseId, -1, SQLITE_TRANSIENT)
        
        if let energy = tags.energyOverride {
            sqlite3_bind_double(stmt, 2, energy)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        
        if let rhythm = tags.rhythmStyle {
            sqlite3_bind_text(stmt, 3, rhythm.rawValue, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        
        if let moodJson = try? JSONEncoder().encode(tags.mood) {
            sqlite3_bind_text(stmt, 4, String(data: moodJson, encoding: .utf8), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        
        if let tagsJson = try? JSONEncoder().encode(tags.customTags) {
            sqlite3_bind_text(stmt, 5, String(data: tagsJson, encoding: .utf8), -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        
        if let notes = tags.notes {
            sqlite3_bind_text(stmt, 6, notes, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
    
    /// Get phrase tags
    func getPhraseTags(phraseId: String) throws -> PhraseTags? {
        guard let db = db else { throw DatabaseError.openFailed("Database not open") }
        
        let sql = "SELECT * FROM phrase_tags WHERE phrase_id = ?"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, phraseId, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        var energyOverride: Double?
        if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
            energyOverride = sqlite3_column_double(stmt, 1)
        }
        
        var rhythmStyle: RhythmStyle?
        if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
            let styleStr = String(cString: sqlite3_column_text(stmt, 2))
            rhythmStyle = RhythmStyle(rawValue: styleStr)
        }
        
        var mood: [String] = []
        if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
            let moodStr = String(cString: sqlite3_column_text(stmt, 3))
            if let data = moodStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                mood = decoded
            }
        }
        
        var customTags: [String] = []
        if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
            let tagsStr = String(cString: sqlite3_column_text(stmt, 4))
            if let data = tagsStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                customTags = decoded
            }
        }
        
        var notes: String?
        if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
            notes = String(cString: sqlite3_column_text(stmt, 5))
        }
        
        return PhraseTags(
            phraseId: phraseId,
            energyOverride: energyOverride,
            rhythmStyle: rhythmStyle,
            mood: mood,
            customTags: customTags,
            notes: notes
        )
    }
    
    // MARK: - Queries
    
    /// Get all transitions with feedback stats, sorted by usage
    func getAllTransitionsWithFeedback() throws -> [(Transition, TransitionFeedback)] {
        guard let db = db else { throw DatabaseError.openFailed("Database not open") }
        
        let sql = "SELECT * FROM transitions ORDER BY updated_at DESC"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        var results: [(Transition, TransitionFeedback)] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let transition = parseTransitionRow(stmt)
            let feedback = try getFeedback(from: transition.fromPhraseId, to: transition.toPhraseId)
            results.append((transition, feedback))
        }
        
        return results
    }
    
    /// Get top-rated transitions for a source phrase
    func getTopTransitions(from phraseId: String, limit: Int = 10) throws -> [(Transition, TransitionFeedback)] {
        guard let db = db else { throw DatabaseError.openFailed("Database not open") }
        
        let sql = "SELECT * FROM transitions WHERE from_phrase = ?"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, phraseId, -1, SQLITE_TRANSIENT)
        
        var results: [(Transition, TransitionFeedback, Double)] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let transition = parseTransitionRow(stmt)
            let feedback = try getFeedback(from: transition.fromPhraseId, to: transition.toPhraseId)
            
            // Score based on rating and usage
            let score = feedback.averageRating * feedback.confidence + Double(feedback.totalCount) * 0.1
            results.append((transition, feedback, score))
        }
        
        // Sort by score and limit
        return results
            .sorted { $0.2 > $1.2 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }
}

// SQLite transient constant
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

