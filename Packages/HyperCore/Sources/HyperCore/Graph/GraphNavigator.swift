import Foundation

/// A cross-track transition candidate from one phrase to another.
public struct Branch: Sendable, Identifiable {
    public let from: PhraseNode
    public let to: PhraseNode
    public let link: PhraseLink
    public let score: Double

    public var id: String { "\(from.id)->\(to.id)" }

    public init(from: PhraseNode, to: PhraseNode, link: PhraseLink, score: Double) {
        self.from = from
        self.to = to
        self.link = link
        self.score = score
    }
}

/// Read-only queries over a `PhraseGraph`: time-to-phrase lookup and branch candidates.
/// All indexes are built once in `init`; the instance is immutable afterwards.
public final class GraphNavigator: Sendable {
    private let nodesById: [String: PhraseNode]
    private let tracks: [String: [PhraseNode]]
    private let startTimes: [String: [TimeInterval]]
    private let startPhrases: [PhraseNode]

    public init(graph: PhraseGraph) {
        var byId: [String: PhraseNode] = [:]
        byId.reserveCapacity(graph.nodes.count)
        for node in graph.nodes { byId[node.id] = node }

        var ordered: [String: [PhraseNode]] = [:]
        for (path, nodes) in Dictionary(grouping: graph.nodes, by: { $0.sourceTrack }) {
            ordered[path] = nodes.sorted { $0.trackIndex < $1.trackIndex }
        }

        nodesById = byId
        tracks = ordered
        startTimes = ordered.mapValues { $0.map { $0.startTime ?? 0 } }
        startPhrases = graph.nodes
            .filter { $0.trackIndex == 0 }
            .sorted { $0.id < $1.id }
    }

    public func phrase(id: String) -> PhraseNode? {
        nodesById[id]
    }

    /// Phrases of a track ordered by `trackIndex`; empty for an unknown track.
    public func phrases(inTrack path: String) -> [PhraseNode] {
        tracks[path] ?? []
    }

    /// The phrase containing `t`. Before the first phrase returns the first; after the last, the last.
    public func phrase(atSongTime t: TimeInterval, inTrack path: String) -> PhraseNode? {
        guard let list = tracks[path], let starts = startTimes[path], !list.isEmpty else { return nil }
        // Last index whose start time is <= t.
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= t { low = mid + 1 } else { high = mid }
        }
        return list[max(0, low - 1)]
    }

    /// The phrase following `id` in its original track, if any.
    public func nextInSequence(after id: String) -> PhraseNode? {
        guard let node = nodesById[id], let list = tracks[node.sourceTrack],
              let index = list.firstIndex(where: { $0.id == id }),
              index + 1 < list.count
        else { return nil }
        return list[index + 1]
    }

    /// Cross-track branches from `id`, best `adjust` score first. Ties keep link order.
    public func branches(
        from id: String,
        limit: Int,
        adjust: (PhraseLink, _ fromId: String) -> Double = { link, _ in link.weight }
    ) -> [Branch] {
        guard limit > 0, let source = nodesById[id] else { return [] }
        var result: [Branch] = []
        for link in source.links {
            guard let target = nodesById[link.targetId], target.sourceTrack != source.sourceTrack else { continue }
            result.append(Branch(from: source, to: target, link: link, score: adjust(link, id)))
        }
        // Stable sort: Swift's sort is not guaranteed stable, so tie-break on original position.
        let ranked = result.enumerated().sorted {
            $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
        }
        return ranked.prefix(limit).map(\.element)
    }

    /// Cross-track link targets with energy strictly higher (or lower) than the source, closest energy first.
    public func energyNeighbours(of id: String, higher: Bool, limit: Int) -> [PhraseNode] {
        guard limit > 0, let source = nodesById[id] else { return [] }
        var seen = Set<String>()
        let candidates = source.links.compactMap { link -> PhraseNode? in
            guard let target = nodesById[link.targetId],
                  target.sourceTrack != source.sourceTrack,
                  higher ? target.energy > source.energy : target.energy < source.energy,
                  seen.insert(target.id).inserted
            else { return nil }
            return target
        }
        let ranked = candidates.enumerated().sorted {
            let d0 = abs($0.element.energy - source.energy)
            let d1 = abs($1.element.energy - source.energy)
            return d0 != d1 ? d0 < d1 : $0.offset < $1.offset
        }
        return ranked.prefix(limit).map(\.element)
    }

    /// A random `trackIndex == 0` phrase, or nil if the graph has none.
    public func randomStart<G: RandomNumberGenerator>(using generator: inout G) -> PhraseNode? {
        startPhrases.randomElement(using: &generator)
    }

    public func randomStart() -> PhraseNode? {
        var generator = SystemRandomNumberGenerator()
        return randomStart(using: &generator)
    }
}
