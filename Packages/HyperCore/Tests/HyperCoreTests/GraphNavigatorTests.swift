import Foundation
import Testing
@testable import HyperCore

struct GraphNavigatorTests {
    let a0 = "a1b2c3d4e5f60001", a1 = "a1b2c3d4e5f60002", a2 = "a1b2c3d4e5f60003"
    let b0 = "b7e8f9a0b1c20001", b1 = "b7e8f9a0b1c20002", b2 = "b7e8f9a0b1c20003"
    let trackA = "/fixtures/music/Track A.mp3"

    func navigator() throws -> GraphNavigator {
        GraphNavigator(graph: try PhraseGraph.load(from: fixture("graph_v2.json")))
    }

    @Test func lookupAndTrackOrdering() throws {
        let nav = try navigator()
        #expect(nav.phrase(id: b1)?.trackIndex == 1)
        #expect(nav.phrases(inTrack: trackA).map(\.id) == [a0, a1, a2])
    }

    @Test func phraseAtSongTimeUsesBoundaries() throws {
        let nav = try navigator()
        let p1 = try #require(nav.phrase(id: a1))
        let start = try #require(p1.startTime)
        #expect(nav.phrase(atSongTime: start, inTrack: trackA)?.id == a1)
        #expect(nav.phrase(atSongTime: start - 0.001, inTrack: trackA)?.id == a0)
        #expect(nav.phrase(atSongTime: -5, inTrack: trackA)?.id == a0)
        #expect(nav.phrase(atSongTime: 10_000, inTrack: trackA)?.id == a2)
        #expect(nav.phrase(atSongTime: 1, inTrack: "/nope") == nil)
    }

    @Test func branchesExcludeSameTrackAndSortByAdjustedScore() throws {
        let nav = try navigator()
        let plain = nav.branches(from: a1, limit: 10)
        #expect(plain.map(\.to.id) == [b2, b1, b0])
        #expect(plain.allSatisfy { $0.to.sourceTrack != trackA })
        #expect(plain.first?.id == "\(a1)->\(b2)")
        #expect(plain.first?.score == 0.9)

        let reversed = nav.branches(from: a1, limit: 10, adjust: { l, _ in 1 - l.weight })
        #expect(reversed.map(\.to.id) == [b0, b1, b2])
        #expect(nav.branches(from: a1, limit: 2).count == 2)
    }

    @Test func nextInSequenceFollowsTrackIndex() throws {
        let nav = try navigator()
        #expect(nav.nextInSequence(after: a0)?.id == a1)
        #expect(nav.nextInSequence(after: a1)?.id == a2)
        #expect(nav.nextInSequence(after: a2) == nil)
    }

    @Test func energyNeighboursFilterDirection() throws {
        let nav = try navigator()
        // a1 energy 0.55; cross-track targets: b0 0.3, b1 0.55 (equal, excluded), b2 0.8
        #expect(nav.energyNeighbours(of: a1, higher: true, limit: 5).map(\.id) == [b2])
        #expect(nav.energyNeighbours(of: a1, higher: false, limit: 5).map(\.id) == [b0])
        // a0 energy 0.3; higher targets: b1 0.55 closer than b2 0.8
        #expect(nav.energyNeighbours(of: a0, higher: true, limit: 5).map(\.id) == [b1, b2])
        #expect(nav.energyNeighbours(of: a0, higher: true, limit: 1).map(\.id) == [b1])
    }

    @Test func unknownIdsReturnEmpty() throws {
        let nav = try navigator()
        #expect(nav.phrase(id: "nope") == nil)
        #expect(nav.phrases(inTrack: "/nope").isEmpty)
        #expect(nav.nextInSequence(after: "nope") == nil)
        #expect(nav.branches(from: "nope", limit: 5).isEmpty)
        #expect(nav.energyNeighbours(of: "nope", higher: true, limit: 5).isEmpty)
    }

    @Test func randomStartPicksTrackIndexZero() throws {
        let nav = try navigator()
        var rng = SeededGenerator(seed: 42)
        var seen = Set<String>()
        for _ in 0..<50 {
            let p = try #require(nav.randomStart(using: &rng))
            #expect(p.trackIndex == 0)
            seen.insert(p.id)
        }
        #expect(seen == [a0, b0])
        #expect(try #require(nav.randomStart()).trackIndex == 0)
        #expect(GraphNavigator(graph: PhraseGraph(version: "2.0", createdAt: Date(), collectionPath: "", nodes: [])).randomStart() == nil)
    }
}
