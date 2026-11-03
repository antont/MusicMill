import Foundation

/// Per-deck playback voice. A value type mutated only on the CoreAudio render thread.
///
/// Render-thread rules apply to `render` and every mutating method: no locks, allocation,
/// logging or ARC traffic. The track is held as `Unmanaged` (AudioCore owns retain/release)
/// and is only touched through `_withUnsafeGuaranteedRef`.
public struct DeckPlayer {
    public var track: Unmanaged<AudioTrack>?
    /// Fractional frames, song-absolute.
    public private(set) var position: Double = 0
    public private(set) var isPlaying: Bool = false
    public private(set) var scheduledStart: Int64?
    /// Varispeed ratio, clamped to 0.9...1.1.
    public var bend: Double = 1.0 {
        didSet { bend = min(1.1, max(0.9, bend)) }
    }
    public var loop: Range<Int>?

    public init() {}

    private var frameCount: Int {
        track?._withUnsafeGuaranteedRef { $0.frameCount } ?? 0
    }

    /// `nil` starts immediately; otherwise playback starts exactly at that engine sample time.
    public mutating func play(at sampleTime: Int64?) {
        isPlaying = true
        scheduledStart = sampleTime
    }

    public mutating func pause() {
        isPlaying = false
        scheduledStart = nil
    }

    public mutating func seek(toFrame f: Int) {
        position = Double(min(max(f, 0), frameCount))
    }

    public mutating func nudge(frames: Int) {
        position = min(max(position + Double(frames), 0), Double(frameCount))
    }

    /// Writes (never adds) `frames` samples of output.
    public mutating func render(left: UnsafeMutablePointer<Float>,
                                right: UnsafeMutablePointer<Float>,
                                frames: Int, blockStart: Int64) {
        guard isPlaying,
              let (srcL, srcR, count) = track?._withUnsafeGuaranteedRef({ ($0.left, $0.right, $0.frameCount) })
        else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }

        let end = Double(count)
        let step = bend
        var i = 0

        if let start = scheduledStart {
            let wait = start - blockStart
            if wait > 0 {
                i = Int(min(wait, Int64(frames)))
                left.update(repeating: 0, count: i)
                right.update(repeating: 0, count: i)
            }
            if i < frames || wait <= 0 { scheduledStart = nil }
        }

        var loopUpper = 0.0, loopLength = 0.0
        if let loop, loop.upperBound > loop.lowerBound {
            loopUpper = Double(loop.upperBound)
            loopLength = loopUpper - Double(loop.lowerBound)
        }

        while i < frames {
            if loopLength > 0 && position >= loopUpper { position -= loopLength }
            if position >= end || position < 0 {
                isPlaying = false
                left.advanced(by: i).update(repeating: 0, count: frames - i)
                right.advanced(by: i).update(repeating: 0, count: frames - i)
                return
            }
            let idx = Int(position)
            let t = Float(position - Double(idx))
            if t == 0 {
                left[i] = srcL[idx]
                right[i] = srcR[idx]
            } else {
                let i0 = max(idx - 1, 0), i2 = min(idx + 1, count - 1), i3 = min(idx + 2, count - 1)
                left[i] = DeckPlayer.hermite(srcL[i0], srcL[idx], srcL[i2], srcL[i3], t)
                right[i] = DeckPlayer.hermite(srcR[i0], srcR[idx], srcR[i2], srcR[i3], t)
            }
            position += step
            i += 1
        }
        if loopLength > 0 && position >= loopUpper { position -= loopLength }
    }

    @inline(__always)
    private static func hermite(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ t: Float) -> Float {
        let c0 = y1
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + c0
    }
}
