import SwiftUI
import Combine
import AVFoundation

/// Dedicated RAVE neural synthesis control view
/// Auto-starts server and provides comprehensive latent space controls
struct RAVEView: View {
    @StateObject private var controller = RAVEViewController()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header with model selector and status
                headerSection
                
                Divider()
                
                // Macro controls
                macroControlsSection
                
                Divider()
                
                // Tempo control
                tempoSection
                
                Divider()
                
                // Latent dimensions (collapsible)
                latentDimensionsSection
                
                Divider()
                
                // Modulation
                modulationSection
                
                Divider()
                
                // Voice input
                micInputSection
                
                Divider()
                
                // Playback controls
                playbackSection
                
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 700)
        .onAppear {
            controller.autoStart()
        }
        .onDisappear {
            controller.stopIfPlaying()
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Text("RAVE Neural Synthesis")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            HStack(spacing: 20) {
                // Model selector
                HStack {
                    Text("Model:")
                        .font(.headline)
                    
                    Picker("Model", selection: $controller.selectedModel) {
                        ForEach(controller.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .onChange(of: controller.selectedModel) { _, newModel in
                        Task {
                            await controller.switchModel(to: newModel)
                        }
                    }
                    
                    Button(action: { controller.refreshModels() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                
                Spacer()
                
                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.statusColor)
                        .frame(width: 12, height: 12)
                    
                    Text(controller.statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // Model info
                if controller.latentDimensions > 0 {
                    Text("\(controller.latentDimensions) dimensions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
    }
    
    // MARK: - Macro Controls Section
    
    private var macroControlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Macro Controls")
                .font(.headline)
            
            HStack(spacing: 40) {
                // Energy
                VStack(spacing: 8) {
                    Text("ENERGY")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    VerticalSlider(value: $controller.energy, range: 0...1)
                        .frame(width: 60, height: 120)
                    
                    Text("\(Int(controller.energy * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                }
                
                // Texture
                VStack(spacing: 8) {
                    Text("TEXTURE")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    VerticalSlider(value: $controller.texture, range: 0...1)
                        .frame(width: 60, height: 120)
                    
                    Text("\(Int(controller.texture * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                }
                
                // Chaos
                VStack(spacing: 8) {
                    Text("CHAOS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    VerticalSlider(value: $controller.chaos, range: 0...1)
                        .frame(width: 60, height: 120)
                    
                    Text("\(Int(controller.chaos * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                }
                
                Spacer()
                
                // Quick presets
                VStack(alignment: .leading, spacing: 8) {
                    Text("Presets")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("Calm") {
                        controller.applyPreset(.calm)
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Balanced") {
                        controller.applyPreset(.balanced)
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Intense") {
                        controller.applyPreset(.intense)
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Chaotic") {
                        controller.applyPreset(.chaotic)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(12)
        }
    }
    
    // MARK: - Tempo Section
    
    private var tempoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tempo")
                    .font(.headline)
                
                Spacer()
                
                Text("\(Int(controller.tempo)) BPM")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            
            Slider(value: $controller.tempo, in: 40...200, step: 1)
            
            HStack {
                Text("40")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("120")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("200")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Latent Dimensions Section
    
    private var latentDimensionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Latent Dimensions")
                    .font(.headline)
                
                Spacer()
                
                Button(action: { controller.showLatentDimensions.toggle() }) {
                    Image(systemName: controller.showLatentDimensions ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }
            
            if controller.showLatentDimensions {
                VStack(spacing: 12) {
                    ForEach(0..<controller.latentDimensions, id: \.self) { dim in
                        HStack {
                            Text("D\(dim)")
                                .font(.caption)
                                .frame(width: 30, alignment: .leading)
                            
                            Slider(
                                value: Binding(
                                    get: { controller.getDimension(dim) },
                                    set: { controller.setDimension(dim, value: $0) }
                                ),
                                in: -3...3
                            )
                            
                            Text(String(format: "%.2f", controller.getDimension(dim)))
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                    
                    HStack {
                        Button("Reset All") {
                            controller.resetDimensions()
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Randomize") {
                            controller.randomizeDimensions()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }
    
    // MARK: - Modulation Section
    
    private var modulationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modulation")
                .font(.headline)
            
            HStack(spacing: 20) {
                // LFO Type
                VStack(alignment: .leading, spacing: 4) {
                    Text("LFO")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("LFO", selection: $controller.lfoType) {
                        Text("Off").tag(LFOType.off)
                        Text("Sine").tag(LFOType.sine)
                        Text("Triangle").tag(LFOType.triangle)
                        Text("Square").tag(LFOType.square)
                        Text("Random").tag(LFOType.random)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
                
                // LFO Rate
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Slider(value: $controller.lfoRate, in: 0.1...10)
                            .frame(width: 120)
                        Text(String(format: "%.1f Hz", controller.lfoRate))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                }
                
                // LFO Target
                VStack(alignment: .leading, spacing: 4) {
                    Text("Target")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("Target", selection: $controller.lfoTarget) {
                        Text("Energy").tag(LFOTarget.energy)
                        Text("Texture").tag(LFOTarget.texture)
                        Text("Chaos").tag(LFOTarget.chaos)
                        Text("All Dims").tag(LFOTarget.allDimensions)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
                
                // LFO Depth
                VStack(alignment: .leading, spacing: 4) {
                    Text("Depth")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Slider(value: $controller.lfoDepth, in: 0...1)
                            .frame(width: 120)
                        Text("\(Int(controller.lfoDepth * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
            .disabled(controller.lfoType == .off)
            .opacity(controller.lfoType == .off ? 0.5 : 1.0)
        }
    }
    
    // MARK: - Microphone Input Section
    
    private var micInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Voice Input")
                    .font(.headline)
                
                Spacer()
                
                // Mic toggle
                Toggle("", isOn: $controller.micEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: controller.micEnabled) { _, enabled in
                        controller.toggleMicInput(enabled: enabled)
                    }
            }
            
            // Device selection
            HStack(spacing: 12) {
                Text("Input Device:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("", selection: $controller.selectedInputDevice) {
                    ForEach(controller.availableInputDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 250)
                .onChange(of: controller.selectedInputDevice) { _, deviceId in
                    controller.selectInputDevice(id: deviceId)
                }
                
                Button(action: { controller.refreshInputDevices() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh device list")
            }
            
            VStack(spacing: 12) {
                HStack(spacing: 20) {
                    // Mic icon and status
                    HStack(spacing: 8) {
                        Image(systemName: controller.micEnabled ? "mic.fill" : "mic.slash")
                            .font(.title2)
                            .foregroundColor(controller.micEnabled ? .red : .secondary)
                        
                        Text(controller.micEnabled ? "Listening..." : "Off")
                            .foregroundColor(.secondary)
                    }
                    
                    // Level meter
                    if controller.micEnabled {
                        HStack(spacing: 4) {
                            Text("Level:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.secondary.opacity(0.2))
                                    
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(controller.micLevel > 0.8 ? Color.red : Color.green)
                                        .frame(width: geometry.size.width * CGFloat(controller.micLevel))
                                }
                            }
                            .frame(width: 100, height: 8)
                        }
                    }
                    
                    Spacer()
                }
                
                // Gain controls
                HStack(spacing: 20) {
                    // Input gain
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Input Gain")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Slider(value: $controller.micInputGain, in: 1...10)
                                .frame(width: 80)
                                .onChange(of: controller.micInputGain) { _, gain in
                                    controller.updateMicGain()
                                }
                            Text(String(format: "%.1fx", controller.micInputGain))
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 35)
                        }
                    }
                    
                    // Noise excitation (critical for RAVE response!)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Noise Excitation")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Slider(value: $controller.micNoiseExcitation, in: 0...1)
                                .frame(width: 80)
                            Text("\(Int(controller.micNoiseExcitation * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 35)
                        }
                    }
                    .help("RAVE responds better to noise. Higher = more responsive but less tonal.")
                    
                    // Output gain
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output Gain")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Slider(value: $controller.micOutputGain, in: 0.5...5)
                                .frame(width: 80)
                                .onChange(of: controller.micOutputGain) { _, gain in
                                    controller.updateMicGain()
                                }
                            Text(String(format: "%.1fx", controller.micOutputGain))
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 35)
                        }
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
            
            Text("💡 Tip: RAVE responds best to percussive sounds. Try beatboxing or making 'ts ts' sounds!")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Test Signal Generator
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Test Signal Generator")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 20) {
                    Picker("Signal", selection: $controller.testSignalType) {
                        ForEach(TestSignalType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                    .onChange(of: controller.testSignalType) { _, type in
                        controller.setTestSignal(type: type)
                    }
                    
                    if controller.testSignalType == .sine || 
                       controller.testSignalType == .lfoSine || 
                       controller.testSignalType == .square {
                        HStack {
                            Text("Freq:")
                                .font(.caption)
                            Slider(value: $controller.testSignalFreq, in: 50...1000)
                                .frame(width: 80)
                            Text("\(Int(controller.testSignalFreq))Hz")
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 50)
                        }
                    }
                    
                    if controller.testSignalType == .rhythm || 
                       controller.testSignalType == .noiseBurst {
                        HStack {
                            Text("BPM:")
                                .font(.caption)
                            Slider(value: $controller.testSignalBPM, in: 60...240)
                                .frame(width: 80)
                            Text("\(Int(controller.testSignalBPM))")
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 35)
                        }
                    }
                }
            }
        }
        .onAppear {
            controller.refreshInputDevices()
        }
    }
    
    // MARK: - Playback Section
    
    private var playbackSection: some View {
        VStack(spacing: 16) {
            // Play/Stop buttons
            HStack(spacing: 30) {
                Button(action: { controller.togglePlayback() }) {
                    HStack {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        Text(controller.isPlaying ? "Pause" : "Play")
                    }
                    .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!controller.isServerRunning)
                
                Button(action: { controller.stop() }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                    }
                    .frame(width: 100)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!controller.isPlaying)
            }
            
            // Volume
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)
                
                Slider(value: $controller.volume, in: 0...1)
                
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.secondary)
                
                Text("\(Int(controller.volume * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 40)
            }
        }
    }
}

// MARK: - Vertical Slider Component

struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let normalizedValue = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let fillHeight = height * normalizedValue
            
            ZStack(alignment: .bottom) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                
                // Fill
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor)
                    .frame(height: fillHeight)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let newValue = 1 - (gesture.location.y / height)
                        let clampedValue = max(0, min(1, newValue))
                        value = range.lowerBound + clampedValue * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
}

// MARK: - Supporting Types

enum LFOType: String, CaseIterable {
    case off, sine, triangle, square, random
}

enum LFOTarget: String, CaseIterable {
    case energy, texture, chaos, allDimensions
}

enum Preset {
    case calm, balanced, intense, chaotic
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
}

enum TestSignalType: String, CaseIterable {
    case off, sine, lfoSine, rhythm, noiseBurst, square
    
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .sine: return "Sine Wave"
        case .lfoSine: return "LFO Sine"
        case .rhythm: return "Rhythm Clicks"
        case .noiseBurst: return "Noise Bursts"
        case .square: return "Square Wave"
        }
    }
}

// MARK: - RAVE View Controller

@MainActor
class RAVEViewController: ObservableObject {
    // Model state
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = "percussion"
    @Published var latentDimensions: Int = 4
    @Published var isServerRunning: Bool = false
    @Published var isPlaying: Bool = false
    @Published var statusText: String = "Idle"
    
    // Macro controls
    @Published var energy: Double = 0.5
    @Published var texture: Double = 0.5
    @Published var chaos: Double = 0.3
    @Published var tempo: Double = 120
    @Published var volume: Double = 0.8
    
    // Latent dimensions
    @Published var showLatentDimensions: Bool = false
    @Published private var dimensions: [Float] = []
    
    // Modulation
    @Published var lfoType: LFOType = .off
    @Published var lfoRate: Double = 0.5
    @Published var lfoTarget: LFOTarget = .energy
    
    // Microphone input
    @Published var micEnabled: Bool = false
    @Published var micLevel: Double = 0
    @Published var lfoDepth: Double = 0.3
    @Published var micInputGain: Double = 3.0
    @Published var micOutputGain: Double = 2.0
    @Published var micNoiseExcitation: Double = 0.5  // RAVE needs noise to respond!
    
    // Audio input devices
    @Published var availableInputDevices: [AudioInputDevice] = []
    @Published var selectedInputDevice: String = ""
    
    // Test signal generator
    @Published var testSignalType: TestSignalType = .off
    @Published var testSignalFreq: Double = 200
    @Published var testSignalBPM: Double = 120
    
    // Internal
    private var synthesizer: RAVESynthesizer?
    private var cancellables = Set<AnyCancellable>()
    private var updateTimer: Timer?
    
    var statusColor: Color {
        if isPlaying {
            return .green
        } else if isServerRunning {
            return .yellow
        } else {
            return .gray
        }
    }
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        // Debounce control changes to avoid overwhelming the server
        Publishers.CombineLatest4($energy, $texture, $chaos, $tempo)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.sendControlUpdate()
            }
            .store(in: &cancellables)
        
        $volume
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] volume in
                self?.synthesizer?.setVolume(Float(volume))
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Lifecycle
    
    func autoStart() {
        refreshModels()
        
        Task {
            await startServer()
        }
    }
    
    func stopIfPlaying() {
        if isPlaying {
            stop()
        }
    }
    
    // MARK: - Server Management
    
    func refreshModels() {
        availableModels = RAVESynthesizer.getAvailableModels()
        if availableModels.isEmpty {
            availableModels = ["percussion", "vintage"]
        }
        if !availableModels.contains(selectedModel), let first = availableModels.first {
            selectedModel = first
        }
    }
    
    func startServer() async {
        statusText = "Starting server..."
        
        do {
            synthesizer = RAVESynthesizer(modelName: selectedModel)
            try await synthesizer?.startServer()
            
            isServerRunning = true
            statusText = "Running"
            
            // Get model info
            await fetchModelInfo()
            
        } catch {
            statusText = "Error: \(error.localizedDescription)"
            isServerRunning = false
        }
    }
    
    func switchModel(to model: String) async {
        let wasPlaying = isPlaying
        if wasPlaying {
            stop()
        }
        
        statusText = "Switching to \(model)..."
        
        do {
            try await synthesizer?.switchModel(to: model)
            selectedModel = model
            statusText = "Running"
            
            await fetchModelInfo()
            
            if wasPlaying {
                play()
            }
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }
    
    private func fetchModelInfo() async {
        // For now, use known values. TODO: Get from server
        switch selectedModel {
        case "percussion":
            latentDimensions = 4
        case "vintage":
            latentDimensions = 16
        default:
            latentDimensions = 16
        }
        
        // Initialize dimension array
        dimensions = [Float](repeating: 0, count: latentDimensions)
    }
    
    // MARK: - Playback
    
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func play() {
        guard isServerRunning, let synth = synthesizer else { return }
        
        do {
            sendControlUpdate()
            try synth.start()
            isPlaying = true
            statusText = "Playing"
            startLFOTimer()
        } catch {
            statusText = "Playback error: \(error.localizedDescription)"
        }
    }
    
    func pause() {
        synthesizer?.pause()
        isPlaying = false
        statusText = "Paused"
        stopLFOTimer()
    }
    
    func stop() {
        synthesizer?.stop()
        isPlaying = false
        statusText = isServerRunning ? "Running" : "Stopped"
        stopLFOTimer()
        
        // Also disable mic if it was on
        if micEnabled {
            toggleMicInput(enabled: false)
        }
    }
    
    // MARK: - Microphone Input
    
    func toggleMicInput(enabled: Bool) {
        guard let synth = synthesizer else {
            micEnabled = false
            return
        }
        
        if enabled {
            Task {
                do {
                    try await synth.enableMicInputAsync()
                    await MainActor.run {
                        micEnabled = true
                        statusText = "Voice Input Active"
                        
                        // Start playback if not already playing
                        if !isPlaying {
                            play()
                        }
                        
                        // Start level monitoring
                        startMicLevelMonitor()
                    }
                } catch {
                    await MainActor.run {
                        micEnabled = false
                        statusText = "Mic error: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            synth.disableMicInput()
            micEnabled = false
            micLevel = 0
            if isServerRunning {
                statusText = isPlaying ? "Playing" : "Running"
            }
        }
    }
    
    private var micLevelTimer: Timer?
    
    private func startMicLevelMonitor() {
        micLevelTimer?.invalidate()
        micLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let synth = self.synthesizer else { return }
                // Get mic level from synthesizer (0-1 range, but typical speech is 0.01-0.1)
                let rawLevel = synth.micInputLevel
                // Scale for display (multiply by ~10 to make it visible)
                self.micLevel = min(1.0, Double(rawLevel) * 10)
            }
        }
    }
    
    // MARK: - Audio Input Device Management
    
    func refreshInputDevices() {
        #if os(macOS)
        // Use AVCaptureDevice to enumerate audio input devices
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .externalUnknown, .builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        )
        
        var devices: [AudioInputDevice] = []
        let defaultDevice = AVCaptureDevice.default(for: .audio)
        
        for device in discoverySession.devices {
            devices.append(AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultDevice?.uniqueID
            ))
        }
        
        // If no devices found via discovery, try to get at least the default
        if devices.isEmpty, let defaultDev = defaultDevice {
            devices.append(AudioInputDevice(
                id: defaultDev.uniqueID,
                name: defaultDev.localizedName,
                isDefault: true
            ))
        }
        
        availableInputDevices = devices
        
        // Set selected to default if not already set
        if selectedInputDevice.isEmpty, let defaultDev = devices.first(where: { $0.isDefault }) {
            selectedInputDevice = defaultDev.id
        } else if selectedInputDevice.isEmpty, let first = devices.first {
            selectedInputDevice = first.id
        }
        
        print("RAVEViewController: Found \(devices.count) input devices")
        for device in devices {
            print("  - \(device.name) [\(device.id)] \(device.isDefault ? "(default)" : "")")
        }
        #endif
    }
    
    func selectInputDevice(id: String) {
        print("RAVEViewController: Selecting input device: \(id)")
        selectedInputDevice = id
        
        // Note: AVAudioEngine uses the system default input device.
        // To use a specific device, we'd need to use AudioUnit directly.
        // For now, we just show what's available - the user can change
        // the system default in System Settings > Sound > Input.
        
        #if os(macOS)
        // Find the device name for display
        if let device = availableInputDevices.first(where: { $0.id == id }) {
            if !device.isDefault {
                statusText = "Note: Set '\(device.name)' as system default in Sound settings"
            }
        }
        #endif
    }
    
    func updateMicGain() {
        guard let synth = synthesizer else { return }
        synth.micInputGain = Float(micInputGain)
        synth.micOutputGain = Float(micOutputGain)
        synth.micNoiseExcitation = Float(micNoiseExcitation)
    }
    
    // MARK: - Test Signal Generator
    
    func setTestSignal(type: TestSignalType) {
        guard let synth = synthesizer else { return }
        
        // Disable mic if enabling test signal
        if type != .off && micEnabled {
            toggleMicInput(enabled: false)
        }
        
        // Map our enum to synthesizer enum
        let synthType: RAVESynthesizer.TestSignalType
        switch type {
        case .off: synthType = .off
        case .sine: synthType = .sine
        case .lfoSine: synthType = .lfoSine
        case .rhythm: synthType = .rhythm
        case .noiseBurst: synthType = .noiseBurst
        case .square: synthType = .square
        }
        
        // Update parameters
        synth.testSignalFrequency = Float(testSignalFreq)
        synth.testSignalBPM = Float(testSignalBPM)
        
        // Enable/disable
        synth.enableTestSignal(type: synthType)
        
        // Start playback if not already playing
        if type != .off && !isPlaying {
            play()
        }
        
        if type != .off {
            statusText = "Test: \(type.displayName)"
        } else if isServerRunning {
            statusText = isPlaying ? "Playing" : "Running"
        }
    }
    
    // MARK: - Control Updates
    
    private func sendControlUpdate() {
        guard let synth = synthesizer else { return }
        
        // Map macro controls to parameters
        let mappedEnergy = energy
        let mappedVariation = chaos
        let tempoFactor = tempo / 120.0  // Normalize to 120 BPM base
        
        synth.setParameters(
            style: nil,
            tempo: tempo,
            energy: mappedEnergy
        )
        synth.setEnergy(Float(mappedEnergy))
        synth.setVariation(Float(mappedVariation))
        synth.setTempoFactor(Float(tempoFactor))
    }
    
    // MARK: - Dimension Control
    
    func getDimension(_ index: Int) -> Double {
        guard index < dimensions.count else { return 0 }
        return Double(dimensions[index])
    }
    
    func setDimension(_ index: Int, value: Double) {
        guard index < dimensions.count else { return }
        dimensions[index] = Float(value)
        // TODO: Send to server when dimension control is implemented
    }
    
    func resetDimensions() {
        dimensions = [Float](repeating: 0, count: latentDimensions)
    }
    
    func randomizeDimensions() {
        dimensions = (0..<latentDimensions).map { _ in Float.random(in: -2...2) }
    }
    
    // MARK: - Presets
    
    func applyPreset(_ preset: Preset) {
        withAnimation(.easeInOut(duration: 0.3)) {
            switch preset {
            case .calm:
                energy = 0.3
                texture = 0.2
                chaos = 0.1
                tempo = 80
            case .balanced:
                energy = 0.5
                texture = 0.5
                chaos = 0.3
                tempo = 120
            case .intense:
                energy = 0.8
                texture = 0.6
                chaos = 0.5
                tempo = 140
            case .chaotic:
                energy = 0.9
                texture = 0.8
                chaos = 0.9
                tempo = 160
            }
        }
    }
    
    // MARK: - LFO Modulation
    
    private func startLFOTimer() {
        guard lfoType != .off else { return }
        
        stopLFOTimer()
        
        let interval = 1.0 / 60.0  // 60 Hz update rate
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateLFO()
            }
        }
    }
    
    private func stopLFOTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    private var lfoPhase: Double = 0
    
    private func updateLFO() {
        guard lfoType != .off else { return }
        
        let dt = 1.0 / 60.0
        lfoPhase += dt * lfoRate * 2 * .pi
        if lfoPhase > 2 * .pi {
            lfoPhase -= 2 * .pi
        }
        
        let lfoValue: Double
        switch lfoType {
        case .off:
            return
        case .sine:
            lfoValue = sin(lfoPhase)
        case .triangle:
            lfoValue = 2 * abs(lfoPhase / .pi - 1) - 1
        case .square:
            lfoValue = lfoPhase < .pi ? 1 : -1
        case .random:
            lfoValue = Double.random(in: -1...1)
        }
        
        let modulation = lfoValue * lfoDepth * 0.5  // Scale modulation
        
        switch lfoTarget {
        case .energy:
            let baseEnergy = energy
            let modulated = max(0, min(1, baseEnergy + modulation))
            synthesizer?.setEnergy(Float(modulated))
        case .texture:
            // Texture maps to variation for now
            let baseTexture = texture
            let modulated = max(0, min(1, baseTexture + modulation))
            synthesizer?.setVariation(Float(modulated))
        case .chaos:
            let baseChaos = chaos
            let modulated = max(0, min(1, baseChaos + modulation))
            synthesizer?.setVariation(Float(modulated))
        case .allDimensions:
            // Apply to all dimensions
            for i in 0..<dimensions.count {
                dimensions[i] += Float(modulation)
            }
        }
    }
}

#Preview {
    RAVEView()
}

