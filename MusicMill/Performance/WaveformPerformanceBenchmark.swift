//
//  WaveformPerformanceBenchmark.swift
//  MusicMill
//
//  Automated performance benchmark using real Metal rendering
//

import SwiftUI
import MetalKit
import QuartzCore

/// Automated performance benchmark for waveform rendering
/// Creates a real window with Metal rendering and measures actual frame times
class WaveformPerformanceBenchmark: ObservableObject {
    
    // MARK: - Published Results
    
    @Published var isRunning = false
    @Published var currentPhase: String = "Idle"
    @Published var textureResults: BenchmarkResults?
    @Published var directResults: BenchmarkResults?
    @Published var comparisonReport: String = ""
    
    // MARK: - Configuration
    
    var testDuration: TimeInterval = 5.0  // seconds per mode
    var warmupDuration: TimeInterval = 1.0  // warmup before measuring
    
    // MARK: - Internal State
    
    private var benchmarkWindow: NSWindow?
    private var mtkView: MTKView?
    private var renderer: MetalWaveformRenderer?
    private var coordinator: BenchmarkCoordinator?
    private var testWaveform: WaveformData?
    private var testTexture: MTLTexture?
    private var testBuffer: MTLBuffer?
    
    struct BenchmarkResults {
        let mode: String
        let frameCount: Int
        let avgFPS: Double
        let minFPS: Double
        let maxFPS: Double
        let frameVariance: Double
        let maxFrameTime: Double
        let p95FrameTime: Double  // 95th percentile
        let p99FrameTime: Double  // 99th percentile
        let textureGenCount: Int
        let totalDuration: TimeInterval
    }
    
    // MARK: - Public API
    
    /// Run the complete benchmark (both modes)
    func runFullBenchmark() {
        guard !isRunning else { return }
        isRunning = true
        textureResults = nil
        directResults = nil
        comparisonReport = ""
        
        Task { @MainActor in
            // Phase 1: Texture-based rendering
            currentPhase = "Testing Texture-Based Rendering..."
            textureResults = await runBenchmark(useDirectRendering: false)
            
            // Brief pause between tests
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            // Phase 2: Direct GPU rendering
            currentPhase = "Testing Direct GPU Rendering..."
            directResults = await runBenchmark(useDirectRendering: true)
            
            // Generate comparison report
            currentPhase = "Generating Report..."
            generateComparisonReport()
            
            currentPhase = "Complete"
            isRunning = false
        }
    }
    
    /// Run benchmark for a specific mode
    @MainActor
    private func runBenchmark(useDirectRendering: Bool) async -> BenchmarkResults? {
        // Create benchmark window
        guard createBenchmarkWindow() else {
            print("[Benchmark] Failed to create window")
            return nil
        }
        
        // Create test data
        createTestData()
        
        // Create coordinator for this run
        let coordinator = BenchmarkCoordinator(
            renderer: renderer!,
            waveform: testWaveform!,
            useDirectRendering: useDirectRendering,
            warmupDuration: warmupDuration,
            testDuration: testDuration
        )
        self.coordinator = coordinator
        mtkView?.delegate = coordinator
        
        // Wait for benchmark to complete
        await coordinator.waitForCompletion()
        
        // Collect results
        let results = coordinator.getResults()
        
        // Cleanup
        closeBenchmarkWindow()
        
        return results
    }
    
    // MARK: - Window Management
    
    @MainActor
    private func createBenchmarkWindow() -> Bool {
        // Create Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[Benchmark] No Metal device available")
            return false
        }
        
        // Create renderer
        guard let newRenderer = MetalWaveformRenderer(device: device) else {
            print("[Benchmark] Failed to create renderer")
            return false
        }
        renderer = newRenderer
        
