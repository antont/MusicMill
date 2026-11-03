import AppKit
import Combine
import HyperCore
import SwiftUI

/// One deck: transport (play/pause, quantized start, nudge, bend, loop, PFL), load state and
/// errors, and its scrolling waveform. Every control is one `HyperSession` call.
struct DeckPanel: View {
    let id: HyperDeckID
    let session: HyperSession
    let deck: DeckModel
    /// The song's length, for the full-track waveform playhead.
    let trackDuration: Double?
    let quantizeTarget: QuantizeTarget
    let isCentre: Bool
    let isIncoming: Bool

    static let nudgeMS = 10.0

    private var name: String { id == .a ? "A" : "B" }
    private var color: Color { id == .a ? .orange : .cyan }

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: 300)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            waveform
        }
        .background(Color.black)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            status
            HStack(spacing: 4) {
                Button { deck.isPlaying ? session.pause(id) : session.play(id) } label: {
                    Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .help(id == .a ? "Play/pause (Q)" : "Play/pause (P)")
                Button("SYNC") { session.quantizedStart(id, target: quantizeTarget) }
                    .help("Start on the centre deck's next \(quantizeTarget == .nextDownbeat ? "downbeat" : "phrase") (\(id == .a ? "W" : "O"))")
                Button { session.nudge(id, ms: -Self.nudgeMS) } label: { Image(systemName: "backward.frame") }
                    .help("Nudge −\(Int(Self.nudgeMS)) ms (\(id == .a ? "A" : "K"))")
                Button { session.nudge(id, ms: Self.nudgeMS) } label: { Image(systemName: "forward.frame") }
                    .help("Nudge +\(Int(Self.nudgeMS)) ms (\(id == .a ? "S" : "L"))")
                BendButton(symbol: "minus", session: session, deck: id, up: false)
                    .help("Slow down while held (\(id == .a ? "Z" : ","))")
                BendButton(symbol: "plus", session: session, deck: id, up: true)
                    .help("Speed up while held (\(id == .a ? "X" : "."))")
                Toggle("LOOP", isOn: Binding(get: { deck.loopEnabled }, set: { _ in session.toggleLoop(id) }))
                    .toggleStyle(.button)
                    .help("Loop the current phrase (\(id == .a ? "E" : "I"))")
                Toggle("PFL", isOn: Binding(get: { deck.pfl }, set: { session.setPFL(id, $0) }))
                    .toggleStyle(.button)
                    .tint(.yellow)
                    .help("Pre-listen in cue (\(id == .a ? "1" : "0"))")
            }
            .controlSize(.small)
            .disabled(deck.track == nil)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
            if isCentre {
                Text("CENTRE").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 4).background(color, in: RoundedRectangle(cornerRadius: 3))
            } else if isIncoming {
                Text("INCOMING").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
            }
            Text(deck.currentPhrase?.sourceTrackName ?? deck.track?.lastPathComponent ?? "Empty")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch deck.loadState {
            case .loading:
                ProgressView().controlSize(.mini)
                Text("Loading…").foregroundStyle(.secondary)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(reason).foregroundStyle(.red).lineLimit(2).help(reason)
            case .empty, .ready:
                if let phrase = deck.currentPhrase {
                    Text(phrase.segmentType).foregroundStyle(color)
                    Text("#\(phrase.sequenceNumber)").foregroundStyle(.secondary)
                    Text("\(phrase.bpm) BPM").foregroundStyle(.white)
                }
                Text(Self.formatTime(deck.positionSeconds)).foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    // MARK: Waveform

    private var waveform: some View {
        MetalWaveformView(
            phrase: deck.currentPhrase,
            playbackProgress: phraseProgress,
            trackPlaybackProgress: trackProgress,
            color: color,
            useOriginalFile: true
        )
        .overlay(alignment: .center) {
            if deck.currentPhrase == nil {
                Text(deck.track == nil ? "No track" : "Position is outside the graph's phrases")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phraseProgress: Double {
        guard let p = deck.currentPhrase, p.duration > 0 else { return 0 }
        return min(max((deck.positionSeconds - (p.startTime ?? 0)) / p.duration, 0), 1)
    }

    private var trackProgress: Double? {
        guard let trackDuration, trackDuration > 0 else { return nil }
        return min(max(deck.positionSeconds / trackDuration, 0), 1)
    }

    static func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Bends while pressed: one `bend(active: true)` on press, one `bend(active: false)` on release.
private struct BendButton: View {
    let symbol: String
    let session: HyperSession
    let deck: HyperDeckID
    let up: Bool
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .frame(width: 20, height: 18)
            .background(pressed ? Color.accentColor : Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        session.bend(deck, active: true, up: up)
                    }
                    .onEnded { _ in release() }
            )
            // A drag that never ends (window lost focus, view removed) must not leave the deck bent.
            .onDisappear { release() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                release()
            }
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        session.bend(deck, active: false, up: up)
    }
}
