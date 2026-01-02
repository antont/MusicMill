//
//  WaveformPerformanceTests.swift
//  MusicMillTests
//
//  Automated performance tests with REAL Metal window rendering
//

import Foundation
import Testing
import QuartzCore
import MetalKit
import AppKit
@testable import MusicMill

struct WaveformPerformanceTests {
    
    // MARK: - Test Configuration
    
    static let testDuration: TimeInterval = 5.0  // 5 seconds per test
    static let warmupDuration: TimeInterval = 1.0  // 1 second warmup
    
    // MARK: - Real Metal Rendering Benchmark
    
    @Test("Real Metal Waveform Rendering Comparison")
    @MainActor
    func testRealMetalRendering() async throws {
        print(String(repeating: "=", count: 60))
        print("REAL METAL WAVEFORM RENDERING BENCHMARK")
        print(String(repeating: "=", count: 60))
        
        // Run texture-based test
        print("\n[1/2] Testing texture-based rendering...")
        let textureResults = try await runRealRenderingTest(useDirectRendering: false)
        printResults(textureResults)
        
        // Brief pause
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Run direct rendering test
        print("\n[2/2] Testing direct GPU rendering...")
        let directResults = try await runRealRenderingTest(useDirectRendering: true)
        printResults(directResults)
        
        // Print comparison
        printComparison(texture: textureResults, direct: directResults)
        
        // Write report
        writeReport(texture: textureResults, direct: directResults)
        
        // Assertions
        #expect(textureResults.frameCount > 100, "Texture mode should render >100 frames")
        #expect(directResults.frameCount > 100, "Direct mode should render >100 frames")
    }
    
    // MARK: - Real Rendering Test with Window
    
    @MainActor
    private func runRealRenderingTest(useDirectRendering: Bool) async throws -> RenderingResults {
        // Create Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        
        // Create renderer
        guard let renderer = MetalWaveformRenderer(device: device) else {
            throw TestError.rendererCreationFailed
        }
        
        // Enable GPU profiling
        renderer.enableGPUProfiling = true
        
        // Create test waveform
        let waveform = createTestWaveform(points: 500)
        let phraseId = "benchmark_\(UUID().uuidString)"
        
        // Pre-create resources
        var texture: MTLTexture? = nil
        var buffer: MTLBuffer? = nil
        
        if useDirectRendering {
            buffer = renderer.createWaveformBuffer(from: waveform, phraseId: phraseId)
        } else {
            texture = renderer.generateTexture(from: waveform, height: 120, phraseId: phraseId)
        }
        
        // Create MTKView
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 120), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        
        // Create window (required for real rendering)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1920, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Benchmark - \(useDirectRendering ? "Direct" : "Texture")"
        window.contentView = view
        window.orderFront(nil)
        
        // Create coordinator
        let coordinator = RenderCoordinator(
            renderer: renderer,
            waveform: waveform,
            texture: texture,
            buffer: buffer,
            useDirectRendering: useDirectRendering,
            warmupDuration: Self.warmupDuration,
            testDuration: Self.testDuration
        )
        view.delegate = coordinator
        
        // Wait for benchmark to complete
        await coordinator.waitForCompletion()
        
        // Get results
        var results = coordinator.getResults()
        
        // Add GPU profile log
        results.gpuProfileLog = renderer.getGPUProfileLog()
        
        // Cleanup
        view.delegate = nil
        window.close()
        
