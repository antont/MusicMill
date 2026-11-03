import HyperCore
import SwiftUI

/// Per-channel EQ (with kills), trim and fader; crossfader with curve; cue mix and levels.
/// Every control is one `HyperSession` call or property write.
struct MixerPanel: View {
    let session: HyperSession

    /// The band gain a kill restores, per channel and band (view state only).
    @State private var beforeKill: [String: Float] = [:]

    static let eqRange: ClosedRange<Float> = -26...IsolatorEQ.maxDB
    static let trimRange: ClosedRange<Float> = -12...12
    static let levelRange: ClosedRange<Float> = -24...6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mixer").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                channel(.a)
                Divider()
                channel(.b)
            }
            crossfader
            levels
        }
    }

    // MARK: Channel strip

    private func channel(_ id: HyperDeckID) -> some View {
        let deck = session.decks[id]!
        return VStack(spacing: 6) {
            Text(id == .a ? "A" : "B")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(id == .a ? .orange : .cyan)
            Knob(label: "TRIM", value: Binding(get: { deck.trimDB }, set: { session.setTrim(id, dB: $0) }),
                 range: Self.trimRange, defaultValue: 0, format: Self.dB)
            band(id, .high, "HI", deck.eq.high)
            band(id, .mid, "MID", deck.eq.mid)
            band(id, .low, "LOW", deck.eq.low)
            Slider(value: Binding(get: { deck.fader }, set: { session.setFader(id, $0) }), in: 0...1)
                .controlSize(.mini)
                .help("Channel fader")
            Text("FADER \(Int((deck.fader * 100).rounded()))")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func band(_ id: HyperDeckID, _ band: EQBand, _ label: String, _ dB: Float) -> some View {
        let killed = !(dB > IsolatorEQ.killThresholdDB)
        let key = "\(id)-\(band)"
        return HStack(spacing: 4) {
            Knob(label: label,
                 value: Binding(get: { killed ? Self.eqRange.lowerBound : dB },
                                set: { session.setEQ(id, band, dB: $0) }),
                 range: Self.eqRange, defaultValue: 0, format: Self.dB, dimmed: killed)
            Button {
                if killed {
                    session.setEQ(id, band, dB: beforeKill[key] ?? 0)
                } else {
                    beforeKill[key] = dB
                    session.setEQ(id, band, dB: -.infinity)
                }
            } label: {
                Text("K").font(.system(size: 9, weight: .bold)).frame(width: 14)
            }
            .buttonStyle(.bordered)
            .tint(killed ? .red : nil)
            .controlSize(.mini)
            .help("Kill \(label)")
        }
    }

    // MARK: Crossfader and levels

    private var crossfader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("A").foregroundStyle(.orange)
                Slider(value: Binding(get: { session.crossfader }, set: { session.crossfader = $0 }), in: 0...1)
                Text("B").foregroundStyle(.cyan)
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .help("Crossfader (← / →)")
            Picker("Curve", selection: Binding(get: { session.curve }, set: { session.curve = $0 })) {
                Text("Smooth").tag(CrossfaderCurve.smooth)
                Text("Sharp").tag(CrossfaderCurve.sharp)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    private var levels: some View {
        VStack(alignment: .leading, spacing: 2) {
            labeledSlider("Master", Binding(get: { session.masterDB }, set: { session.masterDB = $0 }),
                          Self.levelRange, Self.dB(session.masterDB))
            labeledSlider("Cue", Binding(get: { session.cueDB }, set: { session.cueDB = $0 }),
                          Self.levelRange, Self.dB(session.cueDB))
            labeledSlider("Cue mix", Binding(get: { session.cueMix }, set: { session.cueMix = $0 }),
                          0...1, session.cueMix < 0.01 ? "PFL" : session.cueMix > 0.99 ? "MST" : "\(Int(session.cueMix * 100))%")
        }
        .font(.system(size: 10))
    }

    private func labeledSlider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>,
                               _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range).controlSize(.mini)
            Text(text).font(.system(size: 9, design: .monospaced)).frame(width: 40, alignment: .trailing)
        }
    }

    nonisolated static func dB(_ v: Float) -> String {
        guard v > IsolatorEQ.killThresholdDB else { return "KILL" }
        return String(format: "%+.1f", v)
    }
}

/// A rotary knob: drag up/down to turn, double-click to reset.
struct Knob: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    let format: (Float) -> String
    var dimmed = false

    @State private var dragStart: Float?

    /// Points of vertical drag for the full range.
    private static let travel: Float = 150

    private var fraction: Double {
        Double((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
            / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().fill(Color(white: 0.18))
                Circle().stroke(Color.gray.opacity(0.6), lineWidth: 1)
                Capsule()
                    .fill(dimmed ? Color.red : Color.white)
                    .frame(width: 2, height: 8)
                    .offset(y: -6)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = start }
                        let base = start.isFinite ? start : range.lowerBound
                        let delta = Float(-g.translation.height) / Self.travel * (range.upperBound - range.lowerBound)
                        value = min(max(base + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = defaultValue }
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 8, weight: .bold))
                Text(dimmed ? "KILL" : format(value)).font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(dimmed ? .red : .secondary)
            }
            .frame(width: 30, alignment: .leading)
        }
        .help("\(label): drag to turn, double-click to reset")
    }
}
