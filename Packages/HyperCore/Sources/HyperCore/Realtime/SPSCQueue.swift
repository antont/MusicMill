import Synchronization

/// Lock-free, wait-free, bounded single-producer / single-consumer FIFO.
///
/// Exactly one thread may call `push` and exactly one (other) thread may call `pop`.
/// Neither side allocates, locks or blocks, so either side may be the CoreAudio
/// render thread. Storage is allocated once in `init`.
///
/// `head` and `tail` are monotonically increasing counters (slot = counter & mask).
/// The producer publishes a slot with a release store of `tail`; the consumer frees
/// a slot with a release store of `head`. Each side acquire-loads the other's counter.
///
/// `push`, `pop` and `isEmpty` are `@inlinable` so they are specialized for the
/// concrete `Element` in the caller's module (no generic value-witness calls on the
/// render thread, and ThreadSanitizer sees the slot accesses).
///
/// Render-thread note: popping an element moves it out of the buffer; if `Element`
/// is (or contains) a class reference the caller then owns that reference. Use value
/// types or `Unmanaged` on the render thread so no release can free memory there.
public final class SPSCQueue<Element>: @unchecked Sendable {
    @usableFromInline let buffer: UnsafeMutablePointer<Element?>
    @usableFromInline let capacity: Int
    @usableFromInline let mask: Int
    /// Next slot to pop. Written only by the consumer.
    @usableFromInline let head = Atomic<Int>(0)
    /// Next slot to push. Written only by the producer.
    @usableFromInline let tail = Atomic<Int>(0)

    /// - Parameter capacity: minimum number of elements; rounded up to a power of two.
    public init(capacity: Int) {
        precondition(capacity > 0, "SPSCQueue capacity must be positive")
        var c = 1
        while c < capacity { c <<= 1 }
        self.capacity = c
        self.mask = c - 1
        buffer = .allocate(capacity: c)
        buffer.initialize(repeating: nil, count: c)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Producer side. Returns false (and drops nothing) when the queue is full.
    @inlinable public func push(_ e: Element) -> Bool {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        if t &- h == capacity { return false }
        // The slot is nil here (the consumer `take()`s it), so this assignment releases nothing.
        buffer[t & mask] = e
        tail.store(t &+ 1, ordering: .releasing)
        return true
    }

    /// Consumer side. Returns nil when the queue is empty.
    @inlinable public func pop() -> Element? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        if h == t { return nil }
        let e = buffer[h & mask].take()
        head.store(h &+ 1, ordering: .releasing)
        return e
    }

    /// Exact when called from the producer or the consumer; a snapshot otherwise.
    @inlinable public var isEmpty: Bool {
        head.load(ordering: .acquiring) == tail.load(ordering: .acquiring)
    }
}
