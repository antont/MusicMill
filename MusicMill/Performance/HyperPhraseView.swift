import SwiftUI
import Combine

/// HyperPhraseView - Graph navigation interface for HyperMusic
///
/// Displays the current phrase in the center with navigable links to
/// compatible phrases, enabling smooth DJ-style transitions across
/// the entire music collection.
struct HyperPhraseView: View {
    @StateObject private var player = HyperPhrasePlayer()
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var transitionBars: Int = 2
    @State private var autoAdvance: Bool = true
    @State private var preferSameTrack: Bool = false
    @State private var masterVolume: Float = 1.0
    @State private var viewMode: ViewMode = .radial
    
    enum ViewMode: String, CaseIterable {
        case radial = "Radial"
        case matrix = "Matrix"
        case list = "List"
    }
    
    var body: some View {
        HSplitView {
            // Left panel: Controls
            controlPanel
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
            
            // Main area: Graph navigation
            mainNavigationArea
        }
        .onAppear {
            loadGraph()
        }
    }
    
    // MARK: - Control Panel
    
    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HyperMusic")
                .font(.title)
                .fontWeight(.bold)
            
            if isLoading {
                ProgressView("Loading phrase graph...")
            } else if let error = loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Error")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Build Graph") {
                        buildGraph()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                graphStats
                Divider()
                playbackControls
                Divider()
                transitionSettings
                Divider()
                viewModeSelector
            }
            
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var graphStats: some View {
        VStack(alignment: .leading, spacing: 4) {
            let stats = player.graphStats
            Text("Graph Statistics")
                .font(.headline)
            HStack {
                Label("\(stats.nodes)", systemImage: "circle.fill")
                Text("phrases")
            }
            .font(.caption)
            HStack {
                Label("\(stats.links)", systemImage: "arrow.right")
                Text("links")
            }
            .font(.caption)
            HStack {
                Label("\(stats.tracks)", systemImage: "music.note.list")
                Text("tracks")
            }
            .font(.caption)
        }
    }
    
    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback")
                .font(.headline)
            
            HStack(spacing: 16) {
                Button(action: {
                    if player.isPlaying {
                        player.stop()
                    } else {
                        try? player.start()
                    }
                }) {
                    Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderedProminent)
                .disabled(player.currentPhrase == nil)
                
                Button(action: {
                    player.triggerTransition()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
                .disabled(!player.isPlaying || player.nextPhrase == nil)
                .help("Trigger transition to next phrase")
            }
            
            // Volume slider
            HStack {
                Image(systemName: "speaker.wave.1")
                Slider(value: $masterVolume, in: 0...1)
                    .onChange(of: masterVolume) { _, newValue in
                        player.setMasterVolume(newValue)
                    }
                Image(systemName: "speaker.wave.3")
            }
            
            // Transition progress
            if player.transitionProgress > 0 && player.transitionProgress < 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transitioning...")
                        .font(.caption)
                    ProgressView(value: Double(player.transitionProgress))
                }
            }
        }
    }
    
    private var transitionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transition")
                .font(.headline)
            
            Stepper("Duration: \(transitionBars) bars", value: $transitionBars, in: 1...8)
                .onChange(of: transitionBars) { _, newValue in
                    player.setTransitionBars(newValue)
                }
            
            Toggle("Auto-advance", isOn: $autoAdvance)
                .onChange(of: autoAdvance) { _, newValue in
                    player.setAutoAdvance(newValue)
                }
            
            Toggle("Prefer same track", isOn: $preferSameTrack)
                .onChange(of: preferSameTrack) { _, newValue in
                    player.setPreferSameTrack(newValue)
                }
        }
    }
    
    private var viewModeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("View Mode")
                .font(.headline)
            
            Picker("", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }
    
    // MARK: - Main Navigation Area
    
    private var mainNavigationArea: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if loadError != nil {
                Spacer()
                Text("Build the phrase graph to start navigating")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                switch viewMode {
                case .radial:
                    radialView
                case .matrix:
                    matrixView
                case .list:
                    listView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor).opacity(0.3))
    }
    
    // MARK: - Timeline View (DJ Strip)
    
    private var radialView: some View {
        VStack(spacing: 0) {
            // Track name header
            if let current = player.currentPhrase {
                HStack {
                    Text("Now playing:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(current.sourceTrackName)
                        .font(.headline)
                }
                .padding(.vertical, 8)
            }
            
            Divider()
            
            // Main timeline with branches
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    timelineContent
                        .padding(.vertical, 20)
                }
                .onChange(of: player.currentPhrase?.id) { _, newId in
                    if let id = newId {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(id, anchor: .leading)
                        }
                    }
                }
            }
        }
    }
    
    /// The timeline content: track strip + branch options
    private var timelineContent: some View {
        let trackPhrases = player.getCurrentTrackPhrases()
        let currentIndex = trackPhrases.firstIndex(where: { $0.id == player.currentPhrase?.id }) ?? 0
        
        return VStack(spacing: 0) {
            // Upper branches area
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(trackPhrases.enumerated()), id: \.element.id) { index, phrase in
                    upperBranches(for: phrase, phraseIndex: index, currentIndex: currentIndex)
                        .frame(width: 160)
                }
            }
            .frame(height: 120)
            
            // Main track strip
            HStack(spacing: 2) {
                ForEach(Array(trackPhrases.enumerated()), id: \.element.id) { index, phrase in
                    phraseBox(phrase: phrase, index: index, currentIndex: currentIndex)
                        .id(phrase.id)
                }
            }
            .padding(.horizontal, 20)
            
            // Lower branches area
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(trackPhrases.enumerated()), id: \.element.id) { index, phrase in
                    lowerBranches(for: phrase, phraseIndex: index, currentIndex: currentIndex)
                        .frame(width: 160)
                }
            }
            .frame(height: 120)
        }
    }
    
    /// Single phrase box in the track strip
    private func phraseBox(phrase: PhraseNode, index: Int, currentIndex: Int) -> some View {
        let isCurrent = index == currentIndex
        let isPast = index < currentIndex
        
        return VStack(spacing: 3) {
            // Top row: Sequence number + Segment type
            HStack {
                Text("#\(phrase.sequenceNumber)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(phrase.segmentType)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(segmentColor(phrase.segmentType).opacity(0.3))
                    .foregroundColor(segmentColor(phrase.segmentType))
                    .cornerRadius(4)
            }
            
            // Time range
            Text(phrase.timeRange)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
            
            // Tempo
            Text("\(phrase.bpm) BPM")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            // Energy bar
            HStack(spacing: 0) {
                Rectangle()
                    .fill(energyGradient)
                    .frame(width: 100 * CGFloat(phrase.energy), height: 5)
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 100 * CGFloat(1 - phrase.energy), height: 5)
            }
            .cornerRadius(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 156, height: 80)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.25) : (isPast ? Color.gray.opacity(0.1) : Color(NSColor.controlBackgroundColor)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: isCurrent ? 3 : 1)
        )
        .opacity(isPast ? 0.5 : 1.0)
        .onTapGesture {
            if !isCurrent {
                transitionTo(phrase)
            }
        }
    }
    
    /// Upper branch options (odd-indexed branches)
    private func upperBranches(for phrase: PhraseNode, phraseIndex: Int, currentIndex: Int) -> some View {
        let showBranches = phraseIndex >= currentIndex && phraseIndex <= currentIndex + 1
        let branches = showBranches ? player.getBranchOptions(for: phrase, limit: 4) : []
        let upperBranches = branches.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
        
        return VStack(spacing: 4) {
            Spacer()
            ForEach(upperBranches, id: \.id) { branchPhrase in
                CompactPhraseCard(phrase: branchPhrase, isQueued: player.nextPhrase?.id == branchPhrase.id)
                    .onTapGesture {
                        transitionTo(branchPhrase)
                    }
            }
            
            // Connection line indicator
            if !upperBranches.isEmpty {
                Rectangle()
                    .fill(Color.green.opacity(0.5))
                    .frame(width: 2, height: 20)
            }
        }
    }
    
    /// Lower branch options (even-indexed branches)
    private func lowerBranches(for phrase: PhraseNode, phraseIndex: Int, currentIndex: Int) -> some View {
        let showBranches = phraseIndex >= currentIndex && phraseIndex <= currentIndex + 1
        let branches = showBranches ? player.getBranchOptions(for: phrase, limit: 4) : []
        let lowerBranches = branches.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }
        
        return VStack(spacing: 4) {
            // Connection line indicator
            if !lowerBranches.isEmpty {
                Rectangle()
                    .fill(Color.green.opacity(0.5))
                    .frame(width: 2, height: 20)
            }
            
            ForEach(lowerBranches, id: \.id) { branchPhrase in
                CompactPhraseCard(phrase: branchPhrase, isQueued: player.nextPhrase?.id == branchPhrase.id)
                    .onTapGesture {
                        transitionTo(branchPhrase)
                    }
            }
            Spacer()
        }
    }
    
    private func segmentColor(_ type: String) -> Color {
        switch type {
        case "intro": return .blue
        case "verse": return .gray
        case "chorus": return .purple
        case "drop": return .red
        case "breakdown": return .cyan
        case "outro": return .orange
        default: return .gray
        }
    }
    
    private var energyGradient: LinearGradient {
        LinearGradient(colors: [.green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing)
    }
    
    /// Tap to immediately transition to a phrase
    private func transitionTo(_ phrase: PhraseNode) {
        player.queueNext(phrase)
        if player.isPlaying {
            player.triggerTransition()
        } else {
            // Start playback if not already playing
            try? player.start()
        }
    }
    
    // MARK: - Matrix View
    
    private var matrixView: some View {
        VStack(spacing: 20) {
            // Higher energy row
            HStack(spacing: 16) {
                ForEach(player.getHigherEnergyPhrases(limit: 3), id: \.id) { phrase in
                    PhraseNodeView(phrase: phrase, isNext: player.nextPhrase?.id == phrase.id)
                        .onTapGesture {
                            transitionTo(phrase)
                        }
                }
            }
            
            // Middle row: Prev - Current - Next
            HStack(spacing: 24) {
                // Previous (placeholder for now)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 150, height: 100)
                    .overlay(
                        Text("← Back")
                            .foregroundColor(.secondary)
                    )
                
                // Current
                if let current = player.currentPhrase {
                    PhraseNodeView(phrase: current, isSelected: true)
                        .frame(width: 200, height: 130)
                }
                
                // Next in sequence
                if let next = player.getNextInSequence() {
                    PhraseNodeView(phrase: next, isNext: player.nextPhrase?.id == next.id)
                        .onTapGesture {
                            transitionTo(next)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 150, height: 100)
                        .overlay(
                            Text("End →")
                                .foregroundColor(.secondary)
                        )
                }
            }
            
            // Lower energy row
            HStack(spacing: 16) {
                ForEach(player.getLowerEnergyPhrases(limit: 3), id: \.id) { phrase in
                    PhraseNodeView(phrase: phrase, isNext: player.nextPhrase?.id == phrase.id)
                        .onTapGesture {
                            transitionTo(phrase)
                        }
                }
            }
        }
        .padding()
    }
    
    // MARK: - List View
    
    private var listView: some View {
        VStack(spacing: 0) {
            listViewHeader
            Divider()
            listViewContent
        }
    }
    
    @ViewBuilder
    private var listViewHeader: some View {
        if let current = player.currentPhrase {
            VStack(alignment: .leading, spacing: 8) {
                Text("Now Playing")
                    .font(.headline)
                PhraseNodeView(phrase: current, isSelected: true)
            }
            .padding()
            .background(Color.accentColor.opacity(0.1))
        }
    }
    
    private var listViewContent: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                listViewNextInSequence
                listViewAlternatives
            }
            .padding(.vertical)
        }
    }
    
    @ViewBuilder
    private var listViewNextInSequence: some View {
        if let next = player.getNextInSequence() {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next in Song")
                    .font(.caption)
                    .foregroundColor(.secondary)
                let isNext = player.nextPhrase?.id == next.id
                PhraseNodeView(phrase: next, isNext: isNext)
                    .onTapGesture {
                        transitionTo(next)
                    }
            }
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private var listViewAlternatives: some View {
        if !player.alternativePhrases.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Alternatives")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(player.alternativePhrases, id: \.id) { phrase in
                    alternativeRow(phrase: phrase)
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func alternativeRow(phrase: PhraseNode) -> some View {
        let isNext = player.nextPhrase?.id == phrase.id
        let link = player.availableLinks.first(where: { $0.targetId == phrase.id })
        
        return HStack {
            PhraseNodeView(phrase: phrase, isNext: isNext)
            
            if let link = link {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(link.weight * 100))%")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text(link.suggestedTransition.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onTapGesture {
            transitionTo(phrase)
        }
    }
    
    // MARK: - Helpers
    
    private func loadGraph() {
        isLoading = true
        loadError = nil
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try player.loadGraph()
                DispatchQueue.main.async {
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    loadError = error.localizedDescription
                }
            }
        }
    }
    
    private func buildGraph() {
        // TODO: Run build_phrase_graph.py script
        loadError = "Please run: python scripts/build_phrase_graph.py path/to/librosa_analysis.json"
    }
}

