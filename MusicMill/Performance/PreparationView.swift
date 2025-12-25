import SwiftUI
import Combine

/// Preparation Mode - For authoring and testing transitions before performing
struct PreparationView: View {
    @StateObject private var viewModel = PreparationViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Main content
            HStack(spacing: 0) {
                // Left: Deck A
                deckView(deck: viewModel.deckA, title: "DECK A (Current)")
                    .frame(maxWidth: .infinity)
                
                Divider()
                
                // Right: Deck B (Cue/Preview)
                deckView(deck: viewModel.deckB, title: "DECK B (Preview)")
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 280)
            
            Divider()
            
            // Transition Editor
            transitionEditorView
                .frame(height: 140)
            
            Divider()
            
            // Branch Options
            branchOptionsView
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            viewModel.loadGraph()
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("PREPARATION MODE")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            if viewModel.isSessionActive {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Session Active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("End Session") {
                        viewModel.endSession()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button("Start Session") {
                    viewModel.startSession()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
    
    // MARK: - Deck View
    
    private func deckView(deck: Deck, title: String) -> some View {
        VStack(spacing: 12) {
            // Title
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Waveform
            if let phrase = deck.currentPhrase, let waveform = phrase.waveform {
                WaveformView(
                    waveform: waveform,
                    playbackProgress: deck.playbackPosition,
                    showPlayhead: true,
                    height: 60
                )
                .onTapGesture { location in
                    // Seek on tap
                    // Would need GeometryReader for proper calculation
                }
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.3))
                    .frame(height: 60)
                    .overlay(
                        Text("No phrase loaded")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    )
            }
            
            // Track info
            if let phrase = deck.currentPhrase {
                VStack(spacing: 4) {
                    Text(phrase.sourceTrackName)
                        .font(.subheadline)
                        .lineLimit(1)
                    
                    HStack {
                        Text("\(phrase.bpm) BPM")
                        if let key = phrase.key {
                            Text("•")
                            Text(key)
                        }
                        Text("•")
                        Text(phrase.segmentType)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(segmentColor(phrase.segmentType).opacity(0.2))
                            .cornerRadius(4)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            
            // Transport controls
            HStack(spacing: 16) {
                Button(action: { deck.seekToPreviousBeat() }) {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)
                
                Button(action: { deck.togglePlayPause() }) {
                    Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                
                Button(action: { deck.seekToNextBeat() }) {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
            }
            
            // EQ Controls
            HStack(spacing: 20) {
                eqKnob(label: "LOW", value: Binding(
                    get: { deck.eqLow },
                    set: { deck.eqLow = $0 }
                ))
                
                eqKnob(label: "MID", value: Binding(
                    get: { deck.eqMid },
                    set: { deck.eqMid = $0 }
                ))
                
                eqKnob(label: "HIGH", value: Binding(
                    get: { deck.eqHigh },
                    set: { deck.eqHigh = $0 }
                ))
            }
            
            Spacer()
        }
        .padding()
    }
    
    private func eqKnob(label: String, value: Binding<Float>) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            
            // Simple slider for now - could be replaced with rotary knob
            Slider(value: value, in: -12...12)
                .frame(width: 60)
            
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Transition Editor
    
    private var transitionEditorView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TRANSITION EDITOR")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 20) {
                // Technique picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Technique")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $viewModel.selectedTechnique) {
                        ForEach(RelationshipDatabase.TransitionTechnique.allCases, id: \.self) { tech in
                            Text(tech.displayName).tag(tech as RelationshipDatabase.TransitionTechnique?)
                        }
                    }
                    .frame(width: 120)
                }
                
                // Bars picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bars")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $viewModel.suggestedBars) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("4").tag(4)
                        Text("8").tag(8)
                        Text("16").tag(16)
                    }
                    .frame(width: 60)
                }
                
                // Quality rating
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 2) {
                        ForEach(-2...2, id: \.self) { rating in
                            Button(action: { viewModel.qualityRating = rating }) {
                                Image(systemName: rating <= viewModel.qualityRating ? "star.fill" : "star")
                                    .foregroundColor(rating <= viewModel.qualityRating ? .yellow : .gray)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                Spacer()
                
                // Tags
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tags")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        ForEach(viewModel.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.2))
                                .cornerRadius(4)
                        }
                        
                        Button(action: { viewModel.showTagEditor = true }) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            HStack(spacing: 12) {
                // Notes field
                TextField("Notes...", text: $viewModel.notes)
                    .textFieldStyle(.roundedBorder)
                
                Spacer()
                
                // Action buttons
                Button("Test Transition") {
                    viewModel.testTransition()
                }
                .buttonStyle(.bordered)
                
                Button("Save & Next") {
                    viewModel.saveAndNext()
                }
                .buttonStyle(.borderedProminent)
                
                Button("Skip") {
                    viewModel.skip()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
    
    // MARK: - Branch Options
    
    private var branchOptionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BRANCH OPTIONS")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("(sorted by compatibility + your ratings)")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                
                Spacer()
                
                // Filter controls could go here
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.branchOptions) { option in
                        branchCard(option)
                            .onTapGesture {
                                viewModel.loadToCue(option.phrase)
                            }
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 100)
        }
    }
    
    private func branchCard(_ option: BranchOption) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Track name
            Text(option.phrase.sourceTrackName)
                .font(.caption)
                .lineLimit(1)
            
            // Segment info
            HStack {
                Text(option.phrase.segmentType)
                    .font(.system(size: 10))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(segmentColor(option.phrase.segmentType).opacity(0.2))
                    .cornerRadius(3)
                
                Text("#\(option.phrase.sequenceNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            // Score and user rating
            HStack {
                Text("\(Int(option.score * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.green)
                
                if option.userRating != 0 {
                    HStack(spacing: 1) {
                        ForEach(0..<abs(option.userRating), id: \.self) { _ in
                            Image(systemName: option.userRating > 0 ? "star.fill" : "star.slash.fill")
                                .font(.system(size: 8))
                                .foregroundColor(option.userRating > 0 ? .yellow : .red)
                        }
                    }
                }
            }
            
            // Mini waveform
            if let waveform = option.phrase.waveform {
                CompactWaveformView(waveform: waveform, height: 20)
            }
        }
        .padding(8)
        .frame(width: 140, height: 90)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
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
}

// MARK: - Branch Option

struct BranchOption: Identifiable {
    let id: String
    let phrase: PhraseNode
    let score: Double
    let userRating: Int  // -2 to +2
}

// MARK: - View Model

@MainActor
class PreparationViewModel: ObservableObject {
    // Audio
    @Published var deckA = Deck(id: .a)
    @Published var deckB = Deck(id: .b)
    
    // Database
    private let database = PhraseDatabase()
    private let relationshipDB = RelationshipDatabase()
    
    // Session
    @Published var isSessionActive = false
    private var currentSession: RelationshipDatabase.Session?
    
    // Transition editor
    @Published var selectedTechnique: RelationshipDatabase.TransitionTechnique? = .crossfade
    @Published var suggestedBars: Int = 4
    @Published var qualityRating: Int = 0
    @Published var tags: [String] = []
    @Published var notes: String = ""
    @Published var showTagEditor = false
    
    // Branch options
    @Published var branchOptions: [BranchOption] = []
    
    // MARK: - Initialization
    
    init() {
        // Open relationship database
        do {
            try relationshipDB.open()
        } catch {
            print("PreparationViewModel: Failed to open relationship DB: \(error)")
        }
    }
    
    // MARK: - Graph Loading
    
    func loadGraph() {
        do {
            try database.load()
            
            // Load first phrase into deck A
            if let firstNode = database.currentGraph?.nodes.first {
                loadToDeckA(firstNode)
            }
        } catch {
            print("PreparationViewModel: Failed to load graph: \(error)")
        }
    }
    
    // MARK: - Deck Loading
    
    func loadToDeckA(_ phrase: PhraseNode) {
        Task {
            do {
                try await deckA.load(phrase)
                updateBranchOptions(for: phrase)
                resetTransitionEditor()
            } catch {
                print("PreparationViewModel: Failed to load to Deck A: \(error)")
            }
        }
    }
    
    func loadToCue(_ phrase: PhraseNode) {
        Task {
            do {
                try await deckB.load(phrase)
            } catch {
                print("PreparationViewModel: Failed to load to Deck B: \(error)")
            }
        }
    }
    
    // MARK: - Branch Options
    
    private func updateBranchOptions(for phrase: PhraseNode) {
        var options: [BranchOption] = []
        
        // Get links from phrase graph
        for link in phrase.links where !link.isOriginalSequence {
            guard let targetPhrase = database.getPhrase(id: link.targetId),
                  targetPhrase.sourceTrack != phrase.sourceTrack else {
                continue
            }
            
            // Get user feedback
            var userRating = 0
            if let feedback = try? relationshipDB.getFeedback(from: phrase.id, to: link.targetId) {
                userRating = Int(feedback.averageRating.rounded())
            }
            
            // Calculate adjusted score
            let adjustedScore = (try? relationshipDB.adjustedWeight(
                baseWeight: link.weight,
                from: phrase.id,
                to: link.targetId
            )) ?? link.weight
            
            options.append(BranchOption(
                id: link.targetId,
                phrase: targetPhrase,
                score: adjustedScore,
                userRating: userRating
            ))
        }
        
        // Sort by adjusted score
        branchOptions = options.sorted { $0.score > $1.score }
    }
    
    // MARK: - Session Management
    
    func startSession() {
        do {
            currentSession = try relationshipDB.startSession(type: .practice)
            isSessionActive = true
        } catch {
            print("PreparationViewModel: Failed to start session: \(error)")
        }
    }
    
    func endSession() {
        do {
            try relationshipDB.endSession(notes: nil)
            currentSession = nil
            isSessionActive = false
        } catch {
            print("PreparationViewModel: Failed to end session: \(error)")
        }
    }
    
    // MARK: - Transition Actions
    
    func testTransition() {
        // Play deck A, then crossfade to deck B
        deckA.play()
        
        // After a delay, start deck B
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.deckB.play()
        }
    }
    
    func saveAndNext() {
        guard let phraseA = deckA.currentPhrase,
              let phraseB = deckB.currentPhrase else {
            return
        }
        
        // Save transition metadata
        let transition = RelationshipDatabase.Transition(
            fromPhraseId: phraseA.id,
            toPhraseId: phraseB.id,
            notes: notes.isEmpty ? nil : notes,
            technique: selectedTechnique,
            suggestedBars: suggestedBars,
            qualityRating: qualityRating,
            tags: tags,
            properties: [:],
            createdAt: Date(),
            updatedAt: Date()
        )
        
        do {
            try relationshipDB.saveTransition(transition)
            
            // Log event
            try relationshipDB.logRating(
                from: phraseA.id,
                to: phraseB.id,
                rating: qualityRating > 0 ? 1 : (qualityRating < 0 ? -1 : 0),
                source: .manual
            )
        } catch {
            print("PreparationViewModel: Failed to save transition: \(error)")
        }
        
        // Move to next: load deck B phrase to deck A
        loadToDeckA(phraseB)
        deckB.unload()
    }
    
    func skip() {
        // Move to next branch option
        if let next = branchOptions.first(where: { $0.phrase.id != deckB.currentPhrase?.id }) {
            loadToCue(next.phrase)
        }
    }
    
    private func resetTransitionEditor() {
        selectedTechnique = .crossfade
        suggestedBars = 4
        qualityRating = 0
        tags = []
        notes = ""
    }
}

// MARK: - Preview

#Preview {
    PreparationView()
        .frame(width: 1000, height: 700)
}

