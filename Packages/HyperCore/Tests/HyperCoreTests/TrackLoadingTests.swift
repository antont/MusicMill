import AVFoundation
import Foundation
import Testing
@testable import HyperCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrackLoadingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a Float32 WAV with the given channel contents.
private func writeWAV(_ url: URL, sampleRate: Double, channels: [[Float]]) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: AVAudioChannelCount(channels.count), interleaved: false)!
    let frames = channels[0].count
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for (i, ch) in channels.enumerated() {
        for j in 0..<frames { buffer.floatChannelData![i][j] = ch[j] }
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels.count,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

private actor CountingLoader: TrackLoading {
    private(set) var counts: [URL: Int] = [:]
    let frames: Int
    init(frames: Int = 125_000) { self.frames = frames }   // 125k frames * 2 ch * 4 B = 1 MB
    func track(for url: URL, sampleRate: Double) async throws -> AudioTrack {
        counts[url, default: 0] += 1
        try await Task.sleep(for: .milliseconds(20))
        return AudioTrack(url: url, sampleRate: sampleRate,
                          left: [Float](repeating: 0, count: frames),
                          right: [Float](repeating: 0, count: frames))
    }
    func count(_ url: URL) -> Int { counts[url, default: 0] }
}

private struct FailingOnceLoader: TrackLoading {
    let state = Box()
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
    }
    func track(for url: URL, sampleRate: Double) async throws -> AudioTrack {
        if state.next() == 1 { throw TrackLoadError.unreadable(url, "boom") }
        return AudioTrack(url: url, sampleRate: sampleRate, left: [0], right: [0])
    }
}

private let urlA = URL(fileURLWithPath: "/fake/a.wav")
private let urlB = URL(fileURLWithPath: "/fake/b.wav")
private let urlC = URL(fileURLWithPath: "/fake/c.wav")
private let urlD = URL(fileURLWithPath: "/fake/d.wav")

@Suite struct TrackLoadingTests {
    @Test func decodes48kMonoTo44100Stereo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sine.wav")
        let sine = (0..<96_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        try writeWAV(url, sampleRate: 48_000, channels: [sine])

        let track = try await TrackDecoder().track(for: url, sampleRate: 44_100)
        #expect(abs(track.frameCount - 88_200) <= 2)
        #expect(track.sampleRate == 44_100)
        var crossings = 0
        var identical = true
        for i in 0..<track.frameCount {
            if track.left[i] != track.right[i] { identical = false }
            if i > 0, (track.left[i - 1] < 0) != (track.left[i] < 0) { crossings += 1 }
        }
        #expect(identical)
        #expect(abs(crossings - 4000) <= 10)
    }

    @Test func decodes44100StereoUnchanged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stereo.wav")
        let n = 100_000   // spans several input chunks
        let l = (0..<n).map { Float($0 % 1000) / 1000 - 0.5 }
        let r = (0..<n).map { -Float($0 % 777) / 777 + 0.25 }
        try writeWAV(url, sampleRate: 44_100, channels: [l, r])

        let track = try await TrackDecoder().track(for: url, sampleRate: 44_100)
        #expect(track.frameCount == n)
        var same = true
        for i in 0..<n where track.left[i] != l[i] || track.right[i] != r[i] { same = false; break }
        #expect(same)
    }

    @Test func missingFileThrowsFileNotFound() async throws {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")
        await #expect(throws: TrackLoadError.fileNotFound(url)) {
            _ = try await TrackDecoder().track(for: url, sampleRate: 44_100)
        }
    }

    @Test func cacheEvictsLeastRecentlyUsedOverBudget() async throws {
        let loader = CountingLoader()
        let cache = TrackCache(loader: loader, budgetBytes: 2_500_000)
        _ = try await cache.track(for: urlA, sampleRate: 44_100)
        _ = try await cache.track(for: urlB, sampleRate: 44_100)
        _ = try await cache.track(for: urlA, sampleRate: 44_100)   // touch a
        _ = try await cache.track(for: urlC, sampleRate: 44_100)   // evicts b
        _ = try await cache.track(for: urlA, sampleRate: 44_100)
        #expect(await loader.count(urlA) == 1)
        #expect(await loader.count(urlC) == 1)
        _ = try await cache.track(for: urlB, sampleRate: 44_100)
        #expect(await loader.count(urlB) == 2)
    }

    @Test func concurrentRequestsDecodeOnce() async throws {
        let loader = CountingLoader()
        let cache = TrackCache(loader: loader)
        let tracks = try await withThrowingTaskGroup(of: AudioTrack.self) { group in
            for _ in 0..<10 { group.addTask { try await cache.track(for: urlA, sampleRate: 44_100) } }
            var out: [AudioTrack] = []
            for try await t in group { out.append(t) }
            return out
        }
        #expect(tracks.count == 10)
        #expect(await loader.count(urlA) == 1)
    }

    @Test func pinnedTracksAreNeverEvicted() async throws {
        let loader = CountingLoader()
        let cache = TrackCache(loader: loader, budgetBytes: 2_500_000)
        await cache.pin(urlA)
        _ = try await cache.track(for: urlA, sampleRate: 44_100)
        for u in [urlB, urlC, urlD] { _ = try await cache.track(for: u, sampleRate: 44_100) }
        _ = try await cache.track(for: urlA, sampleRate: 44_100)
        #expect(await loader.count(urlA) == 1)
    }

    @Test func failedLoadDoesNotPoisonCache() async throws {
        let cache = TrackCache(loader: FailingOnceLoader())
        await #expect(throws: TrackLoadError.self) {
            _ = try await cache.track(for: urlA, sampleRate: 44_100)
        }
        let track = try await cache.track(for: urlA, sampleRate: 44_100)
        #expect(track.frameCount == 1)
    }
}