// MARK: - Compact Phrase Card (for branch options)

struct CompactPhraseCard: View {
    let phrase: PhraseNode
    var isQueued: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Track name (truncated)
            Text(phrase.sourceTrackName)
                .font(.caption2)
                .lineLimit(1)
                .foregroundColor(.primary)
            
            HStack(spacing: 4) {
                // Segment type
                Text(phrase.segmentType)
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(segmentColor.opacity(0.3))
                    .foregroundColor(segmentColor)
                    .cornerRadius(3)
                
                Spacer()
                
                // BPM
                Text("\(phrase.bpm)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 140)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isQueued ? Color.green : Color.green.opacity(0.4), lineWidth: isQueued ? 2 : 1)
        )
    }
    
    private var segmentColor: Color {
        switch phrase.segmentType {
        case "intro": return .blue
        case "verse": return .gray
        case "chorus": return .purple
        case "drop": return .red
        case "breakdown": return .cyan
        case "outro": return .orange
        default: return .gray
        }
    }
}

// MARK: - Phrase Node View

struct PhraseNodeView: View {
    let phrase: PhraseNode
    var isSelected: Bool = false
    var isNext: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Track name
            Text(phrase.sourceTrackName)
                .font(.caption)
                .lineLimit(1)
            
            // Segment info
            HStack {
                Text(phrase.segmentType)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(segmentColor.opacity(0.2))
                    .foregroundColor(segmentColor)
                    .cornerRadius(4)
                
                Spacer()
                
                Text("\(phrase.bpm) BPM")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Energy bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.3))
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(energyGradient)
                        .frame(width: geo.size.width * CGFloat(phrase.energy))
                }
            }
            .frame(height: 6)
            
            // Key
            if let key = phrase.key {
                Text("Key: \(key)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(minWidth: 140, maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isNext ? Color.green : (isSelected ? Color.accentColor : Color.clear), lineWidth: 2)
        )
    }
    
    private var segmentColor: Color {
        switch phrase.segmentType {
        case "intro": return .blue
        case "verse": return .gray
        case "chorus": return .purple
        case "drop": return .red
        case "breakdown": return .cyan
        case "outro": return .orange
        default: return .gray
        }
    }
    
    private var energyGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .orange, .red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Preview

#Preview {
    HyperPhraseView()
        .frame(width: 1000, height: 700)
}

