import Foundation
import Testing
import HyperCore

/// Hands a value from a worker thread back to the test. The semaphore signal/wait
/// pair orders the write before the read.
private final class ThreadResult<Value: Sendable>: @unchecked Sendable {
    var value: Value
    let done = DispatchSemaphore(value: 0)
    init(_ value: Value) { self.value = value }
}

private func runOnThread(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        body()
        done.signal()
    }
    thread.start()
    return done
}

struct RealtimeBridgeTests {
    @Test func fifoOrder() {
        let q = SPSCQueue<Int>(capacity: 8)
        #expect(q.isEmpty)
        for i in 1...5 { #expect(q.push(i)) }
        #expect(!q.isEmpty)
        var out: [Int] = []
        while let v = q.pop() { out.append(v) }
        #expect(out == [1, 2, 3, 4, 5])
        #expect(q.isEmpty)
        #expect(q.pop() == nil)
    }

    @Test func pushFailsWhenFull() {
        let q = SPSCQueue<Int>(capacity: 4)
        for i in 0..<4 { #expect(q.push(i)) }
        #expect(!q.push(4))
        #expect(q.pop() == 0)
        #expect(q.push(4))
        #expect(!q.push(5))
    }

    @Test func capacityRoundsUpToPowerOfTwo() {
        let q = SPSCQueue<Int>(capacity: 5)
        var accepted = 0
        while q.push(accepted) { accepted += 1 }
        #expect(accepted == 8)
    }

    @Test func releasesRemainingElementsOnDeinit() {
        final class Token {}
        weak var weakToken: Token?
        do {
            let q = SPSCQueue<Token>(capacity: 4)
            let t = Token()
            weakToken = t
            #expect(q.push(t))
        }
        #expect(weakToken == nil)
    }

    @Test func concurrentProducerConsumerPreservesOrder() {
        let count = 1_000_000
        let q = SPSCQueue<Int>(capacity: 1024)
        // Index of the first out-of-order item, or `count` if all arrived in order.
        let result = ThreadResult(-1)

        let consumerDone = runOnThread {
            var expected = 0
            while expected < count {
                guard let v = q.pop() else { continue }
                if v != expected { break }
                expected += 1
            }
            result.value = expected
        }
        let producerDone = runOnThread {
            for i in 0..<count {
                while !q.push(i) {}
            }
        }
        producerDone.wait()
        consumerDone.wait()
        #expect(result.value == count)
        #expect(q.isEmpty)
    }

    struct Pair { var a: Int; var b: Int }

    @Test func snapshotNeverTorn() {
        let reads = 1_000_000
        let box = SnapshotBox(Pair(a: 0, b: 0))
        // The writer runs until the reader is done; a second box doubles as the stop flag.
        let stopFlag = SnapshotBox(false)

        let writerDone = runOnThread {
            var i = 0
            while !stopFlag.read() {
                i &+= 1
                box.write(Pair(a: i, b: i))
            }
        }

        var torn = 0
        var last = 0
        var wentBackwards = 0
        for _ in 0..<reads {
            let p = box.read()
            if p.a != p.b { torn += 1 }
            if p.a < last { wentBackwards += 1 }
            last = p.a
        }
        stopFlag.write(true)
        writerDone.wait()

        #expect(torn == 0)
        #expect(wentBackwards == 0)
        #expect(last > 0, "writer should have published at least one value")
    }

    @Test func snapshotRoundTripsOddSizedValues() {
        struct Odd: Equatable { var x: UInt8; var y: UInt16; var z: (UInt8, UInt8, UInt8) = (0, 0, 0)
            static func == (l: Odd, r: Odd) -> Bool { l.x == r.x && l.y == r.y && l.z == r.z }
        }
        let box = SnapshotBox(Odd(x: 1, y: 2, z: (3, 4, 5)))
        #expect(box.read() == Odd(x: 1, y: 2, z: (3, 4, 5)))
        box.write(Odd(x: 250, y: 65_000, z: (7, 8, 9)))
        #expect(box.read() == Odd(x: 250, y: 65_000, z: (7, 8, 9)))
    }
}
