import Foundation
import HyperCore
import SwiftUI

/// Where cue goes, relative to the chosen master device.
enum CueChoice: Hashable {
    /// Master only.
    case none
    /// Left = cue (mono), right = master (mono) on the master device.
    case splitOnMaster
    /// Cue on this device: a separate device, or the master device itself (≥ 4 outputs, cue on 3/4).
    case device(String)

    init(_ r: OutputRouting) {
        switch r {
        case .stereo: self = .none
        case .splitCue: self = .splitOnMaster
        case .separate(_, let cue): self = .device(cue)
        case .multichannel(let d): self = .device(d)
        }
    }

    func routing(masterUID: String) -> OutputRouting {
        switch self {
        case .none: .stereo(masterUID: masterUID)
        case .splitOnMaster: .splitCue(deviceUID: masterUID)
        case .device(let uid) where uid == masterUID: .multichannel(deviceUID: masterUID)
        case .device(let uid): .separate(masterUID: masterUID, cueUID: uid)
        }
    }

    /// Cue options for `masterUID`: the master itself only when it has ≥ 4 outputs.
    static func options(masterUID: String, devices: [AudioDeviceInfo]) -> [CueChoice] {
        [.none, .splitOnMaster] + devices
            .filter { $0.uid != masterUID || $0.outputChannels >= 4 }
            .map { .device($0.uid) }
    }
}

extension OutputRouting {
    /// The device that carries master.
    var masterDeviceUID: String {
        switch self {
        case .stereo(let u), .splitCue(let u), .multichannel(let u): u
        case .separate(let u, _): u
        }
    }
}

/// The output routing persisted as JSON in `UserDefaults` under `"hyper.outputRouting"`.
struct RoutingStore {
    static let key = "hyper.outputRouting"
    let defaults: UserDefaults

    func load() -> OutputRouting? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(OutputRouting.self, from: data)
    }

    func save(_ r: OutputRouting) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Master and cue device pickers.
struct OutputSettingsView: View {
    let app: AppAudio
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [AudioDeviceInfo] = []
    @State private var masterUID = ""
    @State private var cue: CueChoice = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio Output").font(.headline)
            Form {
                Picker("Master", selection: $masterUID) {
                    ForEach(devices) { d in
                        Text("\(d.name) (\(d.outputChannels) ch)").tag(d.uid)
                    }
                }
                Picker("Cue", selection: $cue) {
                    ForEach(CueChoice.options(masterUID: masterUID, devices: devices), id: \.self) { choice in
                        Text(label(choice)).tag(choice)
                    }
                }
            }
            if let active = app.activeRouting, active != app.routing {
                Text("Playing on fallback: \(AppAudio.describe(active))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    app.setRouting(cue.routing(masterUID: masterUID))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(masterUID.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            let system = SystemDevices()
            devices = system.outputDevices()
            let current = app.routing ?? .stereo(masterUID: system.defaultOutput()?.uid ?? devices.first?.uid ?? "")
            masterUID = current.masterDeviceUID
            cue = CueChoice(current)
        }
        .onChange(of: masterUID) { _, uid in
            if !CueChoice.options(masterUID: uid, devices: devices).contains(cue) { cue = .none }
        }
    }

    private func label(_ choice: CueChoice) -> String {
        switch choice {
        case .none: "None (master only)"
        case .splitOnMaster: "Split on master device (L cue / R master)"
        case .device(let uid) where uid == masterUID: "Same device, outputs 3/4"
        case .device(let uid): devices.first { $0.uid == uid }?.name ?? uid
        }
    }
}