        return results
    }
    
    // MARK: - Helpers
    
    private func createTestWaveform(points: Int) -> WaveformData {
        var low: [Float] = []
        var mid: [Float] = []
        var high: [Float] = []
        
        for i in 0..<points {
            let t = Double(i) / Double(points)
            let beat = sin(t * Double.pi * 32) * 0.5 + 0.5
            let envelope = sin(t * Double.pi * 4) * 0.3 + 0.7
            
            low.append(Float(beat * envelope * 0.8 + Double.random(in: 0...0.2)))
            mid.append(Float(beat * envelope * 0.6 + Double.random(in: 0...0.3)))
            high.append(Float(beat * envelope * 0.4 + Double.random(in: 0...0.2)))
        }
        
        return WaveformData(low: low, mid: mid, high: high, points: points)
    }
    
    private func printResults(_ results: RenderingResults) {
        print("  Mode: \(results.mode)")
        print("  Frames: \(results.frameCount)")
        print("  Avg FPS: \(String(format: "%.1f", results.avgFPS))")
        print("  Min FPS: \(String(format: "%.1f", results.minFPS))")
        print("  Max FPS: \(String(format: "%.1f", results.maxFPS))")
        print("  Frame Variance: \(String(format: "%.2f", results.frameVariance)) ms")
        print("  95th Percentile: \(String(format: "%.2f", results.p95FrameTime)) ms")
        print("  Max Frame Time: \(String(format: "%.2f", results.maxFrameTime)) ms")
    }
    
    private func printComparison(texture: RenderingResults, direct: RenderingResults) {
        let fpsChange = ((direct.avgFPS - texture.avgFPS) / texture.avgFPS) * 100
        let varianceChange = texture.frameVariance > 0 ? ((texture.frameVariance - direct.frameVariance) / texture.frameVariance) * 100 : 0
        
        print("\n" + String(repeating: "=", count: 60))
        print("📊 COMPARISON")
        print(String(repeating: "=", count: 60))
        print("\n                     TEXTURE    DIRECT     DIFF")
        print("─────────────────────────────────────────────────")
        print(String(format: "Avg FPS:            %6.1f    %6.1f    %+.1f%%",
                    texture.avgFPS, direct.avgFPS, fpsChange))
        print(String(format: "Min FPS:            %6.1f    %6.1f",
                    texture.minFPS, direct.minFPS))
        print(String(format: "Frame Variance:     %6.2fms  %6.2fms  %+.1f%%",
                    texture.frameVariance, direct.frameVariance, varianceChange))
        print(String(format: "95th Percentile:    %6.2fms  %6.2fms",
                    texture.p95FrameTime, direct.p95FrameTime))
        print("─────────────────────────────────────────────────")
        
        print("\n📋 RECOMMENDATION:")
        if fpsChange > 5 {
            print("  ✅ Direct rendering is \(String(format: "%.0f%%", fpsChange)) faster")
        } else if fpsChange < -5 {
            print("  ⚠️ Texture rendering is \(String(format: "%.0f%%", -fpsChange)) faster")
        } else {
            print("  ➖ Both modes have similar FPS")
        }
        
        if varianceChange > 10 {
            print("  ✅ Direct rendering is smoother (less variance)")
        } else if varianceChange < -10 {
            print("  ⚠️ Texture rendering is smoother (less variance)")
        } else {
            print("  ➖ Both modes have similar smoothness")
        }
    }
    
    private func writeReport(texture: RenderingResults, direct: RenderingResults) {
        let fpsChange = ((direct.avgFPS - texture.avgFPS) / texture.avgFPS) * 100
        let varianceChange = texture.frameVariance > 0 ? ((texture.frameVariance - direct.frameVariance) / texture.frameVariance) * 100 : 0
        
        // Format GPU profile logs
        let textureGPU = texture.gpuProfileLog.isEmpty ? "No data" : texture.gpuProfileLog.joined(separator: "\n")
        let directGPU = direct.gpuProfileLog.isEmpty ? "No data" : direct.gpuProfileLog.joined(separator: "\n")
        
        let report = """
        ════════════════════════════════════════════════════════════
        WAVEFORM RENDERING PERFORMANCE BENCHMARK (REAL METAL)
        Generated: \(Date())
        Test Duration: \(Self.testDuration) seconds per mode
        ════════════════════════════════════════════════════════════
        
        TEXTURE-BASED RENDERING
        -----------------------
        Frames Rendered: \(texture.frameCount)
        Average FPS: \(String(format: "%.1f", texture.avgFPS))
        Min FPS: \(String(format: "%.1f", texture.minFPS))
        Max FPS: \(String(format: "%.1f", texture.maxFPS))
        Frame Variance: \(String(format: "%.2f", texture.frameVariance)) ms
        95th Percentile: \(String(format: "%.2f", texture.p95FrameTime)) ms
        99th Percentile: \(String(format: "%.2f", texture.p99FrameTime)) ms
        Max Frame Time: \(String(format: "%.2f", texture.maxFrameTime)) ms
        
        GPU TIMING:
        \(textureGPU)
        
        DIRECT GPU RENDERING
        --------------------
        Frames Rendered: \(direct.frameCount)
        Average FPS: \(String(format: "%.1f", direct.avgFPS))
        Min FPS: \(String(format: "%.1f", direct.minFPS))
        Max FPS: \(String(format: "%.1f", direct.maxFPS))
        Frame Variance: \(String(format: "%.2f", direct.frameVariance)) ms
        95th Percentile: \(String(format: "%.2f", direct.p95FrameTime)) ms
        99th Percentile: \(String(format: "%.2f", direct.p99FrameTime)) ms
        Max Frame Time: \(String(format: "%.2f", direct.maxFrameTime)) ms
        
        GPU TIMING:
        \(directGPU)
        
        COMPARISON
        ----------
        FPS Change: \(String(format: "%+.1f%%", fpsChange))
        Variance Change: \(String(format: "%+.1f%%", varianceChange)) (positive = smoother)
        
        WINNER: \(fpsChange > 0 && varianceChange >= 0 ? "DIRECT RENDERING" : fpsChange < 0 && varianceChange <= 0 ? "TEXTURE RENDERING" : "TIE - both perform similarly")
        
        ════════════════════════════════════════════════════════════
        """
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let reportURL = documentsURL.appendingPathComponent("MusicMill/waveform_benchmark_report.txt")
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("\n📄 Report saved to: \(reportURL.path)")
    }
    
    // MARK: - Types
    
    struct RenderingResults {
        let mode: String
        let frameCount: Int
        let avgFPS: Double
        let minFPS: Double
        let maxFPS: Double
        let frameVariance: Double
        let maxFrameTime: Double
        let p95FrameTime: Double
        let p99FrameTime: Double
        var gpuProfileLog: [String] = []
    }
    
    enum TestError: Error {
        case noMetalDevice
        case rendererCreationFailed
        case textureCreationFailed
    }
}