        // Create MTKView
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 120), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        mtkView = view
        
        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1920, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Waveform Performance Benchmark"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        benchmarkWindow = window
        
        return true
    }
    
    @MainActor
    private func closeBenchmarkWindow() {
        mtkView?.delegate = nil
        mtkView = nil
        benchmarkWindow?.close()
        benchmarkWindow = nil
        coordinator = nil
        testTexture = nil
        testBuffer = nil
    }
    
    // MARK: - Test Data
    
    private func createTestData() {
        // Create realistic waveform data (500 points, simulating a phrase)
        var low: [Float] = []
        var mid: [Float] = []
        var high: [Float] = []
        
        for i in 0..<500 {
            let t = Double(i) / 500.0
            let beat = sin(t * Double.pi * 32) * 0.5 + 0.5
            let envelope = sin(t * Double.pi * 4) * 0.3 + 0.7
            
            low.append(Float(beat * envelope * 0.8 + Double.random(in: 0...0.2)))
            mid.append(Float(beat * envelope * 0.6 + Double.random(in: 0...0.3)))
            high.append(Float(beat * envelope * 0.4 + Double.random(in: 0...0.2)))
        }
        
        testWaveform = WaveformData(low: low, mid: mid, high: high, points: 500)
    }
    
    // MARK: - Report Generation
    
    private func generateComparisonReport() {
        guard let texture = textureResults, let direct = directResults else {
            comparisonReport = "Benchmark incomplete - missing results"
            return
        }
        
        let fpsChange = ((direct.avgFPS - texture.avgFPS) / texture.avgFPS) * 100
        let varianceChange = ((texture.frameVariance - direct.frameVariance) / texture.frameVariance) * 100
        let p95Change = ((texture.p95FrameTime - direct.p95FrameTime) / texture.p95FrameTime) * 100
        
        comparisonReport = """
        ════════════════════════════════════════════════════════════
        WAVEFORM RENDERING PERFORMANCE BENCHMARK
        Generated: \(Date())
        ════════════════════════════════════════════════════════════
        
        ┌─────────────────────────────────────────────────────────┐
        │  TEXTURE-BASED RENDERING                                │
        ├─────────────────────────────────────────────────────────┤
        │  Frames Rendered:  \(String(format: "%6d", texture.frameCount))                              │
        │  Average FPS:      \(String(format: "%6.1f", texture.avgFPS))                              │
        │  Min FPS:          \(String(format: "%6.1f", texture.minFPS))                              │
        │  Max FPS:          \(String(format: "%6.1f", texture.maxFPS))                              │
        │  Frame Variance:   \(String(format: "%6.2f", texture.frameVariance)) ms                         │
        │  Max Frame Time:   \(String(format: "%6.2f", texture.maxFrameTime)) ms                         │
        │  95th Percentile:  \(String(format: "%6.2f", texture.p95FrameTime)) ms                         │
        │  99th Percentile:  \(String(format: "%6.2f", texture.p99FrameTime)) ms                         │
        │  Texture Gens:     \(String(format: "%6d", texture.textureGenCount))                              │
        └─────────────────────────────────────────────────────────┘
        
        ┌─────────────────────────────────────────────────────────┐
        │  DIRECT GPU RENDERING                                   │
        ├─────────────────────────────────────────────────────────┤
        │  Frames Rendered:  \(String(format: "%6d", direct.frameCount))                              │
        │  Average FPS:      \(String(format: "%6.1f", direct.avgFPS))                              │
        │  Min FPS:          \(String(format: "%6.1f", direct.minFPS))                              │
        │  Max FPS:          \(String(format: "%6.1f", direct.maxFPS))                              │
        │  Frame Variance:   \(String(format: "%6.2f", direct.frameVariance)) ms                         │
        │  Max Frame Time:   \(String(format: "%6.2f", direct.maxFrameTime)) ms                         │
        │  95th Percentile:  \(String(format: "%6.2f", direct.p95FrameTime)) ms                         │
        │  99th Percentile:  \(String(format: "%6.2f", direct.p99FrameTime)) ms                         │
        │  Buffer Gens:      \(String(format: "%6d", direct.textureGenCount))                              │
        └─────────────────────────────────────────────────────────┘
        
        ┌─────────────────────────────────────────────────────────┐
        │  COMPARISON                                             │
        ├─────────────────────────────────────────────────────────┤
        │  FPS Change:       \(String(format: "%+6.1f", fpsChange))%                             │
        │  Variance Change:  \(String(format: "%+6.1f", varianceChange))% (+ = smoother)              │
        │  95th % Change:    \(String(format: "%+6.1f", p95Change))% (+ = faster)                │
        └─────────────────────────────────────────────────────────┘
        
        ════════════════════════════════════════════════════════════
        RECOMMENDATION
        ════════════════════════════════════════════════════════════
        
        \(fpsChange > 5 ? "✅ Direct rendering is significantly faster (\(String(format: "%.0f", fpsChange))% higher FPS)" : fpsChange < -5 ? "⚠️ Texture rendering is faster (\(String(format: "%.0f", -fpsChange))% higher FPS)" : "➖ FPS is similar between modes")
        
        \(varianceChange > 10 ? "✅ Direct rendering is smoother (\(String(format: "%.0f", varianceChange))% less variance)" : varianceChange < -10 ? "⚠️ Texture rendering is smoother (\(String(format: "%.0f", -varianceChange))% less variance)" : "➖ Smoothness is similar between modes")
        
        \(direct.maxFrameTime < texture.maxFrameTime ? "✅ Direct rendering has fewer frame spikes" : "⚠️ Texture rendering has fewer frame spikes")
        
        Overall: \(fpsChange > 0 && varianceChange > 0 ? "Use DIRECT rendering for best results" : fpsChange < 0 && varianceChange < 0 ? "Use TEXTURE rendering for best results" : "Both modes perform similarly - choose based on memory usage preference")
        
        ════════════════════════════════════════════════════════════
        """
        
        // Save to file
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let reportURL = documentsURL.appendingPathComponent("MusicMill/waveform_benchmark_report.txt")
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? comparisonReport.write(to: reportURL, atomically: true, encoding: .utf8)
        print("[Benchmark] Report saved to: \(reportURL.path)")
    }
}

// MARK: - Benchmark Coordinator (MTKViewDelegate)

private class BenchmarkCoordinator: NSObject, MTKViewDelegate {
    
