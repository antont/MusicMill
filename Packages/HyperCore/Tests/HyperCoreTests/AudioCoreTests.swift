import Testing
import Foundation
@testable import HyperCore

private let sr = 44100.0

private func constantTrack(_ value: Float, frames: Int = 44100) -> AudioTrack {
    let s = [Float](repeating: value, count: frames)
    return AudioTrack(url: URL(fileURLWithPath: "/tmp/dc.wav"), sampleRate: sr, left: s, right: s)
}

private struct Rendered {
    var masterL: [Float], masterR: [Float], cueL: [Float], cueR: [Float]
}

/// Renders one `render` call of `frames` frames into fresh arrays.
@discardableResult
private func render(_ core: AudioCore, frames: Int) -> Rendered {
    var r = Rendered(masterL: .init(repeating: .nan, count: frames), masterR: .init(repeating: .nan, count: frames),
                     cueL: .init(repeating: .nan, count: frames), cueR: .init(repeating: .nan, count: frames))
    r.masterL.withUnsafeMutableBufferPointer { mL in r.masterR.withUnsafeMutableBufferPointer { mR in
    r.cueL.withUnsafeMutableBufferPointer { cL in r.cueR.withUnsafeMutableBufferPointer { cR in
        core.render(frames: frames, out: FourChannelOut(masterL: mL.baseAddress!, masterR: mR.baseAddress!,
                                                        cueL: cL.baseAddress!, cueR: cR.baseAddress!))
    }}}}
    return r
}

/// Retains `track` for the core (the main-thread side of the ownership rule) and sends `.load`.
private func load(_ core: AudioCore, _ deck: DeckID, _ track: AudioTrack, startFrame: Int = 0) {
    let u = Unmanaged.passRetained(track)
    let ok = core.send(.load(deck, u, startFrame: startFrame))
    precondition(ok)
}

@Suite struct AudioCoreTests {
    @Test func commandsApplyOnNextRender() {
        let core = AudioCore(sampleRate: sr)
        let t = constantTrack(0.25)
        load(core, .a, t, startFrame: 100)
        #expect(core.send(.fader(.a, 0.8)))
        #expect(core.send(.play(.a, at: nil)))
        // Nothing applies until the render thread drains the queue.
        #expect(core.snapshot.a.isPlaying == false)
        render(core, frames: 64)
        let s = core.snapshot
        #expect(s.a.isPlaying)
        #expect(s.a.position == 164)
        #expect(s.a.scheduledStart == -1)
        #expect(s.a.trackToken == UInt64(UInt(bitPattern: ObjectIdentifier(t))))
        #expect(s.b.trackToken == 0)
        #expect(s.b.isPlaying == false)
        core.drainReleasedTracks()
    }

    @Test func scheduledPlayUsesEngineSampleTime() {
        let core = AudioCore(sampleRate: sr)
        let t = constantTrack(0.25)
        load(core, .b, t)
        render(core, frames: 128)                       // engine time is now 128
        #expect(core.send(.play(.b, at: 128 + 1000)))
        render(core, frames: 512)
        #expect(core.snapshot.b.isPlaying)
        #expect(core.snapshot.b.scheduledStart == 1128)
        #expect(core.snapshot.b.position == 0)
        render(core, frames: 1024)                      // block 640..<1664 starts at 1128
        #expect(core.snapshot.b.scheduledStart == -1)
        #expect(core.snapshot.b.position == 1664 - 1128)
    }

    @Test func replacedTrackIsReleasedOnMainThreadOnly() {
        let core = AudioCore(sampleRate: sr)
        weak var weakT1: AudioTrack?
        do {
            let t1 = constantTrack(0.1)
            weakT1 = t1
            load(core, .a, t1)
        }
        render(core, frames: 64)
        let t2 = constantTrack(0.2)
        load(core, .a, t2)
        render(core, frames: 64)
        // The render thread has replaced t1 but must not have released it.
        #expect(weakT1 != nil)
        core.drainReleasedTracks()
        #expect(weakT1 == nil)
        #expect(core.snapshot.a.trackToken == UInt64(UInt(bitPattern: ObjectIdentifier(t2))))
    }

    @Test func loadingNilEmptiesDeckAndReleasesOldTrack() {
        let core = AudioCore(sampleRate: sr)
        weak var weakT: AudioTrack?
        do {
            let t = constantTrack(0.1)
            weakT = t
            load(core, .b, t)
        }
        #expect(core.send(.play(.b, at: nil)))
        render(core, frames: 64)
        #expect(core.send(.load(.b, nil, startFrame: 0)))
        render(core, frames: 64)
        let s = core.snapshot.b
        #expect(s.trackToken == 0)
        #expect(s.isPlaying == false)
        core.drainReleasedTracks()
        #expect(weakT == nil)
    }

