import Testing
import Foundation
@testable import HyperCore

@MainActor
struct RelationshipDatabaseTests {
    let url: URL
    let db: RelationshipDatabase

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relationships-\(UUID().uuidString).db")
        db = RelationshipDatabase(url: url)
        try db.open()
    }

    @Test func noEventsReturnsBaseWeight() throws {
        #expect(try db.adjustedWeight(baseWeight: 0.7, from: "a", to: "b") == 0.7)
    }

    @Test func manualRatingChangesWeight() throws {
        try db.logRating(from: "a", to: "b", rating: 1, source: .manual)
        #expect(try db.adjustedWeight(baseWeight: 0.5, from: "a", to: "b") > 0.5)
    }

    @Test func negativeRatingLowersWeight() throws {
        try db.logRating(from: "a", to: "b", rating: -1, source: .manual)
        #expect(try db.adjustedWeight(baseWeight: 0.5, from: "a", to: "b") < 0.5)
    }

    @Test func playsAloneLeaveWeightUnchanged() throws {
        for _ in 0..<5 { try db.logPlayed(from: "a", to: "b", source: .performance) }
        #expect(try db.adjustedWeight(baseWeight: 0.8, from: "a", to: "b") == 0.8)
        // One rating: confidence 0.1 from rated events only, so 0.8 * 0.95 + 1 * 0.05.
        try db.logRating(from: "a", to: "b", rating: 1)
        #expect(abs(try db.adjustedWeight(baseWeight: 0.8, from: "a", to: "b") - 0.81) < 1e-9)
    }

    @Test func playedEventsArePersistedAcrossReopen() throws {
        try db.logPlayed(from: "a", to: "b", source: .practice)
        db.close()
        let reopened = RelationshipDatabase(url: url)
        try reopened.open()
        let feedback = try reopened.getFeedback(from: "a", to: "b")
        #expect(feedback.totalCount == 1)
        #expect(feedback.practiceCount == 1)
    }

    @Test func sessionIdIsAttachedToLoggedEvents() throws {
        let session = try db.startSession(type: .performance)
        #expect(db.currentSession?.id == session.id)
        try db.logPlayed(from: "a", to: "b", source: .performance)
        try db.endSession()
        #expect(db.currentSession == nil)
        #expect(try db.getFeedback(from: "a", to: "b").performanceCount == 1)
    }
}