    private let renderer: MetalWaveformRenderer
    private let waveform: WaveformData
    private let useDirectRendering: Bool
    private let warmupDuration: TimeInterval
    private let testDuration: TimeInterval
    
    private var startTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var frameTimes: [Double] = []
    private var isWarmingUp = true
    private var isComplete = false
    private var textureGenCount = 0
    
    private var texture: MTLTexture?
    private var buffer: MTLBuffer?
    private var continuation: CheckedContinuation<Void, Never>?
    
    private var simulatedProgress: Double = 0
    private let phraseId = "benchmark_\(UUID().uuidString)"
    
    init(renderer: MetalWaveformRenderer,
         waveform: WaveformData,
         useDirectRendering: Bool,
         warmupDuration: TimeInterval,
         testDuration: TimeInterval) {
        self.renderer = renderer
        self.waveform = waveform
        self.useDirectRendering = useDirectRendering
        self.warmupDuration = warmupDuration
        self.testDuration = testDuration
        super.init()
        
        // Pre-create resources
        if useDirectRendering {
            buffer = renderer.createWaveformBuffer(from: waveform, phraseId: phraseId)
        } else {
            texture = renderer.generateTexture(from: waveform, height: 120, phraseId: phraseId)
            textureGenCount = 1
        }
    }
    
    func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
    
    func getResults() -> WaveformPerformanceBenchmark.BenchmarkResults {
        let sortedTimes = frameTimes.sorted()
        let avgFrameTime = frameTimes.isEmpty ? 0 : frameTimes.reduce(0, +) / Double(frameTimes.count)
        let avgFPS = avgFrameTime > 0 ? 1000.0 / avgFrameTime : 0
        let minFrameTime = sortedTimes.first ?? 0
        let maxFrameTime = sortedTimes.last ?? 0
        let minFPS = maxFrameTime > 0 ? 1000.0 / maxFrameTime : 0
        let maxFPS = minFrameTime > 0 ? 1000.0 / minFrameTime : 0
        
        let mean = avgFrameTime
        let variance = frameTimes.isEmpty ? 0 : sqrt(frameTimes.map { pow($0 - mean, 2) }.reduce(0, +) / Double(frameTimes.count))
        
        let p95Index = min(Int(Double(sortedTimes.count) * 0.95), sortedTimes.count - 1)
        let p99Index = min(Int(Double(sortedTimes.count) * 0.99), sortedTimes.count - 1)
        let p95 = sortedTimes.isEmpty ? 0 : sortedTimes[max(0, p95Index)]
        let p99 = sortedTimes.isEmpty ? 0 : sortedTimes[max(0, p99Index)]
        
        return WaveformPerformanceBenchmark.BenchmarkResults(
            mode: useDirectRendering ? "Direct" : "Texture",
            frameCount: frameTimes.count,
            avgFPS: avgFPS,
            minFPS: minFPS,
            maxFPS: maxFPS,
            frameVariance: variance,
            maxFrameTime: maxFrameTime,
            p95FrameTime: p95,
            p99FrameTime: p99,
            textureGenCount: textureGenCount,
            totalDuration: testDuration
        )
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Regenerate texture if size changes (would happen in real usage)
        if !useDirectRendering {
            texture = renderer.generateTexture(from: waveform, height: size.height, phraseId: phraseId + "_\(size.height)")
            textureGenCount += 1
        }
    }
    
    func draw(in view: MTKView) {
        let currentTime = CACurrentMediaTime()
        
        // Initialize on first frame
        if startTime == 0 {
            startTime = currentTime
            lastFrameTime = currentTime
            return
        }
        
        let elapsed = currentTime - startTime
        let frameTime = (currentTime - lastFrameTime) * 1000.0  // ms
        lastFrameTime = currentTime
        
        // Warmup phase
        if isWarmingUp {
            if elapsed > warmupDuration {
                isWarmingUp = false
                startTime = currentTime  // Reset start time for actual measurement
                frameTimes.removeAll()
            }
            // Still render during warmup
        } else {
            // Measurement phase
            frameTimes.append(frameTime)
            
            if elapsed > testDuration {
                isComplete = true
                continuation?.resume()
                return
            }
        }
        
        // Simulate playback progress
        simulatedProgress = fmod(elapsed * 0.1, 1.0)  // Slow scroll for visibility
        
        // Actual rendering
        guard let drawable = view.currentDrawable else { return }
        
        let playheadColor = SIMD4<Float>(1.0, 0.5, 0.0, 1.0)  // Orange
        
        if useDirectRendering {
            renderer.renderDirectWaveform(
                to: drawable,
                currentBuffer: buffer,
                nextBuffer: nil,
                branchBuffer: nil,
                playbackProgress: simulatedProgress,
                hasBranch: false,
                viewSize: view.bounds.size,
                playheadColor: playheadColor,
                pointCount: waveform.points
            )
        } else {
            renderer.renderScrollingWaveform(
                to: drawable,
                currentTexture: texture,
                nextTexture: nil,
                branchTexture: nil,
                playbackProgress: simulatedProgress,
                hasBranch: false,
                viewSize: view.bounds.size,
                playheadColor: playheadColor
            )
        }
    }
}