// MARK: - Render Coordinator (MTKViewDelegate)

private class RenderCoordinator: NSObject, MTKViewDelegate {
    
    private let renderer: MetalWaveformRenderer
    private let waveform: WaveformData
    private let texture: MTLTexture?
    private let buffer: MTLBuffer?
    private let useDirectRendering: Bool
    private let warmupDuration: TimeInterval
    private let testDuration: TimeInterval
    
    private var startTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var frameTimes: [Double] = []
    private var isWarmingUp = true
    private var isComplete = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var simulatedProgress: Double = 0
    
    init(renderer: MetalWaveformRenderer,
         waveform: WaveformData,
         texture: MTLTexture?,
         buffer: MTLBuffer?,
         useDirectRendering: Bool,
         warmupDuration: TimeInterval,
         testDuration: TimeInterval) {
        self.renderer = renderer
        self.waveform = waveform
        self.texture = texture
        self.buffer = buffer
        self.useDirectRendering = useDirectRendering
        self.warmupDuration = warmupDuration
        self.testDuration = testDuration
        super.init()
    }
    
    func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
    
    func getResults() -> WaveformPerformanceTests.RenderingResults {
        let sortedTimes = frameTimes.sorted()
        let avgFrameTime = frameTimes.isEmpty ? 0 : frameTimes.reduce(0, +) / Double(frameTimes.count)
        let avgFPS = avgFrameTime > 0 ? 1000.0 / avgFrameTime : 0
        let minFrameTime = sortedTimes.first ?? 0
        let maxFrameTime = sortedTimes.last ?? 0
        let minFPS = maxFrameTime > 0 ? 1000.0 / maxFrameTime : 0
        let maxFPS = minFrameTime > 0 ? 1000.0 / minFrameTime : 0
        
        let mean = avgFrameTime
        let variance = frameTimes.isEmpty ? 0 : sqrt(frameTimes.map { pow($0 - mean, 2) }.reduce(0, +) / Double(frameTimes.count))
        
        let p95Index = max(0, min(Int(Double(sortedTimes.count) * 0.95), sortedTimes.count - 1))
        let p99Index = max(0, min(Int(Double(sortedTimes.count) * 0.99), sortedTimes.count - 1))
        let p95 = sortedTimes.isEmpty ? 0 : sortedTimes[p95Index]
        let p99 = sortedTimes.isEmpty ? 0 : sortedTimes[p99Index]
        
        return WaveformPerformanceTests.RenderingResults(
            mode: useDirectRendering ? "Direct" : "Texture",
            frameCount: frameTimes.count,
            avgFPS: avgFPS,
            minFPS: minFPS,
            maxFPS: maxFPS,
            frameVariance: variance,
            maxFrameTime: maxFrameTime,
            p95FrameTime: p95,
            p99FrameTime: p99
        )
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Size won't change during benchmark
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
        let frameTime = (currentTime - lastFrameTime) * 1000.0  // Convert to ms
        lastFrameTime = currentTime
        
        // Warmup phase - render but don't record
        if isWarmingUp {
            if elapsed > warmupDuration {
                isWarmingUp = false
                startTime = currentTime  // Reset for actual measurement
                frameTimes.removeAll()
            }
        } else {
            // Measurement phase
            frameTimes.append(frameTime)
            
            if elapsed > testDuration {
                isComplete = true
                continuation?.resume()
                return
            }
        }
        
        // Simulate playback progress (scrolling waveform)
        simulatedProgress = fmod(elapsed * 0.1, 1.0)
        
        // REAL Metal rendering
        guard let drawable = view.currentDrawable else { return }
        
        let playheadColor = SIMD4<Float>(1.0, 0.5, 0.0, 1.0)
        
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
                pointCount: waveform.points,
                zoomLevel: 1.0  // Default zoom
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
