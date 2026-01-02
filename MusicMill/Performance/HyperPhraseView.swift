import SwiftUI
import Combine
import CoreAudio

/// HyperPhraseView - Graph navigation interface for HyperMusic
///
/// Displays the current phrase in the center with navigable links to
/// compatible phrases, enabling smooth DJ-style transitions across
/// the entire music collection.
///
/// Includes dual-deck DJ controls for professional mixing.
struct HyperPhraseView: View {
    @StateObject private var player = HyperPhrasePlayer()
    @StateObject private var relationshipDB = RelationshipDatabase()
    @StateObject private var deckA = Deck(id: .a)  // Main/current deck
    @StateObject private var deckB = Deck(id: .b)  // Cue/preview deck
    @StateObject private var audioRouter = AudioRouter()
    
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var transitionBars: Int = 2
    @State private var autoAdvance: Bool = true
    @State private var preferSameTrack: Bool = false
    @State private var masterVolume: Float = 1.0
    @State private var viewMode: ViewMode = .radial
    
    // Session/Performance tracking
    @State private var isSessionActive = false
    @State private var sessionType: RelationshipDatabase.SessionType = .practice
    @State private var lastTransition: (from: String, to: String)?
    
    // Cue monitoring
    @State private var cueEnabled = false
    
    // Debug/Performance UI
    @State private var useDirectRendering = false
    @State private var showPerformanceMetrics = false
    @State private var showPerformanceTest = false
    @StateObject private var performanceMonitor = WaveformPerformanceMonitor()
    
    enum ViewMode: String, CaseIterable {
        case radial = "Radial"
        case matrix = "Matrix"
        case list = "List"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top: Main output waveform (full width, scrolling with playhead)
            mainWaveformStrip
                .frame(height: 100)
            
            // EQ/Mixer strip
            eqMixerStrip
                .frame(height: 60)
            
            // Cue/Preview waveform
            cueWaveformStrip
                .frame(height: 80)
            
            Divider()
            