    @Test func deinitReleasesLoadedAndQueuedTracks() {
        weak var weakLoaded: AudioTrack?
        weak var weakQueued: AudioTrack?
        weak var weakUnapplied: AudioTrack?
        do {
            let core = AudioCore(sampleRate: sr)
            do {
                let t1 = constantTrack(0.1), t2 = constantTrack(0.2), t3 = constantTrack(0.3)
                weakQueued = t1; weakLoaded = t2; weakUnapplied = t3
                load(core, .a, t1)
                render(core, frames: 16)
                load(core, .a, t2)
                render(core, frames: 16)        // t1 now sits in the release queue
                load(core, .b, t3)              // never rendered: still in the command queue
            }
            #expect(weakQueued != nil && weakLoaded != nil && weakUnapplied != nil)
        }
        #expect(weakQueued == nil)
        #expect(weakLoaded == nil)
        #expect(weakUnapplied == nil)
    }

    @Test func manyReplacementsWithoutDrainingAreNeverDropped() {
        let core = AudioCore(sampleRate: sr)
        var weaks: [() -> AudioTrack?] = []
        // Far more replacements than the release queue holds, never draining in between.
        for _ in 0..<300 {
            let t = constantTrack(0.1, frames: 16)
            weak let w = t
            weaks.append { w }
            load(core, .a, t)
            render(core, frames: 16)
        }
        // Everything replaced so far is still alive (nothing released on the render thread).
        #expect(weaks.allSatisfy { $0() != nil })
        for _ in 0..<10 {
            core.drainReleasedTracks()
            render(core, frames: 16)
        }
        core.drainReleasedTracks()
        // All but the currently loaded track have been released on this thread.
        #expect(weaks.dropLast().allSatisfy { $0() == nil })
        #expect(weaks.last!() != nil)
    }

    @Test func sampleTimeAdvances() {
        let core = AudioCore(sampleRate: sr)
        #expect(core.snapshot.sampleTime == 0)
        render(core, frames: 256)
        #expect(core.snapshot.sampleTime == 256)
        render(core, frames: 100)
        #expect(core.snapshot.sampleTime == 356)
        // Larger than maxFrames: processed in chunks, still advances by the full count.
        render(core, frames: 10_000)
        #expect(core.snapshot.sampleTime == 10_356)
        #expect(core.sampleRate == sr)
    }

    @Test func renderLargerThanMaxFramesIsChunked() {
        let core = AudioCore(sampleRate: sr, maxFrames: 256)
        let t = constantTrack(0.5)
        load(core, .a, t)
        #expect(core.send(.crossfader(0)))
        #expect(core.send(.play(.a, at: nil)))
        let r = render(core, frames: 3000)
        #expect(core.snapshot.a.position == 3000)
        #expect(r.masterL.allSatisfy { $0.isFinite })
        // Settled after the 10 ms ramps: full deck A through the smooth curve at x = 0.
        #expect(abs(r.masterL[2999] - 0.5) < 1e-3)
        #expect(abs(r.masterR[2999] - 0.5) < 1e-3)
    }

    @Test func snapshotPeakReflectsOutput() {
        let core = AudioCore(sampleRate: sr)
        let ta = constantTrack(0.5), tb = constantTrack(-0.25)
        load(core, .a, ta)
        load(core, .b, tb)
        #expect(core.send(.fader(.a, 1)))
        #expect(core.send(.fader(.b, 0.5)))
        #expect(core.send(.play(.a, at: nil)))
        #expect(core.send(.play(.b, at: nil)))
        render(core, frames: 2048)                      // let ramps settle
        render(core, frames: 512)
        let s = core.snapshot
        #expect(abs(s.a.peak - 0.5) < 1e-2)
        #expect(abs(s.b.peak - 0.25 * 0.25) < 1e-2)      // fader 0.5 → gain 0.25

        // Fader down → no post-fader level, even though the deck keeps playing.
        #expect(core.send(.fader(.a, 0)))
        render(core, frames: 2048)
        render(core, frames: 512)
        #expect(core.snapshot.a.peak == 0)
        #expect(core.snapshot.a.isPlaying)

        // Paused deck → the EQ filters ring down (the DC step), then the peak is ~zero.
        #expect(core.send(.pause(.b)))
        render(core, frames: 512)
        #expect(core.snapshot.b.peak > 0)
        render(core, frames: 44100)
        render(core, frames: 512)
        #expect(core.snapshot.b.peak < 1e-4)
    }

    @Test func fullQueueReturnsFalse() {
        let core = AudioCore(sampleRate: sr)
        var accepted = 0
        for _ in 0..<10_000 {
            if core.send(.master(0)) { accepted += 1 } else { break }
        }
        #expect(accepted > 0)
        #expect(accepted < 10_000)
        #expect(core.send(.master(0)) == false)
        render(core, frames: 64)                        // drains the queue
        #expect(core.send(.master(0)))
    }

