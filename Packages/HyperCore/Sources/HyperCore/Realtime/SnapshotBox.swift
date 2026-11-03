import Synchronization

/// Single-writer, multi-reader latest-value box (a two-slot seqlock).
///
/// The writer (the audio render thread) never blocks, allocates or locks. Readers
/// retry when the sequence shows their slot may have been overwritten, so `read()`
/// never returns a torn value.
///
/// Design notes:
///
/// - **Atomic payload words.** The payload is stored as `Atomic<UInt64>` words read
///   and written with relaxed ordering, not as a plain `T`. A textbook seqlock reads a
///   plain payload while the writer may be writing it; the sequence check discards
///   such torn reads, but the concurrent plain access is still a data race under the
///   Swift/C++ memory model (and TSan reports it). With atomic words every shared
///   access is atomic, and ordering comes from the sequence counter plus fences
///   (Boehm, "Can Seqlocks Get Along with Programming Language Memory Models?", 2012).
///   `T`'s bytes are copied in and out word by word, padded to a multiple of 8 bytes.
///
/// - **Two slots.** `sequence` is odd while a write is in progress and even when
///   stable; write number `w` completes at `sequence == 2w`. Write `w` goes to slot
///   `w & 1`, so while write `w + 1` is in progress (sequence `2w + 1`) the previous
///   value in slot `w & 1` is still intact and readable. A reader only has to retry
///   if the slot it read was overwritten by write `w + 2` (sequence reached `2w + 3`).
///   With a single slot, a writer that writes back-to-back leaves readers only the
///   tiny gap between writes and they can starve; with two slots they get a whole
///   write period.
///
///       writer (sequence s = 2w):
///         sequence = s + 1 (release); release fence
///         store words of slot (w + 1) & 1 (relaxed)
///         sequence = s + 2 (release)
///       reader:
///         s1 = sequence (acquire); w = s1 / 2
///         load words of slot w & 1 (relaxed); acquire fence
///         s2 = sequence (relaxed); accept iff s2 <= 2w + 2
///
///   Why the check is sufficient: write `w + 2` stores `sequence = 2w + 3` and issues
///   a release fence before touching slot `w & 1`. If any of the reader's relaxed
///   loads observed such a store, that fence synchronizes with the reader's acquire
///   fence, so the reader's `s2` load must see at least `2w + 3`. The opening store
///   is `.releasing` so that a reader observing the odd value `2w + 1` still
///   synchronizes with the end of write `w` (plain stores do not extend a release
///   sequence).
public final class SnapshotBox<T: BitwiseCopyable>: @unchecked Sendable {
    /// Even: stable. Odd: a write is in progress. Written only by the writer.
    @usableFromInline let sequence = Atomic<UInt64>(0)
    /// Two slots of `wordCount` words each.
    @usableFromInline let words: UnsafeMutablePointer<Atomic<UInt64>>
    @usableFromInline let wordCount: Int

    public init(_ initial: T) {
        wordCount = max((MemoryLayout<T>.size + 7) / 8, 1)
        words = .allocate(capacity: 2 * wordCount)
        for i in 0..<(2 * wordCount) {
            (words + i).initialize(to: Atomic(0))
        }
        storeWords(initial, slot: 0)
    }

    deinit {
        // Atomic<UInt64> is trivially destructible; no deinitialize needed.
        words.deallocate()
    }

    /// Single writer only. Real-time safe: no allocation, locks or ARC traffic.
    @inlinable public func write(_ v: T) {
        let s = sequence.load(ordering: .relaxed)
        sequence.store(s &+ 1, ordering: .releasing)
        atomicMemoryFence(ordering: .releasing)
        storeWords(v, slot: Int((s >> 1) &+ 1) & 1)
        sequence.store(s &+ 2, ordering: .releasing)
    }

    /// Any thread. Retries if the slot it read was overwritten; never returns a torn value.
    @inlinable public func read() -> T {
        withUnsafeTemporaryAllocation(
            byteCount: wordCount * 8, alignment: max(MemoryLayout<T>.alignment, 8)
        ) { scratch in
            let scratchWords = scratch.baseAddress!.assumingMemoryBound(to: UInt64.self)
            while true {
                let s1 = sequence.load(ordering: .acquiring)
                let lastComplete = s1 & ~1          // 2w
                let slot = words + Int((s1 >> 1) & 1) * wordCount
                for i in 0..<wordCount {
                    scratchWords[i] = slot[i].load(ordering: .relaxed)
                }
                atomicMemoryFence(ordering: .acquiring)
                let s2 = sequence.load(ordering: .relaxed)
                if s2 &- lastComplete <= 2 {
                    return scratch.load(as: T.self)
                }
            }
        }
    }

    /// Copies `v`'s bytes into one slot's atomic words (relaxed stores). Writer only.
    @usableFromInline func storeWords(_ v: T, slot: Int) {
        let dest = words + slot * wordCount
        withUnsafeBytes(of: v) { bytes in
            let size = bytes.count
            for i in 0..<wordCount {
                let offset = i * 8
                let word: UInt64
                if offset + 8 <= size {
                    word = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                } else {
                    // Trailing partial word (or an empty T): copy the remaining bytes,
                    // zero-padded, in memory order.
                    var w: UInt64 = 0
                    withUnsafeMutableBytes(of: &w) { wb in
                        for j in 0..<max(size - offset, 0) { wb[j] = bytes[offset + j] }
                    }
                    word = w
                }
                dest[i].store(word, ordering: .relaxed)
            }
        }
    }
}
