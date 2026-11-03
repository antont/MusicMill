import HyperCore
import SwiftUI

/// The centre deck's song as a strip of phrases (the current one highlighted), the branches out
/// of the current phrase, and the incoming phrase attached to the branch it was loaded from.
/// Clicking a branch loads it onto the other deck (`HyperSession.loadBranch`).
struct CentreGraphView: View {
    let session: HyperSession
    /// The centre phrase's song, in order.
    let sequence: [PhraseNode]
    /// Branches out of the centre's current phrase, best first.
    let branches: [Branch]

    static let boxWidth: CGFloat = 156

    var body: some View {
        if let centre = session.centreDeck, let current = centre.currentPhrase {
            VStack(spacing: 0) {
                HStack {
                    Text("Centre: deck \(centre.id == .a ? "A" : "B")").foregroundStyle(.secondary)
                    Text(current.sourceTrackName).font(.headline).lineLimit(1)
                    Spacer()
                }
                .padding(8)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        HStack(alignment: .top, spacing: 4) {
                            ForEach(sequence) { phrase in
                                column(phrase, current: current, centre: centre)
                                    .id(phrase.id)
                            }
                        }
                        .padding(16)
                    }
                    .onAppear { proxy.scrollTo(current.id, anchor: .leading) }
                    .onChange(of: current.id) { _, id in
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .leading) }
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Text("Nothing in the centre yet").font(.headline)
                Text("Start a deck and raise its fader; the louder channel becomes the centre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Columns

    @ViewBuilder
    private func column(_ phrase: PhraseNode, current: PhraseNode, centre: DeckModel) -> some View {
        let isCurrent = phrase.id == current.id
        let incoming = session.incoming
        VStack(spacing: 6) {
            PhraseBox(phrase: phrase, isCurrent: isCurrent,
                      isPast: phrase.trackIndex < current.trackIndex,
                      progress: isCurrent ? Self.progress(of: centre.positionSeconds, in: phrase) : nil)
            if isCurrent {
                ForEach(Array(branches.enumerated()), id: \.element.id) { index, branch in
                    connector
                    BranchCard(branch: branch, shortcut: index < 8 ? "⌘\(index + 1)" : nil,
                               incoming: incoming?.branch.id == branch.id ? incomingInfo(incoming!) : nil)
                        .onTapGesture { Task { await session.loadBranch(branch) } }
                }
            }
            // The incoming phrase stays attached to the phrase it branched from after the centre
            // has moved on.
            if let incoming, incoming.branch.from.id == phrase.id,
               !(isCurrent && branches.contains { $0.id == incoming.branch.id }) {
                connector
                BranchCard(branch: incoming.branch, shortcut: nil, incoming: incomingInfo(incoming))
            }
        }
        .frame(width: Self.boxWidth)
    }

    private var connector: some View {
        Rectangle().fill(Color.green.opacity(0.5)).frame(width: 2, height: 10)
    }

    private func incomingInfo(_ incoming: (deck: HyperDeckID, branch: Branch)) -> BranchCard.Incoming {
        let deck = session.decks[incoming.deck]!
        return .init(deckName: incoming.deck == .a ? "A" : "B", isPlaying: deck.isPlaying,
                     progress: Self.progress(of: deck.positionSeconds, in: incoming.branch.to))
    }

    static func progress(of seconds: Double, in phrase: PhraseNode) -> Double {
        guard phrase.duration > 0 else { return 0 }
        return min(max((seconds - (phrase.startTime ?? 0)) / phrase.duration, 0), 1)
    }

    static func segmentColor(_ type: String) -> Color {
        switch type {
        case "intro": .blue
        case "verse": .gray
        case "chorus": .purple
        case "drop": .red
        case "breakdown": .cyan
        case "outro": .orange
        default: .gray
        }
    }
}

/// One phrase of the centre song.
private struct PhraseBox: View {
    let phrase: PhraseNode
    let isCurrent: Bool
    let isPast: Bool
    /// Playhead within the phrase, for the current one.
    let progress: Double?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text("#\(phrase.sequenceNumber)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                SegmentTag(type: phrase.segmentType)
                Spacer()
                Text(phrase.timeRange)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let waveform = phrase.waveform {
                WaveformView(waveform: waveform, playbackProgress: progress ?? (isPast ? 1 : 0),
                             showPlayhead: progress != nil, height: 40)
            } else {
                ProgressView(value: progress ?? (isPast ? 1 : 0)).frame(height: 40)
            }
            Text("\(phrase.bpm) BPM · \(phrase.key ?? "?")")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(height: 80)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isCurrent ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isCurrent ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: isCurrent ? 3 : 1))
        .opacity(isPast ? 0.5 : 1)
    }
}

/// A branch into another song; drawn as incoming (with its deck's playhead) once loaded.
private struct BranchCard: View {
    struct Incoming {
        let deckName: String
        let isPlaying: Bool
        let progress: Double
    }

    let branch: Branch
    let shortcut: String?
    let incoming: Incoming?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let shortcut {
                    Text(shortcut).font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                SegmentTag(type: branch.to.segmentType)
                Spacer()
                Text("\(Int((branch.score * 100).rounded()))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green)
            }
            Text(branch.to.sourceTrackName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Text("\(branch.to.bpm) BPM · \(branch.to.key ?? "?") · \(branch.link.suggestedTransition.rawValue)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            if let incoming {
                HStack(spacing: 4) {
                    Text("\(incoming.isPlaying ? "▶" : "❚❚") deck \(incoming.deckName)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                    ProgressView(value: incoming.progress).controlSize(.mini)
                }
            }
        }
        .padding(6)
        .frame(width: CentreGraphView.boxWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(incoming != nil ? Color.green.opacity(0.2) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(incoming != nil ? Color.green : Color.gray.opacity(0.3), lineWidth: incoming != nil ? 2 : 1))
        .contentShape(Rectangle())
        .help("Load onto the other deck")
    }
}

private struct SegmentTag: View {
    let type: String

    var body: some View {
        Text(type)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(CentreGraphView.segmentColor(type).opacity(0.3))
            .foregroundStyle(CentreGraphView.segmentColor(type))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