    @Test func endToEndCrossfade() {
        let core = AudioCore(sampleRate: sr)
        let ta = constantTrack(0.5), tb = constantTrack(-0.5)
        load(core, .a, ta)
        load(core, .b, tb)
        let fader: Float = 0.8
        #expect(core.send(.fader(.a, 1)))
        #expect(core.send(.fader(.b, fader)))
        #expect(core.send(.crossfader(1.0)))
        #expect(core.send(.play(.a, at: nil)))
        #expect(core.send(.play(.b, at: nil)))
        let r = render(core, frames: 4096)
        let expected = -0.5 * fader * fader
        #expect(abs(r.masterL[4095] - expected) < 1e-3)
        #expect(abs(r.masterR[4095] - expected) < 1e-3)
        // PFL off and cueMix 0 → the cue bus is silent.
        #expect(abs(r.cueL[4095]) < 1e-6)
    }

    @Test func mixerCommandsReachTheMixer() {
        let core = AudioCore(sampleRate: sr)
        let ta = constantTrack(0.5)
        load(core, .a, ta)
        #expect(core.send(.crossfader(0)))
        #expect(core.send(.curve(.sharp)))
        #expect(core.send(.trim(.a, -6)))
        #expect(core.send(.eq(.a, .mid, 0)))
        #expect(core.send(.pfl(.a, true)))
        #expect(core.send(.cueMix(0)))
        #expect(core.send(.cueLevel(-6)))
        #expect(core.send(.master(-6)))
        #expect(core.send(.play(.a, at: nil)))
        let r = render(core, frames: 4096)
        let half = powf(10, -6 / 20)
        // trim −6 dB, master −6 dB on master; trim −6 dB, cue −6 dB on the PFL cue.
        #expect(abs(r.masterL[4095] - 0.5 * half * half) < 2e-3)
        #expect(abs(r.cueL[4095] - 0.5 * half * half) < 2e-3)
    }

    /// Render on another thread while this one sends, polls and drains: the cross-thread
    /// paths that TSan checks. Every loaded track except the last ends up released here.
    @Test func concurrentRenderSendAndDrain() async {
        let core = AudioCore(sampleRate: sr, maxFrames: 128)
        let renderer = Task.detached {
            var mL = [Float](repeating: 0, count: 128), mR = mL, cL = mL, cR = mL
            for _ in 0..<3000 {
                mL.withUnsafeMutableBufferPointer { a in mR.withUnsafeMutableBufferPointer { b in
                cL.withUnsafeMutableBufferPointer { c in cR.withUnsafeMutableBufferPointer { d in
                    core.render(frames: 128, out: FourChannelOut(masterL: a.baseAddress!, masterR: b.baseAddress!,
                                                                 cueL: c.baseAddress!, cueR: d.baseAddress!))
                }}}}
            }
        }
        var weaks: [() -> AudioTrack?] = []
        var lastTime: Int64 = 0
        for i in 0..<200 {
            let t = constantTrack(0.1, frames: 256)
            weak let w = t
            weaks.append { w }
            let u = Unmanaged.passRetained(t)
            if !core.send(.load(i % 2 == 0 ? .a : .b, u, startFrame: 0)) { u.release() }
            _ = core.send(.play(i % 2 == 0 ? .a : .b, at: nil))
            _ = core.send(.crossfader(Float(i % 10) / 10))
            let s = core.snapshot
            #expect(s.sampleTime >= lastTime)
            lastTime = s.sampleTime
            core.drainReleasedTracks()
        }
        await renderer.value
        for _ in 0..<5 {                // apply whatever is still queued
            render(core, frames: 64)
            core.drainReleasedTracks()
        }
        let alive = weaks.filter { $0() != nil }.count
        #expect(alive <= 2)        // at most the track loaded on each deck
    }

    @Test func transportCommands() {
        let core = AudioCore(sampleRate: sr)
        let t = constantTrack(0.1, frames: 10_000)
        load(core, .a, t)
        #expect(core.send(.seek(.a, frame: 1000)))
        #expect(core.send(.nudge(.a, frames: 24)))
        render(core, frames: 16)
        #expect(core.snapshot.a.position == 1024)
        #expect(core.send(.loop(.a, 1024..<1056)))
        #expect(core.send(.bend(.a, 1.0)))
        #expect(core.send(.play(.a, at: nil)))
        render(core, frames: 100)
        let p = core.snapshot.a.position
        #expect(p >= 1024 && p < 1056)
        #expect(core.send(.pause(.a)))
        render(core, frames: 16)
        #expect(core.snapshot.a.isPlaying == false)
        #expect(core.snapshot.a.position == p)
    }
}
