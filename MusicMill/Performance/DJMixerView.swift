import SwiftUI
import Combine
import CoreAudio

/// Live Performance Mode - DJ Mixer interface with dual decks
struct DJMixerView: View {
    @StateObject private var viewModel = DJMixerViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with session controls
            headerView
            
            Divider()
            
            // Main mixer area
            HStack(spacing: 0) {
                // Deck A
                deckPanel(deck: viewModel.deckA, title: "A", isMain: true)
                    .frame(maxWidth: .infinity)
                
                // Center mixer controls
                mixerControls
                    .frame(width: 120)
                
                // Deck B
                deckPanel(deck: viewModel.deckB, title: "B", isMain: false)
                    .frame(maxWidth: .infinity)
            }
            
            Divider()
            
            // Branch options
            branchOptionsView
        }
        .background(Color.black)
        .onAppear {
            viewModel.loadGraph()
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("LIVE PERFORMANCE")
                .font(.headline)
                .foregroundColor(.orange)
            
            Spacer()
            
            if viewModel.isPerformanceActive {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .animation(.easeInOut(duration: 0.5).repeatForever(), value: true)
                    
                    Text("RECORDING")
                        .font(.caption.bold())
                        .foregroundColor(.red)
                    
                    Text(viewModel.sessionDuration)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Button("End") {
                        viewModel.endPerformance()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            } else {
                Button("Start Performance") {
                    viewModel.startPerformance()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            
            Spacer()
            
            // Audio output settings
            Menu {
                Section("Main Output") {
                    ForEach(viewModel.audioDevices, id: \.id) { device in
                        Button(device.displayName) {
                            viewModel.setMainOutput(device.id)
                        }
                    }
                }
                Section("Cue Output") {
                    ForEach(viewModel.audioDevices, id: \.id) { device in
                        Button(device.displayName) {
                            viewModel.setCueOutput(device.id)
                        }
                    }
                }
            } label: {
                Image(systemName: "speaker.wave.2.fill")
            }
            .menuStyle(.borderlessButton)
        }
        .padding()
        .background(Color(white: 0.1))
    }
    
    // MARK: - Deck Panel
    
    private func deckPanel(deck: Deck, title: String, isMain: Bool) -> some View {
        VStack(spacing: 16) {
            // Deck title with beat grid indicator
            HStack {
                Text("DECK \(title)")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundColor(isMain ? .orange : .cyan)
                
                Spacer()
                
                if deck.isLoaded {
                    // BPM display
                    Text("\(deck.currentPhrase?.bpm ?? 0)")
                        .font(.system(.title3, design: .monospaced).bold())
                        .foregroundColor(.white)
                    Text("BPM")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            // Waveform with beat grid
            if let phrase = deck.currentPhrase, let waveform = phrase.waveform {
                WaveformView(
                    waveform: waveform,
                    playbackProgress: deck.playbackPosition,
                    showPlayhead: true,
                    height: 80
                )
                .overlay(alignment: .leading) {
                    // Cue point marker (simplified)
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: 2)
                        .offset(x: 0)  // Would be calculated from cue point
                }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 80)
                    .overlay(
                        Text("Drop track here")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    )
            }
            
            // Track info
            if let phrase = deck.currentPhrase {
                VStack(spacing: 2) {
                    Text(phrase.sourceTrackName)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    HStack {
                        Text(phrase.segmentType.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(segmentColor(phrase.segmentType))
                            .cornerRadius(3)
                        
                        Text("#\(phrase.sequenceNumber)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        if let key = phrase.key {
                            Text(key)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            // Transport and jog
            HStack(spacing: 20) {
                // Nudge buttons
                VStack(spacing: 4) {
                    Button(action: { deck.nudge(byMs: -10) }) {
                        Image(systemName: "minus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    
                    Text("NUDGE")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    
                    Button(action: { deck.nudge(byMs: 10) }) {
                        Image(systemName: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                
                // Play/Pause
                Button(action: { deck.togglePlayPause() }) {
                    ZStack {
                        Circle()
                            .fill(deck.isPlaying ? Color.orange : Color.gray)
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundColor(.black)
                    }
                }
                .buttonStyle(.plain)
                
                // Cue button
                Button(action: { deck.stop() }) {
                    ZStack {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 40, height: 40)
                        
                        Text("CUE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.black)
                    }
                }
                .buttonStyle(.plain)
            }
            
            // EQ Controls
            HStack(spacing: 16) {
                eqControl(label: "HI", value: Binding(
                    get: { deck.eqHigh },
                    set: { deck.eqHigh = $0 }
                ), color: .red)
                
                eqControl(label: "MID", value: Binding(
                    get: { deck.eqMid },
                    set: { deck.eqMid = $0 }
                ), color: .yellow)
                
                eqControl(label: "LOW", value: Binding(
                    get: { deck.eqLow },
                    set: { deck.eqLow = $0 }
                ), color: .blue)
            }
            
            // Volume fader
            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { Double(deck.volume) },
                    set: { deck.volume = Float($0) }
                ), in: 0...1)
                .accentColor(isMain ? .orange : .cyan)
                
                Text("VOL")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(white: 0.08))
    }
    
    private func eqControl(label: String, value: Binding<Float>, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
            
            // Vertical slider representation
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                    
                    Rectangle()
                        .fill(color.opacity(0.5))
                        .frame(height: geo.size.height * CGFloat((value.wrappedValue + 12) / 24))
                }
                .cornerRadius(4)
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            let newValue = Float((1 - gesture.location.y / geo.size.height) * 24 - 12)
                            value.wrappedValue = max(-12, min(12, newValue))
                        }
                )
            }
            .frame(width: 30, height: 80)
            
            // Kill button
            Button(action: {
                if value.wrappedValue > -50 {
                    value.wrappedValue = -60
                } else {
                    value.wrappedValue = 0
                }
            }) {
                Text("KILL")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(value.wrappedValue <= -50 ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Mixer Controls
    
    private var mixerControls: some View {
        VStack(spacing: 20) {
            // Crossfader
            VStack(spacing: 4) {
                Text("CROSSFADER")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                
                Slider(value: $viewModel.crossfaderPosition, in: 0...1)
                    .rotationEffect(.degrees(270))
                    .frame(height: 100)
            }
            
            Spacer()
            
            // GO button (transition)
            Button(action: { viewModel.executeTransition() }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green)
                        .frame(width: 80, height: 40)
                    
                    Text("GO")
                        .font(.system(.headline, design: .rounded).bold())
                        .foregroundColor(.black)
                }
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canTransition)
            .opacity(viewModel.canTransition ? 1 : 0.5)
            
            Spacer()
            
            // Quick rate feedback
            HStack(spacing: 8) {
                Button(action: { viewModel.rateCurrentTransition(-1) }) {
                    Image(systemName: "hand.thumbsdown.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.rateCurrentTransition(1) }) {
                    Image(systemName: "hand.thumbsup.fill")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }
            
            Text("Rate Last")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
        .padding(.vertical)
        .background(Color(white: 0.05))
    }
    
    // MARK: - Branch Options
    
    private var branchOptionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("UP NEXT")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Cue to monitor toggle
                Toggle(isOn: $viewModel.cueToMonitor) {
                    Text("CUE")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(.cyan)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.branchOptions) { option in
                        liveBranchCard(option)
                            .onTapGesture {
                                viewModel.loadToCue(option.phrase)
                            }
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 80)
        }
        .background(Color(white: 0.05))
    }
    
    private func liveBranchCard(_ option: BranchOption) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(option.phrase.sourceTrackName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            
            HStack {
                Text(option.phrase.segmentType)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(segmentColor(option.phrase.segmentType))
                    .cornerRadius(3)
                
                Spacer()
                
                Text("\(Int(option.score * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green)
            }
            
            if let waveform = option.phrase.waveform {
                CompactWaveformView(waveform: waveform, height: 16)
            }
        }
        .padding(8)
        .frame(width: 130, height: 70)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(viewModel.deckB.currentPhrase?.id == option.phrase.id ?
                      Color.cyan.opacity(0.3) : Color(white: 0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(viewModel.deckB.currentPhrase?.id == option.phrase.id ?
                        Color.cyan : Color.clear, lineWidth: 2)
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

// MARK: - View Model

@MainActor
class DJMixerViewModel: ObservableObject {
    // Audio
    @Published var deckA = Deck(id: .a)
    @Published var deckB = Deck(id: .b)
    let audioRouter = AudioRouter()
    
    // Database
    private let database = PhraseDatabase()
    private let relationshipDB = RelationshipDatabase()
    
    // Session state
    @Published var isPerformanceActive = false
    @Published var sessionDuration = "00:00"
    private var sessionStartTime: Date?
    private var sessionTimer: Timer?
    private var lastTransition: (from: String, to: String)?
    
    // Mixer controls
    @Published var crossfaderPosition: Double = 0.5
    @Published var cueToMonitor = true
    
    // Branch options
    @Published var branchOptions: [BranchOption] = []
    
    // Audio devices
    @Published var audioDevices: [AudioDevice] = []
    
    var canTransition: Bool {
        deckA.isLoaded && deckB.isLoaded
    }
    
    // MARK: - Initialization
    
    init() {
        do {
            try relationshipDB.open()
        } catch {
            print("DJMixerViewModel: Failed to open relationship DB: \(error)")
        }
        
        audioDevices = audioRouter.availableDevices
    }
    
    // MARK: - Graph Loading
    
    func loadGraph() {
        do {
            try database.load()
            
            if let firstNode = database.currentGraph?.nodes.first {
                loadToDeckA(firstNode)
            }
        } catch {
            print("DJMixerViewModel: Failed to load graph: \(error)")
        }
    }
    
    // MARK: - Deck Loading
    
    func loadToDeckA(_ phrase: PhraseNode) {
        Task {
            do {
                try await deckA.load(phrase)
                updateBranchOptions(for: phrase)
            } catch {
                print("DJMixerViewModel: Failed to load to Deck A: \(error)")
            }
        }
    }
    
    func loadToCue(_ phrase: PhraseNode) {
        Task {
            do {
                try await deckB.load(phrase)
                
                // Auto-play cue if monitoring
                if cueToMonitor {
                    deckB.play()
                }
            } catch {
                print("DJMixerViewModel: Failed to load to Deck B: \(error)")
            }
        }
    }
    
    private func updateBranchOptions(for phrase: PhraseNode) {
        var options: [BranchOption] = []
        
        for link in phrase.links where !link.isOriginalSequence {
            guard let targetPhrase = database.getPhrase(id: link.targetId),
                  targetPhrase.sourceTrack != phrase.sourceTrack else {
                continue
            }
            
            var userRating = 0
            if let feedback = try? relationshipDB.getFeedback(from: phrase.id, to: link.targetId) {
                userRating = Int(feedback.averageRating.rounded())
            }
            
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
        
        branchOptions = options.sorted { $0.score > $1.score }
    }
    
    // MARK: - Performance Session
    
    func startPerformance() {
        do {
            _ = try relationshipDB.startSession(type: .performance)
            isPerformanceActive = true
            sessionStartTime = Date()
            
            sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateSessionDuration()
            }
            
            // Start audio engines
            try audioRouter.startMainEngine()
            try audioRouter.startCueEngine()
        } catch {
            print("DJMixerViewModel: Failed to start performance: \(error)")
        }
    }
    
    func endPerformance() {
        do {
            try relationshipDB.endSession(notes: nil)
            isPerformanceActive = false
            sessionTimer?.invalidate()
            sessionTimer = nil
            sessionDuration = "00:00"
            
            audioRouter.stopAll()
        } catch {
            print("DJMixerViewModel: Failed to end performance: \(error)")
        }
    }
    
    private func updateSessionDuration() {
        guard let start = sessionStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        sessionDuration = String(format: "%02d:%02d", minutes, seconds)
    }
    
    // MARK: - Transition Execution
    
    func executeTransition() {
        guard let phraseA = deckA.currentPhrase,
              let phraseB = deckB.currentPhrase else {
            return
        }
        
        // Log the transition
        if isPerformanceActive {
            do {
                let context = RelationshipDatabase.EventContext(
                    eqLow: deckB.eqLow,
                    eqMid: deckB.eqMid,
                    eqHigh: deckB.eqHigh,
                    bars: 4,
                    tempoDiff: Double(phraseB.bpm - phraseA.bpm)
                )
                
                try relationshipDB.logPlayed(
                    from: phraseA.id,
                    to: phraseB.id,
                    source: .performance,
                    context: context
                )
                
                lastTransition = (from: phraseA.id, to: phraseB.id)
            } catch {
                print("DJMixerViewModel: Failed to log transition: \(error)")
            }
        }
        
        // Transfer deck B to deck A
        loadToDeckA(phraseB)
        deckB.unload()
    }
    
    // MARK: - Rating
    
    func rateCurrentTransition(_ rating: Int) {
        guard let last = lastTransition else { return }
        
        do {
            try relationshipDB.logRating(
                from: last.from,
                to: last.to,
                rating: rating,
                source: .performance
            )
        } catch {
            print("DJMixerViewModel: Failed to rate transition: \(error)")
        }
    }
    
    // MARK: - Audio Routing
    
    func setMainOutput(_ deviceId: AudioDeviceID) {
        audioRouter.setOutputDevice(deviceId, for: .main)
    }
    
    func setCueOutput(_ deviceId: AudioDeviceID) {
        audioRouter.setOutputDevice(deviceId, for: .cue)
    }
}

// MARK: - Preview

#Preview {
    DJMixerView()
        .frame(width: 1100, height: 700)
}

