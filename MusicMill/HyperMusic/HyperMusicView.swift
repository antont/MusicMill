import HyperCore
import SwiftUI

/// The HyperMusic tab: both decks with their waveforms on top, the control panel (session,
/// rating, mixer, output) on the left, and the centre graph in the main area. A thin layer over
/// `HyperSession`: every control and shortcut is one session call.
struct HyperMusicView: View {
    @Environment(AppAudio.self) private var app
    @State private var quantizeTarget: QuantizeTarget = .nextDownbeat
    @State private var showOutputSettings = false

    static let crossfaderStep: Float = 0.1

    var body: some View {
        let session = app.session
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                deckPanel(.a, session)
                deckPanel(.b, session)
            }
            .frame(height: 170)
            .disabled(app.navigator == nil)
            Divider()
            HSplitView {
                controlPanel(session)
                    .frame(minWidth: 260, idealWidth: 290, maxWidth: 340)
                graphArea(session)
            }
        }
        .onAppear { app.startIfNeeded() }
        .hyperShortcuts { shortcut, keyDown in perform(shortcut, keyDown: keyDown) }
        .sheet(isPresented: $showOutputSettings) { OutputSettingsView(app: app) }
    }

    private func deckPanel(_ id: HyperDeckID, _ session: HyperSession) -> some View {
        let deck = session.decks[id]!
        return DeckPanel(id: id, session: session, deck: deck,
                         trackDuration: deck.currentPhrase.flatMap { app.trackDuration(of: $0) },
                         quantizeTarget: quantizeTarget,
                         isCentre: session.centre == id,
                         isIncoming: session.incoming?.deck == id)
    }

    // MARK: Graph area

    @ViewBuilder
    private func graphArea(_ session: HyperSession) -> some View {
        Group {
            if let error = app.graphError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                    Button("Reload Graph") { Task { await app.loadGraph() } }
                        .disabled(app.isLoadingGraph)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.navigator == nil {
                ProgressView("Loading phrase graph…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CentreGraphView(session: session,
                                sequence: session.centreDeck?.currentPhrase.map { app.sequence(of: $0) } ?? [],
                                branches: app.branches)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    }

    // MARK: Control panel

    private func controlPanel(_ session: HyperSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("HyperMusic").font(.title2).fontWeight(.bold)
                if let message = session.message {
                    HStack(alignment: .top) {
                        Text(message).font(.caption).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button { session.clearMessage() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .help("Dismiss")
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button("Random Start") { Task { await app.randomStart() } }
                        .disabled(app.navigator == nil)
                    Spacer()
                    Button { showOutputSettings = true } label: { Label("Output", systemImage: "hifispeaker.2") }
                }
                Picker("Sync to", selection: $quantizeTarget) {
                    Text("Downbeat").tag(QuantizeTarget.nextDownbeat)
                    Text("Phrase").tag(QuantizeTarget.nextPhraseBoundary)
                }
                .pickerStyle(.segmented)
                Divider()
                if let db = app.feedback {
                    SessionControls(db: db)
                    Divider()
                } else if let error = app.feedbackError {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Divider()
                }
                ratingControls(session)
                Divider()
                MixerPanel(session: session)
                Divider()
                shortcutHelp
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func ratingControls(_ session: HyperSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rate Transition").font(.headline)
            if let t = session.lastTransition {
                Text("\(t.from.sourceTrackName) #\(t.from.sequenceNumber) → \(t.to.sourceTrackName) #\(t.to.sequenceNumber)")
                    .font(.caption)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Button { session.rateLastTransition(-1) } label: {
                        Image(systemName: "hand.thumbsdown.fill").foregroundStyle(.red)
                    }
                    .help("Rate down (−)")
                    Button { session.rateLastTransition(1) } label: {
                        Image(systemName: "hand.thumbsup.fill").foregroundStyle(.green)
                    }
                    .help("Rate up (+)")
                }
                .buttonStyle(.bordered)
            } else {
                Text("Mix a branch in to rate it").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutHelp: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Keys (A / B)").font(.headline)
            Group {
                Text("Play Q / P · Sync W / O · Loop E / I · PFL 1 / 0")
                Text("Nudge A S / K L · Bend Z X / , .")
                Text("⌘1–8 load branch · ← → crossfader · + − rate")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Shortcuts

    private func perform(_ shortcut: HyperShortcut, keyDown: Bool) {
        let session = app.session
        switch shortcut {
        case .bend(let d, let up):
            session.bend(d, active: keyDown, up: up)
        case _ where !keyDown:
            break
        case .playPause(let d):
            if session.decks[d]!.isPlaying { session.pause(d) } else { session.play(d) }
        case .quantizedStart(let d):
            session.quantizedStart(d, target: quantizeTarget)
        case .nudge(let d, let forward):
            session.nudge(d, ms: forward ? DeckPanel.nudgeMS : -DeckPanel.nudgeMS)
        case .loop(let d):
            session.toggleLoop(d)
        case .pfl(let d):
            session.setPFL(d, !session.decks[d]!.pfl)
        case .loadBranch(let n):
            let branches = app.branches
            guard n < branches.count else { return }
            Task { await session.loadBranch(branches[n]) }
        case .crossfaderStep(let towardB):
            session.crossfader = min(max(session.crossfader + (towardB ? Self.crossfaderStep : -Self.crossfaderStep), 0), 1)
        case .rate(let rating):
            session.rateLastTransition(rating)
        }
    }
}

/// Practice/performance session start and end, on the feedback database.
private struct SessionControls: View {
    @ObservedObject var db: RelationshipDatabase
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Session").font(.headline)
                Spacer()
                if let s = db.currentSession {
                    Circle().fill(s.type == .performance ? Color.red : Color.orange).frame(width: 8, height: 8)
                }
            }
            if let s = db.currentSession {
                HStack {
                    Text(s.type == .performance ? "Live" : "Practice").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("End") { run { try db.endSession(notes: nil) } }
                }
            } else {
                HStack(spacing: 8) {
                    Button("Practice") { run { _ = try db.startSession(type: .practice) } }
                    Button("Perform") { run { _ = try db.startSession(type: .performance) } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .controlSize(.small)
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
