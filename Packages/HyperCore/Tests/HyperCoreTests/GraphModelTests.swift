import Foundation
import Testing
@testable import HyperCore

@Suite struct GraphModelTests {
    @Test func loadsV2Graph() throws {
        let g = try PhraseGraph.load(from: fixture("graph_v2.json"))
        #expect(g.version == "2.0")
        #expect(g.nodes.count == 6)
        #expect(g.nodes[0].songTime(ofPhraseRelative: 1.0) == (g.nodes[0].startTime ?? 0) + 1.0)
        #expect(g.nodesByTrack.count == 2)
        #expect(g.nodes.allSatisfy { !$0.beats.isEmpty && !$0.downbeats.isEmpty })
        #expect(g.nodes[0].links.first?.suggestedTransition == .eqSwap)
        #expect(g.nodes[0].waveform?.points == 4)
    }

    @Test func rejectsV1GraphWithRebuildMessage() {
        #expect(throws: GraphError.unsupportedVersion(found: "1.1")) { try PhraseGraph.load(from: fixture("graph_v1.json")) }
        #expect(GraphError.unsupportedVersion(found: "1.1").localizedDescription.contains("build_phrase_graph.py"))
    }

    @Test func parsesPythonIsoDatesWithMicroseconds() throws {
        // graph_v2.json createdAt = "2025-12-25T23:08:27.476161+02:00"
        let g = try PhraseGraph.load(from: fixture("graph_v2.json"))
        #expect(abs(g.createdAt.timeIntervalSince1970 - 1766696907.476) < 0.01)
    }

    @Test func missingFileThrowsFileNotFound() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypercore-missing-\(UUID().uuidString).json")
        #expect(throws: GraphError.fileNotFound(url)) { try PhraseGraph.load(from: url) }
    }

    @Test func startFrameUsesStartTimeAtSampleRate() throws {
        let g = try PhraseGraph.load(from: fixture("graph_v2.json"))
        let node = g.nodes[1]
        #expect(node.startFrame(sampleRate: 48_000) == Int((node.startTime! * 48_000).rounded()))
    }
}
