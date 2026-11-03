//
//  HyperMusicTests.swift
//  MusicMillTests
//
//  The HyperMusic tab's non-view logic: keyboard mapping, output-routing choices and
//  persistence, and serialized sample-rate recovery. Hermetic: no devices, files or graph.
//

import AppKit
import Foundation
import HyperCore
import Testing
@testable import MusicMill

@MainActor @Suite struct HyperShortcutsTests {
    private func map(_ chars: String, keyCode: UInt16 = 0, _ flags: NSEvent.ModifierFlags = []) -> HyperShortcut? {
        HyperShortcut.match(characters: chars, keyCode: keyCode, modifiers: flags)
    }

    @Test func deckKeysMapPerDeck() {
        #expect(map("q") == .playPause(.a))
        #expect(map("p") == .playPause(.b))
        #expect(map("w") == .quantizedStart(.a))
        #expect(map("o") == .quantizedStart(.b))
        #expect(map("a") == .nudge(.a, forward: false))
        #expect(map("s") == .nudge(.a, forward: true))
        #expect(map("k") == .nudge(.b, forward: false))
        #expect(map("l") == .nudge(.b, forward: true))
        #expect(map("z") == .bend(.a, up: false))
        #expect(map("x") == .bend(.a, up: true))
        #expect(map(",") == .bend(.b, up: false))
        #expect(map(".") == .bend(.b, up: true))
        #expect(map("e") == .loop(.a))
        #expect(map("i") == .loop(.b))
        #expect(map("1") == .pfl(.a))
        #expect(map("0") == .pfl(.b))
    }

    @Test func capsLockAndShiftStillMatchLetters() {
        #expect(map("Q", [.capsLock]) == .playPause(.a))
        #expect(map("P", [.shift]) == .playPause(.b))
    }

    @Test func commandDigitsLoadBranches() {
        #expect(map("1", [.command]) == .loadBranch(0))
        #expect(map("8", [.command]) == .loadBranch(7))
        #expect(map("9", [.command]) == nil)
        #expect(map("q", [.command]) == nil)          // ⌘Q stays the app's quit
    }

    @Test func arrowsStepTheCrossfader() {
        #expect(map("\u{F702}", keyCode: 123, [.function, .numericPad]) == .crossfaderStep(towardB: false))
        #expect(map("\u{F703}", keyCode: 124, [.function, .numericPad]) == .crossfaderStep(towardB: true))
    }

    @Test func plusAndMinusRate() {
        #expect(map("+") == .rate(1))
        #expect(map("+", [.shift]) == .rate(1))
        #expect(map("=") == .rate(1))
        #expect(map("-") == .rate(-1))
        #expect(map("−") == .rate(-1))
    }

    @Test func otherModifiersAndKeysAreIgnored() {
        #expect(map("q", [.control]) == nil)
        #expect(map("q", [.option]) == nil)
        #expect(map("y") == nil)
        #expect(map("") == nil)
    }

    @Test func onlyBendIsHeld() {
        #expect(HyperShortcut.bend(.a, up: true).isHeld)
        #expect(!HyperShortcut.playPause(.a).isHeld)
        #expect(!HyperShortcut.crossfaderStep(towardB: true).isHeld)
    }

    @Test func repeatsOnlyForContinuousActions() {
        #expect(HyperShortcut.crossfaderStep(towardB: true).repeats)
        #expect(HyperShortcut.nudge(.a, forward: true).repeats)
        #expect(!HyperShortcut.playPause(.a).repeats)
        #expect(!HyperShortcut.loop(.b).repeats)
        #expect(!HyperShortcut.bend(.a, up: true).repeats)
    }
}

@MainActor @Suite struct OutputRoutingChoiceTests {
    private let speakers = AudioDeviceInfo(id: 1, uid: "spk", name: "Speakers", outputChannels: 2, nominalSampleRate: 48000)
    private let interface = AudioDeviceInfo(id: 2, uid: "usb", name: "USB", outputChannels: 4, nominalSampleRate: 48000)

    @Test func cueChoiceBuildsRouting() {
        #expect(CueChoice.none.routing(masterUID: "spk") == .stereo(masterUID: "spk"))
        #expect(CueChoice.splitOnMaster.routing(masterUID: "spk") == .splitCue(deviceUID: "spk"))
        #expect(CueChoice.device("usb").routing(masterUID: "spk") == .separate(masterUID: "spk", cueUID: "usb"))
        #expect(CueChoice.device("usb").routing(masterUID: "usb") == .multichannel(deviceUID: "usb"))
    }

