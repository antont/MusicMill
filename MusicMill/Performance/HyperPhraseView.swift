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
                Text(current.sourceTrackName)
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            
            // Main timeline area
            GeometryReader { geometry in
                let trackPhrases = player.getCurrentTrackPhrases()
                let currentIndex = trackPhrases.firstIndex(where: { $0.id == player.currentPhrase?.id }) ?? 0
                
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .top) {
                            // Track strip (horizontal timeline)
                            trackStrip(phrases: trackPhrases, currentIndex: currentIndex, geometry: geometry)
                            
                            // Branch options at each phrase boundary
                            branchOverlays(phrases: trackPhrases, currentIndex: currentIndex, geometry: geometry)
                        }
                        .frame(minWidth: geometry.size.width)
                    }
                    .onChange(of: player.currentPhrase?.id) { _, newId in
                        // Auto-scroll to current phrase
                        if let id = newId {
                            withAnimation {
                                scrollProxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }
    
    /// The horizontal track strip showing all phrases in the current song
    private func trackStrip(phrases: [PhraseNode], currentIndex: Int, geometry: GeometryProxy) -> some View {
        let phraseWidth: CGFloat = 160
        let phraseHeight: CGFloat = 80
        let stripY = geometry.size.height / 2
        
        return HStack(spacing: 0) {
            ForEach(Array(phrases.enumerated()), id: \.element.id) { index, phrase in
                let isCurrent = index == currentIndex
                let isPast = index < currentIndex
                
                // Phrase box in the strip
                VStack(spacing: 2) {
                    // Segment type badge
                    Text(phrase.segmentType)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(segmentColor(phrase.segmentType).opacity(0.3))
                        .foregroundColor(segmentColor(phrase.segmentType))
                        .cornerRadius(4)
                    
                    // Tempo
                    Text("\(phrase.bpm) BPM")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
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
                    .frame(height: 4)
                }
                .frame(width: phraseWidth - 4, height: phraseHeight - 8)
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isCurrent ? Color.accentColor.opacity(0.3) : (isPast ? Color.gray.opacity(0.1) : Color(NSColor.controlBackgroundColor)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isCurrent ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isCurrent ? 2 : 1)
                )
                .opacity(isPast ? 0.5 : 1.0)
                .id(phrase.id)
                .onTapGesture {
                    if !isCurrent {
                        transitionTo(phrase)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: phraseHeight)
        .position(x: CGFloat(phrases.count) * phraseWidth / 2 + 20, y: stripY)
    }
    
    /// Branch options that fan out from phrase boundaries
    private func branchOverlays(phrases: [PhraseNode], currentIndex: Int, geometry: GeometryProxy) -> some View {
        let phraseWidth: CGFloat = 160
        let stripY = geometry.size.height / 2
        
        return ForEach(Array(phrases.enumerated()), id: \.element.id) { index, phrase in
            // Only show branches for current and next few phrases
            if index >= currentIndex && index <= currentIndex + 2 {
                let branches = player.getBranchOptions(for: phrase, limit: 4)
                let xPos = CGFloat(index) * phraseWidth + phraseWidth + 20  // At end of phrase
                
                // Branch lines and nodes
                ForEach(Array(branches.enumerated()), id: \.element.id) { branchIndex, branchPhrase in
                    let yOffset = branchYOffset(index: branchIndex, total: branches.count)
                    let branchY = stripY + yOffset
                    
                    // Connection line
                    Path { path in
                        path.move(to: CGPoint(x: xPos - phraseWidth/2, y: stripY))
                        path.addQuadCurve(
                            to: CGPoint(x: xPos + 60, y: branchY),
                            control: CGPoint(x: xPos, y: (stripY + branchY) / 2)
                        )
                    }
                    .stroke(Color.green.opacity(0.4), lineWidth: 2)
                    
                    // Branch phrase card (compact)
                    CompactPhraseCard(phrase: branchPhrase, isQueued: player.nextPhrase?.id == branchPhrase.id)
                        .position(x: xPos + 100, y: branchY)
                        .onTapGesture {
                            transitionTo(branchPhrase)
                        }
                }
            }
        }
    }
    
    /// Calculate Y offset for branch options (spread above and below the track)
    private func branchYOffset(index: Int, total: Int) -> CGFloat {
        let spacing: CGFloat = 70
        let centerOffset = CGFloat(total - 1) / 2.0
        return (CGFloat(index) - centerOffset) * spacing
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
        VStack(alignment: .leading, spacing: 2) {
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
                    .padding(.vertical, 1)
                    .background(segmentColor.opacity(0.3))
                    .foregroundColor(segmentColor)
                    .cornerRadius(3)
                
                // BPM
                Text("\(phrase.bpm)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(6)
        .frame(width: 120)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isQueued ? Color.green : Color.green.opacity(0.3), lineWidth: isQueued ? 2 : 1)
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

