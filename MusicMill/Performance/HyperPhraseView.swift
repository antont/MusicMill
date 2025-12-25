import SwiftUI
import Combine

/// HyperPhraseView - Graph navigation interface for HyperMusic
///
/// Displays the current phrase in the center with navigable links to
/// compatible phrases, enabling smooth DJ-style transitions across
/// the entire music collection.
struct HyperPhraseView: View {
    @StateObject private var player = HyperPhrasePlayer()
    @StateObject private var relationshipDB = RelationshipDatabase()
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var transitionBars: Int = 2
    @State private var autoAdvance: Bool = true
    @State private var preferSameTrack: Bool = false
    @State private var masterVolume: Float = 1.0
    @State private var viewMode: ViewMode = .radial
    
    // DJ Controls
    @State private var eqLow: Float = 0
    @State private var eqMid: Float = 0
    @State private var eqHigh: Float = 0
    
    // Session/Performance tracking
    @State private var isSessionActive = false
    @State private var sessionType: RelationshipDatabase.SessionType = .practice
    @State private var lastTransition: (from: String, to: String)?
    @State private var showRatingPopup = false
    
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
        ScrollView {
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
                    sessionControls
                    Divider()
                    playbackControls
                    Divider()
                    eqControls
                    Divider()
                    transitionSettings
                    Divider()
                    ratingControls
                    Divider()
                    viewModeSelector
                }
                
