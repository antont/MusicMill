import Testing
import Foundation
import CoreAudio
@testable import HyperCore

func device(_ uid: String, id: AudioDeviceID, outputs: Int = 2, rate: Double = 44100) -> AudioDeviceInfo {
    AudioDeviceInfo(id: id, uid: uid, name: uid, outputChannels: outputs, nominalSampleRate: rate)
}

@Suite struct OutputRoutingTests {
    let speakers = device("speakers", id: 10)
    let phones = device("phones", id: 11)
    let interface = device("interface", id: 12, outputs: 4)

    @Test func resolveFallsBackWhenCueMissing() {
        #expect(resolve(.separate(masterUID: "speakers", cueUID: "phones"), devices: [speakers])
                == .stereo(masterUID: "speakers"))
    }

    @Test func resolveKeepsRoutingWhenAllDevicesPresent() {
        let all = [speakers, phones, interface]
        for r: OutputRouting in [.stereo(masterUID: "speakers"), .splitCue(deviceUID: "phones"),
                                 .separate(masterUID: "speakers", cueUID: "phones"),
                                 .multichannel(deviceUID: "interface")] {
            #expect(resolve(r, devices: all) == r)
        }
    }

    @Test func resolveFallsBackToDefaultWhenMasterMissing() {
        #expect(resolve(.stereo(masterUID: "gone"), devices: [speakers, phones], defaultUID: "phones")
                == .stereo(masterUID: "phones"))
        #expect(resolve(.separate(masterUID: "gone", cueUID: "phones"), devices: [speakers, phones],
                        defaultUID: "speakers")
                == .stereo(masterUID: "speakers"))
        #expect(resolve(.splitCue(deviceUID: "gone"), devices: [speakers]) == .stereo(masterUID: "speakers"))
        // Nothing to fall back to: keep the master UID; starting will fail with deviceNotFound.
        #expect(resolve(.stereo(masterUID: "gone"), devices: []) == .stereo(masterUID: "gone"))
    }

    @Test func multichannelNeeds4Outputs() {
        #expect(resolve(.multichannel(deviceUID: "speakers"), devices: [speakers])
                == .stereo(masterUID: "speakers"))
        #expect(resolve(.multichannel(deviceUID: "interface"), devices: [interface])
                == .multichannel(deviceUID: "interface"))
        #expect(resolve(.multichannel(deviceUID: "gone"), devices: [interface], defaultUID: "interface")
                == .stereo(masterUID: "interface"))
    }

    @Test func separateOnOneDeviceUsesItsChannels() {
        #expect(resolve(.separate(masterUID: "interface", cueUID: "interface"), devices: [interface])
                == .multichannel(deviceUID: "interface"))
        #expect(resolve(.separate(masterUID: "speakers", cueUID: "speakers"), devices: [speakers])
                == .stereo(masterUID: "speakers"))
    }

    @Test func separateLayoutPutsCueAfterMasterChannels() {
        let r = OutputRouting.separate(masterUID: "speakers", cueUID: "phones")
        #expect(channelLayout(for: r, deviceChannels: 4, masterChannels: 2) == [.masterL, .masterR, .cueL, .cueR])
        // A 4-output master device: cue lands on the aggregate's channels 4/5, 2/3 are silent.
        #expect(channelLayout(for: r, deviceChannels: 6, masterChannels: 4)
                == [.masterL, .masterR, nil, nil, .cueL, .cueR])
    }

    @Test func splitCueLayout() {
        #expect(channelLayout(for: .splitCue(deviceUID: "phones"), deviceChannels: 2, masterChannels: 2)
                == [.splitCueMono, .splitMasterMono])
        #expect(channelLayout(for: .splitCue(deviceUID: "phones"), deviceChannels: 4, masterChannels: 4)
                == [.splitCueMono, .splitMasterMono, nil, nil])
    }

    @Test func stereoAndMultichannelLayouts() {
        #expect(channelLayout(for: .stereo(masterUID: "x"), deviceChannels: 4, masterChannels: 4)
                == [.masterL, .masterR, nil, nil])
        #expect(channelLayout(for: .stereo(masterUID: "x"), deviceChannels: 1, masterChannels: 1) == [.masterL])
        #expect(channelLayout(for: .multichannel(deviceUID: "x"), deviceChannels: 6, masterChannels: 6)
                == [.masterL, .masterR, .cueL, .cueR, nil, nil])
    }

    @Test func layoutNeverExceedsDeviceChannels() {
        #expect(channelLayout(for: .separate(masterUID: "a", cueUID: "b"), deviceChannels: 3, masterChannels: 2)
                == [.masterL, .masterR, .cueL])
        #expect(channelLayout(for: .multichannel(deviceUID: "x"), deviceChannels: 0, masterChannels: 0) == [])
    }

    @Test func routingRoundTripsThroughCodable() throws {
        let r = OutputRouting.separate(masterUID: "m", cueUID: "c")
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(OutputRouting.self, from: data) == r)
    }

    @Test func aggregateDescriptionIsPrivateWithMasterClockAndCueDrift() throws {
        let d = AggregateDevice.description(masterUID: "speakers", cueUID: "phones", uid: "agg-1")
        #expect(d[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
        #expect(d[kAudioAggregateDeviceUIDKey] as? String == "agg-1")
        #expect(d[kAudioAggregateDeviceMainSubDeviceKey] as? String == "speakers")
        #expect(d[kAudioAggregateDeviceClockDeviceKey] as? String == "speakers")
        let subs = try #require(d[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subs.count == 2)
        #expect(subs[0][kAudioSubDeviceUIDKey] as? String == "speakers")
        #expect(subs[0][kAudioSubDeviceDriftCompensationKey] as? Int == 0)
        #expect(subs[1][kAudioSubDeviceUIDKey] as? String == "phones")
        #expect(subs[1][kAudioSubDeviceDriftCompensationKey] as? Int == 1)
        #expect(AggregateDevice.isOwn(uid: AggregateDevice.uidPrefix + "x"))
        #expect(!AggregateDevice.isOwn(uid: "speakers"))
    }
}