            // Bottom: Graph navigation + controls
            HSplitView {
                // Left panel: Controls
                controlPanel
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
                
                // Main area: Graph navigation
                mainNavigationArea
            }
        }
        .onAppear {
            loadGraph()
            setupAudio()
        }
        .onChange(of: player.currentPhrase?.id) { _, newId in
            syncDeckAWithPlayer()
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying && deckA.currentPhrase != nil && !deckA.isPlaying {
                deckA.play()
            } else if !isPlaying && deckA.isPlaying {
                deckA.pause()
            }
        }
    }
    
    // MARK: - Audio Setup
    
    private func setupAudio() {
        do {
            try audioRouter.startMainEngine()
            try audioRouter.startCueEngine()
        } catch {
            print("HyperPhraseView: Failed to start audio: \(error)")
        }
    }
    
    /// Keep Deck A in sync with the player's current phrase
    private func syncDeckAWithPlayer() {
        guard let phrase = player.currentPhrase else { return }
        
        // Only load if different phrase
        if deckA.currentPhrase?.id != phrase.id {
            Task {
                do {
                    try await deckA.load(phrase)
                    if player.isPlaying {
                        deckA.play()
                    }
                } catch {
                    print("HyperPhraseView: Failed to sync Deck A: \(error)")
                }
            }
        }
    }
    
    // MARK: - Main Waveform Strip (Full Width, Scrolling)
    
    private var mainWaveformStrip: some View {
        VStack(spacing: 0) {
            // Track info bar
            HStack {
                if let phrase = player.currentPhrase {
                    // Left: Track info
                    HStack(spacing: 8) {
                        Text("▶")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        
                        Text(phrase.sourceTrackName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        Text(phrase.segmentType)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(segmentColor(phrase.segmentType).opacity(0.3))
                            .foregroundColor(segmentColor(phrase.segmentType))
                            .cornerRadius(4)
                        
                        Text("#\(phrase.sequenceNumber)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Right: BPM and time
                    HStack(spacing: 12) {
                        Text("\(phrase.bpm)")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                        + Text(" BPM")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        
                        Text(formatTime(player.playbackProgress * (phrase.duration)))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                    }
                } else {
                    Text("No track loaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(white: 0.1))
            
            // Scrolling waveform with centered playhead
            // Shows: full original track waveform (not just phrase segment)
            // If branch loaded: splits to show continuation vs branch alternative
            ScrollingWaveformView(
                phrase: player.currentPhrase,
                playbackProgress: player.playbackProgress,
                trackPlaybackProgress: player.trackPlaybackProgress,
                nextPhrase: player.getNextInSequence(),
                branchPhrase: deckB.currentPhrase,
                color: .orange,
                useOriginalFile: true,  // Use original file waveform instead of phrase segment
                useDirectRendering: useDirectRendering,  // Use GPU direct rendering if enabled
                performanceMonitor: performanceMonitor  // Pass monitor for metrics display
            )
            .overlay(alignment: .topTrailing) {
                if showPerformanceMetrics {
                    performanceMetricsOverlay
                }
            }
        }
        .background(Color.black)
    }
    
    // MARK: - Performance Metrics Overlay
    
    private var performanceMetricsOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("FPS: \(performanceMonitor.currentFPS, specifier: "%.0f") (Avg: \(performanceMonitor.averageFPS, specifier: "%.0f"))")
                .font(.caption2)
                .foregroundColor(.white)
            Text("Frame Var: \(performanceMonitor.frameTimeVariance, specifier: "%.2f")ms")
                .font(.caption2)
                .foregroundColor(.white)
            Text("Tex Gen: \(performanceMonitor.textureGenTime, specifier: "%.2f")ms")
                .font(.caption2)
                .foregroundColor(.white)
            Text("Tex Upload: \(performanceMonitor.textureUploadTime, specifier: "%.2f")ms")
                .font(.caption2)
                .foregroundColor(.white)
            Text("Tex Gen Count: \(performanceMonitor.textureGenCount)")
                .font(.caption2)
                .foregroundColor(.white)
        }
        .padding(4)
        .background(Color.black.opacity(0.7))
        .cornerRadius(4)
        .padding(4)
    }
    
    // MARK: - EQ/Mixer Strip
    
    private var eqMixerStrip: some View {
        HStack(spacing: 0) {
            // Main deck EQ (left side)
            HStack(spacing: 16) {
                Text("MAIN")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.orange)
                    .frame(width: 35)
                
                eqControl(label: "LOW", value: Binding(
                    get: { deckA.eqLow },
                    set: { deckA.eqLow = $0 }
                ), color: .blue)
                
                eqControl(label: "MID", value: Binding(
                    get: { deckA.eqMid },
                    set: { deckA.eqMid = $0 }
                ), color: .green)
                
                eqControl(label: "HIGH", value: Binding(
                    get: { deckA.eqHigh },
                    set: { deckA.eqHigh = $0 }
                ), color: .orange)
            }
            .padding(.horizontal, 12)
            
            Spacer()
            
            // Center: GO button + status
            VStack(spacing: 4) {
                if let queued = player.nextPhrase {
                    Text("⏭ \(queued.segmentType)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.green)
                }
                
                HStack(spacing: 8) {
                    Button(action: { executeTransition() }) {
                        Text("GO")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 50, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(player.nextPhrase?.id == deckB.currentPhrase?.id ? .gray : .green)
                    .disabled(deckB.currentPhrase == nil)
                    
                    // Quick rating
                    HStack(spacing: 4) {
                        Button(action: { rateTransition(-1) }) {
                            Image(systemName: "hand.thumbsdown.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                        
                        Button(action: { rateTransition(1) }) {
                            Image(systemName: "hand.thumbsup.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.green)
                    }
                    .opacity(lastTransition != nil ? 1 : 0.3)
                }
            }
            
            Spacer()
            
            // Cue deck EQ (right side)
            HStack(spacing: 16) {
                eqControl(label: "LOW", value: Binding(
                    get: { deckB.eqLow },
                    set: { deckB.eqLow = $0 }
                ), color: .blue)
                
                eqControl(label: "MID", value: Binding(
                    get: { deckB.eqMid },
                    set: { deckB.eqMid = $0 }
                ), color: .green)
                
                eqControl(label: "HIGH", value: Binding(
                    get: { deckB.eqHigh },
                    set: { deckB.eqHigh = $0 }
                ), color: .orange)
                
                Text("CUE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.cyan)
                    .frame(width: 35)
                
                Toggle(isOn: $cueEnabled) {
                    Image(systemName: "headphones")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .tint(.cyan)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
        .background(Color(white: 0.08))
    }
    
    private func eqControl(label: String, value: Binding<Float>, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(color)
            
            Slider(value: value, in: -12...12)
                .frame(width: 50)
                .accentColor(value.wrappedValue <= -50 ? .red : color)
        }
        .onTapGesture(count: 2) {
            // Double-tap to kill/restore
            if value.wrappedValue > -50 {
                value.wrappedValue = -60
            } else {
                value.wrappedValue = 0
            }
        }
    }
    
    // MARK: - Cue Waveform Strip
    
    private var cueWaveformStrip: some View {
        VStack(spacing: 0) {
            // Track info bar
            HStack {
                if let phrase = deckB.currentPhrase {
                    HStack(spacing: 8) {
                        Text("CUE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.cyan)
                        
                        Text(phrase.sourceTrackName)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        Text(phrase.segmentType)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(segmentColor(phrase.segmentType).opacity(0.3))
                            .foregroundColor(segmentColor(phrase.segmentType))
                            .cornerRadius(3)
                        
                        Spacer()
                        
                        Text("\(phrase.bpm) BPM")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.cyan)
                        
                        // Transport
                        HStack(spacing: 8) {
                            Button(action: { deckB.seekToPreviousBeat() }) {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.white)
                            
                            Button(action: { deckB.togglePlayPause() }) {
                                Image(systemName: deckB.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.cyan)
                            
                            Button(action: { deckB.seekToNextBeat() }) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.white)
                        }
                    }
                } else {
                    Text("Click a branch option to load into CUE")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(white: 0.06))
            
            // Cue waveform
            ScrollingWaveformView(
                phrase: deckB.currentPhrase,
                playbackProgress: deckB.playbackPosition,
                color: .cyan
            )
        }
        .background(Color.black)
    }
    
    /// Execute transition: queue deck B for phrase boundary switch
    private func executeTransition() {
        guard let phraseB = deckB.currentPhrase else { return }
        
        // Log transition if session active
        if let phraseA = player.currentPhrase, isSessionActive {
            logTransition(from: phraseA, to: phraseB)
        }
        
        // Queue phrase B - will switch at phrase boundary
        player.queueNext(phraseB)
        
        // Stop cue playback
        deckB.pause()
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", mins, secs, ms)
    }
    
    // MARK: - Control Panel
    
    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("HyperMusic")
                    .font(.title2)
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
                    transitionSettings
                    Divider()
                    viewModeSelector
                    Divider()
                    debugControls
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
    
    private var debugControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug")
                .font(.headline)
            
            Toggle("Show Performance Metrics", isOn: $showPerformanceMetrics)
                .font(.caption)
            
            Toggle("Direct GPU Rendering", isOn: $useDirectRendering)
                .font(.caption)
            
            if showPerformanceMetrics {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FPS: \(performanceMonitor.currentFPS, specifier: "%.0f")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Tex Gen Count: \(performanceMonitor.textureGenCount)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Button("Open Performance Test") {
                showPerformanceTest = true
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showPerformanceTest) {
            WaveformRenderingTest()
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
    
    /// Tap to load a phrase into the cue deck (B) for preview
    /// 
    /// The phrase is loaded into deck B where you can:
    /// - Pre-listen via CUE button
    /// - Adjust EQ before transition
    /// - Hit GO when ready to transition
    private func transitionTo(_ phrase: PhraseNode) {
        // Load into deck B (cue)
        Task {
            do {
                try await deckB.load(phrase)
                // Auto-play cue if enabled
                if cueEnabled {
                    deckB.play()
                }
            } catch {
                print("HyperPhraseView: Failed to load cue: \(error)")
            }
        }
        
        // Also queue in player for auto-advance if enabled
        player.queueNext(phrase)
        
        if !player.isPlaying {
            // Start playback if not already playing
            try? player.start()
            
            // Also sync deck A with player's current phrase
            if let current = player.currentPhrase {
                Task {
                    try? await deckA.load(current)
                    deckA.play()
                }
            }
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
                    // Sync Deck A with initial phrase
                    syncDeckAWithPlayer()
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
            // Use deck B's EQ settings (the incoming track)
            let context = RelationshipDatabase.EventContext(
                eqLow: deckB.eqLow,
                eqMid: deckB.eqMid,
                eqHigh: deckB.eqHigh,
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

