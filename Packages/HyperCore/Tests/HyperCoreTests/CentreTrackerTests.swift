import Testing
import Foundation
@testable import HyperCore

private func lv(_ a: Double, _ b: Double) -> [DeckID: Double] { [.a: a, .b: b] }

@Suite struct CentreTrackerTests {
    @Test func firstAudibleDeckBecomesCentreImmediately() {
        var t = CentreTracker()
        #expect(t.update(levels: lv(0.1, 0.1), now: 0) == nil)
        #expect(t.centre == nil)
        #expect(t.update(levels: lv(0.1, 0.5), now: 0.1) == Handover(from: nil, to: .b))
        #expect(t.centre == .b)
        #expect(t.update(levels: lv(0.1, 0.5), now: 0.2) == nil)
    }

    @Test func wiggleShorterThanDwellDoesNotSwitch() {
        var t = CentreTracker()
        _ = t.update(levels: lv(0.8, 0), now: 0)
        for i in 0...6 { #expect(t.update(levels: lv(0.4, 0.9), now: 1 + Double(i) * 0.1) == nil) }
        #expect(t.update(levels: lv(0.8, 0.1), now: 1.7) == nil)
        // dwell restarted: B dominant again from 2.0 must not switch before 3.0
        #expect(t.update(levels: lv(0.4, 0.9), now: 2.0) == nil)
        #expect(t.update(levels: lv(0.4, 0.9), now: 2.9) == nil)
        #expect(t.centre == .a)
    }

    @Test func sustainedDominanceSwitchesAfterDwell() {
        var t = CentreTracker()
        _ = t.update(levels: lv(0.8, 0), now: 0)
        #expect(t.update(levels: lv(0.4, 0.9), now: 0) == nil)
        #expect(t.update(levels: lv(0.4, 0.9), now: 0.99) == nil)
        #expect(t.update(levels: lv(0.4, 0.9), now: 1.0) == Handover(from: .a, to: .b))
        #expect(t.centre == .b)
    }

    @Test func pullingBackReversesAfterDwell() {
        var t = CentreTracker()
        _ = t.update(levels: lv(0.8, 0), now: 0)
        _ = t.update(levels: lv(0.4, 0.9), now: 0)
        _ = t.update(levels: lv(0.4, 0.9), now: 1.0)
        #expect(t.centre == .b)
        #expect(t.update(levels: lv(0.9, 0.4), now: 2.0) == nil)
        #expect(t.update(levels: lv(0.9, 0.4), now: 2.99) == nil)
        #expect(t.update(levels: lv(0.9, 0.4), now: 3.0) == Handover(from: .b, to: .a))
    }

    @Test func stoppedCentreWithAudibleOtherSwitchesAfterDwell() {
        var t = CentreTracker()
        _ = t.update(levels: lv(0.8, 0), now: 0)
        #expect(t.update(levels: lv(0, 0.3), now: 5) == nil)
        #expect(t.update(levels: lv(0, 0.3), now: 5.99) == nil)
        #expect(t.update(levels: lv(0, 0.3), now: 6.0) == Handover(from: .a, to: .b))
    }

    @Test func belowMinLevelNeverTakesOver() {
        var t = CentreTracker()
        _ = t.update(levels: lv(0.8, 0), now: 0)
        for i in 0..<50 { #expect(t.update(levels: lv(0.05, 0.19), now: Double(i)) == nil) }
        #expect(t.centre == .a)
        // both below minLevel: centre stays, never nil
        for i in 50..<60 { #expect(t.update(levels: lv(0, 0.1), now: Double(i)) == nil) }
        #expect(t.centre == .a)
    }

    @Test func effectiveLevelKillsReduceOpenness() {
        let open = effectiveLevel(isPlaying: true, trim: 1, fader: 1, crossfaderGain: 1, eqLinear: (1, 1, 1))
        #expect(abs(open - 1) < 1e-9)
        let lowKill = effectiveLevel(isPlaying: true, trim: 1, fader: 1, crossfaderGain: 1, eqLinear: (0, 1, 1))
        #expect(abs(lowKill - 0.5) < 1e-6)
        #expect(effectiveLevel(isPlaying: false, trim: 1, fader: 1, crossfaderGain: 1, eqLinear: (1, 1, 1)) == 0)
        let boosted = effectiveLevel(isPlaying: true, trim: 0.5, fader: 1, crossfaderGain: 1, eqLinear: (2, 2, 2))
        #expect(abs(boosted - 0.5) < 1e-6)
    }
}
