import SwiftUI
import Combine

/// Test harness for waveform rendering performance
/// Runs continuous playback simulation and logs detailed metrics
struct WaveformRenderingTest: View {
    @StateObject private var testRunner = WaveformTestRunner()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Waveform Rendering Performance Test")
                .font(.title)
            
            // Test controls
            HStack(spacing: 20) {
                Button(testRunner.isRunning ? "Stop Test" : "Start Test") {
                    if testRunner.isRunning {
                        testRunner.stopTest()
                    } else {
                        testRunner.startTest()
                    }
                }
                .buttonStyle(.borderedProminent)
                
                Toggle("Direct Rendering", isOn: $testRunner.useDirectRendering)
                    .toggleStyle(.switch)
                
                Button("Reset Stats") {
                    testRunner.resetStats()
                }
            }
            .padding()
            
            // Waveform display
            if let phrase = testRunner.testPhrase {
                ScrollingWaveformView(
                    phrase: phrase,
                    playbackProgress: testRunner.simulatedProgress,
                    trackPlaybackProgress: testRunner.simulatedProgress,
                    color: .orange,
                    useOriginalFile: false,
                    useDirectRendering: testRunner.useDirectRendering,
                    performanceMonitor: testRunner.monitor
                )
                .frame(height: 120)
                .border(Color.gray.opacity(0.3))
            } else {
                Text("No test phrase loaded")
                    .foregroundColor(.secondary)
                    .frame(height: 120)
            }
            
            Divider()
            
            // Live metrics
            VStack(alignment: .leading, spacing: 8) {
                Text("Live Metrics")
                    .font(.headline)
                
                HStack(spacing: 40) {
                    MetricView(label: "Current FPS", value: String(format: "%.1f", testRunner.monitor.currentFPS))
                    MetricView(label: "Average FPS", value: String(format: "%.1f", testRunner.monitor.averageFPS))
                    MetricView(label: "Min FPS", value: String(format: "%.1f", testRunner.monitor.minFPS))
                    MetricView(label: "Max FPS", value: String(format: "%.1f", testRunner.monitor.maxFPS))
                }
                
                HStack(spacing: 40) {
                    MetricView(label: "Frame Variance", value: String(format: "%.2f ms", testRunner.monitor.frameTimeVariance))
                    MetricView(label: "Max Frame Time", value: String(format: "%.2f ms", testRunner.monitor.frameTimeMax))
                    MetricView(label: "Tex Gen Time", value: String(format: "%.2f ms", testRunner.monitor.textureGenTime))
                    MetricView(label: "Tex Gen Count", value: "\(testRunner.monitor.textureGenCount)")
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            Divider()
            
            // Test results log
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Test Log")
                        .font(.headline)
                    Spacer()
                    Button("Clear Log") {
                        testRunner.clearLog()
                    }
                    .buttonStyle(.bordered)
                    Button("Export Results") {
                        testRunner.exportResults()
                    }
                    .buttonStyle(.bordered)
                }
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(testRunner.logEntries, id: \.self) { entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .padding(8)
                .background(Color.black.opacity(0.05))
                .cornerRadius(4)
            }
            .padding()
            
            Spacer()
        }
        .padding()
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            testRunner.loadTestPhrase()
        }
    }
}

struct MetricView: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
        }
    }
}

/// Test runner that simulates playback and collects metrics
class WaveformTestRunner: ObservableObject {
    @Published var isRunning = false
    @Published var useDirectRendering = false
    @Published var simulatedProgress: Double = 0.0
    @Published var testPhrase: PhraseNode?
    @Published var logEntries: [String] = []
    
    let monitor = WaveformPerformanceMonitor()
    
    private var progressTimer: Timer?
    private var metricsTimer: Timer?
    private var testStartTime: Date?
    private var testDuration: TimeInterval = 0
    
    // Collected metrics for comparison
    private var textureRenderingResults: TestResults?
    private var directRenderingResults: TestResults?
    
    struct TestResults {
        let mode: String
        let duration: TimeInterval
        let avgFPS: Double
        let minFPS: Double
        let maxFPS: Double
        let frameVariance: Double
        let maxFrameTime: Double
        let textureGenCount: Int
        let textureGenTime: Double
    }
    
    func loadTestPhrase() {
        // Create a test phrase with synthetic waveform data
        let numPoints = 500
        var low: [Float] = []
        var mid: [Float] = []
        var high: [Float] = []
        
        // Generate realistic-looking waveform data
        for i in 0..<numPoints {
            let t = Double(i) / Double(numPoints)
            // Simulate beat pattern with varying intensity
            let beat = sin(t * Double.pi * 32) * 0.5 + 0.5
            let envelope = sin(t * Double.pi * 4) * 0.3 + 0.7
            
            low.append(Float(beat * envelope * 0.8 + Double.random(in: 0...0.2)))
            mid.append(Float(beat * envelope * 0.6 + Double.random(in: 0...0.3)))
            high.append(Float(beat * envelope * 0.4 + Double.random(in: 0...0.2)))
        }
        
        let waveform = WaveformData(
            low: low,
            mid: mid,
            high: high,
            points: numPoints
        )
        
        testPhrase = PhraseNode(
            id: "test_phrase_\(UUID().uuidString)",
            sourceTrack: "/test/path/test_track.mp3",
            sourceTrackName: "Performance Test Track",
            trackIndex: 0,
            audioFile: "",
            tempo: 128.0,
            key: "Am",
            energy: 0.75,
            spectralCentroid: 2500,
            segmentType: "test",
            duration: 30,
            startTime: 0,
            endTime: 30,
            beats: [],
            downbeats: [],
            waveform: waveform,
            links: []
        )
        
        log("Test phrase loaded: \(numPoints) waveform points")
    }
    
