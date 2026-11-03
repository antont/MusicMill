import Foundation

/// LRU cache of decoded tracks, bounded by bytes, keyed by (url, sampleRate).
///
/// Tracks whose url is pinned (loaded on a deck) are never evicted, whatever the sample
/// rate. Concurrent requests for one key share a single in-flight decode, and a failed
/// decode is forgotten so a retry decodes again.
public actor TrackCache: TrackLoading {
    private struct Key: Hashable {
        let url: URL
        let sampleRate: Double
    }

    private struct Entry {
        let id: Int
        let task: Task<AudioTrack, Error>
        var bytes: Int?          // nil while in flight
        var lastUsed: Int
    }

    private let loader: any TrackLoading
    private let budgetBytes: Int
    private var entries: [Key: Entry] = [:]
    private var pins: [URL: Int] = [:]
    private var tick = 0
    private var nextID = 0

    public init(loader: any TrackLoading, budgetBytes: Int = 1_500_000_000) {
        self.loader = loader
        self.budgetBytes = budgetBytes
    }

    public func track(for url: URL, sampleRate: Double) async throws -> AudioTrack {
        let key = Key(url: url, sampleRate: sampleRate)
        tick += 1
        let entry: Entry
        if var existing = entries[key] {
            existing.lastUsed = tick
            entries[key] = existing
            entry = existing
        } else {
            nextID += 1
            let loader = self.loader
            let task = Task { try await loader.track(for: url, sampleRate: sampleRate) }
            entry = Entry(id: nextID, task: task, bytes: nil, lastUsed: tick)
            entries[key] = entry
        }

        do {
            let track = try await entry.task.value
            if var current = entries[key], current.id == entry.id {
                if current.bytes == nil {
                    current.bytes = track.byteSize
                    entries[key] = current
                }
                evictIfNeeded()
            }
            return track
        } catch {
            if let current = entries[key], current.id == entry.id {
                entries[key] = nil
            }
            throw error
        }
    }

    /// Protects every cached sample rate of `url` from eviction. Ref-counted.
    public func pin(_ url: URL) {
        pins[url, default: 0] += 1
    }

    public func unpin(_ url: URL) {
        guard let count = pins[url] else { return }
        if count <= 1 {
            pins[url] = nil
            evictIfNeeded()
        } else {
            pins[url] = count - 1
        }
    }

    public func removeAll() {
        for (_, entry) in entries where entry.bytes == nil { entry.task.cancel() }
        entries.removeAll()
    }

    private func evictIfNeeded() {
        var total = entries.values.reduce(0) { $0 + ($1.bytes ?? 0) }
        while total > budgetBytes {
            let victim = entries
                .filter { $0.value.bytes != nil && pins[$0.key.url] == nil }
                .min { $0.value.lastUsed < $1.value.lastUsed }
            guard let victim else { return }
            total -= victim.value.bytes ?? 0
            entries[victim.key] = nil
        }
    }
}
