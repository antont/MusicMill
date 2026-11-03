import Foundation

/// A whole decoded song as two raw, deinterleaved Float32 channel buffers.
///
/// The render thread reads `left` / `right` through `Unmanaged` references and raw
/// pointers. The buffers are immutable after init and freed in `deinit`; ownership rules
/// elsewhere guarantee the last release never happens on the render thread.
public final class AudioTrack: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Double
    public let frameCount: Int
    public let left: UnsafeMutablePointer<Float>
    public let right: UnsafeMutablePointer<Float>

    /// For tests and synthesis. Copies the samples; the shorter channel is zero-padded
    /// to the longer one's length.
    public init(url: URL, sampleRate: Double, left: [Float], right: [Float]) {
        let count = max(left.count, right.count)
        let capacity = max(count, 1)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        l.initialize(repeating: 0, count: capacity)
        r.initialize(repeating: 0, count: capacity)
        left.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { l.update(from: base, count: src.count) }
        }
        right.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { r.update(from: base, count: src.count) }
        }
        self.url = url
        self.sampleRate = sampleRate
        self.frameCount = count
        self.left = l
        self.right = r
    }

    /// Takes ownership of buffers allocated with `UnsafeMutablePointer<Float>.allocate`
    /// holding at least `frameCount` initialized samples (and at least one element).
    init(url: URL, sampleRate: Double, adoptingLeft left: UnsafeMutablePointer<Float>,
         right: UnsafeMutablePointer<Float>, frameCount: Int) {
        self.url = url
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.left = left
        self.right = right
    }

    /// Memory held by the two channel buffers.
    public var byteSize: Int { frameCount * 2 * MemoryLayout<Float>.stride }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}