    func startTest() {
        guard !isRunning else { return }
        
        isRunning = true
        testStartTime = Date()
        simulatedProgress = 0.0
        monitor.reset()
        
        let mode = useDirectRendering ? "Direct Rendering" : "Texture-Based"
        log("=== Starting test: \(mode) ===")
        
        // Progress simulation timer (simulates playback at ~30 second duration)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.simulatedProgress += 1.0 / (120.0 * 30.0) // 30 seconds at 120fps
            if self.simulatedProgress >= 1.0 {
                self.simulatedProgress = 0.0
                self.log("Progress loop completed")
            }
        }
        
        // Metrics logging timer (every 2 seconds)
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.logCurrentMetrics()
        }
    }
    
    func stopTest() {
        guard isRunning else { return }
        
        progressTimer?.invalidate()
        progressTimer = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
        
        if let startTime = testStartTime {
            testDuration = Date().timeIntervalSince(startTime)
        }
        
        // Capture final results
        let results = TestResults(
            mode: useDirectRendering ? "Direct" : "Texture",
            duration: testDuration,
            avgFPS: monitor.averageFPS,
            minFPS: monitor.minFPS,
            maxFPS: monitor.maxFPS,
            frameVariance: monitor.frameTimeVariance,
            maxFrameTime: monitor.frameTimeMax,
            textureGenCount: monitor.textureGenCount,
            textureGenTime: monitor.textureGenTime
        )
        
        if useDirectRendering {
            directRenderingResults = results
        } else {
            textureRenderingResults = results
        }
        
        log("=== Test completed: \(results.mode) ===")
        log("Duration: \(String(format: "%.1f", testDuration))s")
        log("Avg FPS: \(String(format: "%.1f", results.avgFPS))")
        log("Min/Max FPS: \(String(format: "%.1f", results.minFPS)) / \(String(format: "%.1f", results.maxFPS))")
        log("Frame Variance: \(String(format: "%.3f", results.frameVariance))ms")
        log("Max Frame Time: \(String(format: "%.2f", results.maxFrameTime))ms")
        log("Texture Gens: \(results.textureGenCount)")
        
        // Compare if both results available
        if let texture = textureRenderingResults, let direct = directRenderingResults {
            log("")
            log("=== COMPARISON ===")
            log("Avg FPS: Texture=\(String(format: "%.1f", texture.avgFPS)) vs Direct=\(String(format: "%.1f", direct.avgFPS))")
            log("Min FPS: Texture=\(String(format: "%.1f", texture.minFPS)) vs Direct=\(String(format: "%.1f", direct.minFPS))")
            log("Frame Variance: Texture=\(String(format: "%.3f", texture.frameVariance)) vs Direct=\(String(format: "%.3f", direct.frameVariance))")
            log("Texture Gens: \(texture.textureGenCount) vs \(direct.textureGenCount)")
            
            let fpsImprovement = ((direct.avgFPS - texture.avgFPS) / texture.avgFPS) * 100
            let varianceImprovement = ((texture.frameVariance - direct.frameVariance) / texture.frameVariance) * 100
            log("")
            log("FPS Change: \(String(format: "%+.1f", fpsImprovement))%")
            log("Variance Change: \(String(format: "%+.1f", varianceImprovement))% (lower is better)")
        }
        
        isRunning = false
    }
    
    func resetStats() {
        monitor.reset()
        textureRenderingResults = nil
        directRenderingResults = nil
        log("Stats reset")
    }
    
    func clearLog() {
        logEntries.removeAll()
    }
    
    func exportResults() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        
        let content = logEntries.joined(separator: "\n")
        
        // Copy to clipboard for now
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        log("Results copied to clipboard")
    }
    
    private func logCurrentMetrics() {
        let mode = useDirectRendering ? "Direct" : "Texture"
        log("[\(mode)] FPS: \(String(format: "%.1f", monitor.currentFPS)) (avg: \(String(format: "%.1f", monitor.averageFPS))), Var: \(String(format: "%.2f", monitor.frameTimeVariance))ms")
    }
    
    private func log(_ message: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        
        DispatchQueue.main.async {
            self.logEntries.append(entry)
            // Keep log size manageable
            if self.logEntries.count > 200 {
                self.logEntries.removeFirst(50)
            }
        }
        
        #if DEBUG
        print(entry)
        #endif
    }
}

#Preview {
    WaveformRenderingTest()
}