    @Test func routingRoundTripsToChoices() {
        let cases: [OutputRouting] = [
            .stereo(masterUID: "spk"), .splitCue(deviceUID: "spk"),
            .separate(masterUID: "spk", cueUID: "usb"), .multichannel(deviceUID: "usb"),
        ]
        for r in cases {
            #expect(CueChoice(r).routing(masterUID: r.masterDeviceUID) == r)
        }
    }

    @Test func cueChoicesOfferOnlyMultichannelMasterAsSameDeviceCue() {
        #expect(CueChoice.options(masterUID: "spk", devices: [speakers, interface])
            == [.none, .splitOnMaster, .device("usb")])
        #expect(CueChoice.options(masterUID: "usb", devices: [speakers, interface])
            == [.none, .splitOnMaster, .device("spk"), .device("usb")])
    }

    @Test func routingPersistsAsJSONUnderItsKey() throws {
        let suite = "HyperMusicTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoutingStore(defaults: defaults)
        #expect(store.load() == nil)
        store.save(.separate(masterUID: "spk", cueUID: "usb"))
        let data = try #require(defaults.data(forKey: "hyper.outputRouting"))
        #expect(try JSONDecoder().decode(OutputRouting.self, from: data) == .separate(masterUID: "spk", cueUID: "usb"))
        #expect(RoutingStore(defaults: defaults).load() == .separate(masterUID: "spk", cueUID: "usb"))
        defaults.set(Data("garbage".utf8), forKey: "hyper.outputRouting")
        #expect(store.load() == nil)
    }
}

/// Applies gated sample-rate changes: each call waits until the test releases it.
@MainActor private final class GatedApply {
    var calls: [Double] = []
    var active = 0
    var maxActive = 0
    private var gates: [CheckedContinuation<Void, Never>] = []

    func apply(_ rate: Double) async {
        calls.append(rate)
        active += 1
        maxActive = max(maxActive, active)
        await withCheckedContinuation { gates.append($0) }
        active -= 1
    }

    func releaseOne() {
        guard !gates.isEmpty else { Issue.record("nothing waiting"); return }
        gates.removeFirst().resume()
    }

    var waiting: Int { gates.count }
}

@MainActor
private func settle(until condition: () -> Bool) async {
    for _ in 0..<1000 where !condition() { await Task.yield() }
}

@MainActor @Suite struct SerialSampleRateChangesTests {
    @Test func oneChangeAtATimeAndOnlyTheLatestPendingRuns() async {
        let gate = GatedApply()
        let changes = SerialSampleRateChanges { await gate.apply($0) }
        changes.submit(48000)
        await settle { gate.waiting == 1 }
        #expect(gate.calls == [48000])

        changes.submit(96000)
        changes.submit(44100)
        await Task.yield()
        #expect(gate.calls == [48000])          // nothing starts while one runs

        gate.releaseOne()
        await settle { gate.waiting == 1 }
        #expect(gate.calls == [48000, 44100])   // the latest rate, once

        gate.releaseOne()
        await settle { !changes.isRunning }
        #expect(gate.calls == [48000, 44100])
        #expect(gate.maxActive == 1)
        #expect(!changes.isRunning)
    }

    @Test func submitAfterIdleRunsAgain() async {
        let gate = GatedApply()
        let changes = SerialSampleRateChanges { await gate.apply($0) }
        changes.submit(48000)
        await settle { gate.waiting == 1 }
        gate.releaseOne()
        await settle { !changes.isRunning }
        changes.submit(96000)
        await settle { gate.waiting == 1 }
        gate.releaseOne()
        await settle { !changes.isRunning }
        #expect(gate.calls == [48000, 96000])
    }

    @Test func aRateSubmittedFromInsideApplyIsQueued() async {
        var calls: [Double] = []
        var changes: SerialSampleRateChanges!
        changes = SerialSampleRateChanges { rate in
            calls.append(rate)
            // Like `replaceCore` firing `onSampleRateChange` synchronously.
            if rate == 48000 { changes.submit(96000) }
        }
        changes.submit(48000)
        await settle { !changes.isRunning && calls.count == 2 }
        #expect(calls == [48000, 96000])
    }
}