                Spacer()
            }
            .padding()
        }
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
    
    // MARK: - Session Controls
    
    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session")
                    .font(.headline)
                
                Spacer()
                
                if isSessionActive {
                    Circle()
                        .fill(sessionType == .performance ? Color.red : Color.orange)
                        .frame(width: 8, height: 8)
                }
            }
            
            if isSessionActive {
                HStack {
                    Text(sessionType == .performance ? "🎧 Live" : "🎯 Practice")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button("End") {
                        endSession()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Practice") {
                        startSession(type: .practice)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button("Perform") {
                        startSession(type: .performance)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)
                }
            }
        }
    }
    
    // MARK: - EQ Controls
    
    private var eqControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EQ")
                .font(.headline)
            
            HStack(spacing: 16) {
                eqKnob(label: "LOW", value: $eqLow, color: .blue)
                eqKnob(label: "MID", value: $eqMid, color: .green)
                eqKnob(label: "HIGH", value: $eqHigh, color: .orange)
            }
            
            Button("Reset EQ") {
                eqLow = 0
                eqMid = 0
                eqHigh = 0
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
    
    private func eqKnob(label: String, value: Binding<Float>, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
            
            // Vertical slider
            Slider(value: value, in: -12...12)
                .frame(width: 60)
            
            // Value display
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
            
            // Kill button
            Button(value.wrappedValue <= -50 ? "ON" : "KILL") {
                if value.wrappedValue > -50 {
                    value.wrappedValue = -60
                } else {
                    value.wrappedValue = 0
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(value.wrappedValue <= -50 ? .red : nil)
        }
    }
    
    // MARK: - Rating Controls
    
    private var ratingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rate Transition")
                .font(.headline)
            
            if let last = lastTransition {
                HStack(spacing: 12) {
                    Button(action: { rateTransition(-1) }) {
                        Image(systemName: "hand.thumbsdown.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: { rateTransition(0) }) {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: { rateTransition(1) }) {
                        Image(systemName: "hand.thumbsup.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.bordered)
                }
                
                Text("Last: transition queued")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("Make a transition to rate it")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
        
        // Calculate playback progress for current phrase
        let progress: Double = isCurrent ? player.playbackProgress : (isPast ? 1.0 : 0.0)
        
        return VStack(spacing: 2) {
            // Top row: Sequence number + Segment type + Time
            HStack(spacing: 4) {
                Text("#\(phrase.sequenceNumber)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Text(phrase.segmentType)
                    .font(.system(size: 9))
                    .fontWeight(.medium)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(segmentColor(phrase.segmentType).opacity(0.3))
                    .foregroundColor(segmentColor(phrase.segmentType))
                    .cornerRadius(3)
                
                Spacer()
                
                Text(phrase.timeRange)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            // RGB Waveform
            if let waveform = phrase.waveform {
                WaveformView(
                    waveform: waveform,
                    playbackProgress: progress,
                    showPlayhead: isCurrent,
                    height: 40
                )
            } else {
                // Fallback: energy bar if no waveform
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(energyGradient)
                        .frame(width: 130 * CGFloat(phrase.energy), height: 40)
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 130 * CGFloat(1 - phrase.energy), height: 40)
                }
                .cornerRadius(4)
            }
            
            // Bottom row: Tempo
            Text("\(phrase.bpm) BPM")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
    
    /// Tap to queue a phrase for playback at end of current phrase
    /// 
    /// Behavior B: Switch at phrase boundary (default)
    /// - Queues the phrase, current phrase plays to end, then switches
    /// 
    /// TODO: Future option A (quick switch):
    /// - Immediate beat-aligned cut using player.triggerTransition()
    /// - Could be triggered by double-tap or modifier key
    private func transitionTo(_ phrase: PhraseNode) {
        // Log the transition if session is active
        if let current = player.currentPhrase, isSessionActive {
            logTransition(from: current, to: phrase)
        }
        
        player.queueNext(phrase)
        if !player.isPlaying {
            // Start playback if not already playing
            try? player.start()
        }
        // Note: If playing, just queue - switch happens at phrase end
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
        
        // Open relationship database
        do {
            try relationshipDB.open()
        } catch {
            print("HyperPhraseView: Failed to open relationship DB: \(error)")
        }
        
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
    
    // MARK: - Session Management
    
    private func startSession(type: RelationshipDatabase.SessionType) {
        do {
            _ = try relationshipDB.startSession(type: type)
            sessionType = type
            isSessionActive = true
        } catch {
            print("HyperPhraseView: Failed to start session: \(error)")
        }
    }
    
    private func endSession() {
        do {
            try relationshipDB.endSession(notes: nil)
            isSessionActive = false
            lastTransition = nil
        } catch {
            print("HyperPhraseView: Failed to end session: \(error)")
        }
    }
    
    // MARK: - Transition Logging
    
    private func logTransition(from: PhraseNode, to: PhraseNode) {
        guard isSessionActive else { return }
        
        do {
            let context = RelationshipDatabase.EventContext(
                eqLow: eqLow,
                eqMid: eqMid,
                eqHigh: eqHigh,
                bars: transitionBars,
                tempoDiff: Double(to.bpm - from.bpm)
            )
            
            let source: RelationshipDatabase.EventSource = sessionType == .performance ? .performance : .practice
            
            try relationshipDB.logPlayed(
                from: from.id,
                to: to.id,
                source: source,
                context: context
            )
            
            lastTransition = (from: from.id, to: to.id)
        } catch {
            print("HyperPhraseView: Failed to log transition: \(error)")
        }
    }
    
    private func rateTransition(_ rating: Int) {
        guard let last = lastTransition else { return }
        
        do {
            let source: RelationshipDatabase.EventSource = sessionType == .performance ? .performance : .practice
            try relationshipDB.logRating(from: last.from, to: last.to, rating: rating, source: source)
        } catch {
            print("HyperPhraseView: Failed to rate transition: \(error)")
        }
    }
}

// MARK: - Compact Phrase Card (for branch options)

struct CompactPhraseCard: View {
    let phrase: PhraseNode
    var isQueued: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Top row: Sequence number + Track name
            HStack(spacing: 4) {
                Text("#\(phrase.sequenceNumber)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Text(phrase.sourceTrackName)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundColor(.primary)
            }
            
            // Mini waveform
            if let waveform = phrase.waveform {
                CompactWaveformView(waveform: waveform, height: 18)
            }
            
            HStack(spacing: 4) {
                // Segment type
                Text(phrase.segmentType)
                    .font(.system(size: 8))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(segmentColor.opacity(0.3))
                    .foregroundColor(segmentColor)
                    .cornerRadius(2)
                
                Spacer()
                
                // BPM
                Text("\(phrase.bpm)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: 140, height: phrase.waveform != nil ? 55 : 45)
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

