import Foundation
import Combine
import QuartzCore

/// Performance monitoring for waveform rendering
/// Tracks frame rate, texture generation time, upload time, and scrolling smoothness
class WaveformPerformanceMonitor: ObservableObject {
    
    // MARK: - Published Metrics
    
    @Published private(set) var currentFPS: Double = 0.0
    @Published private(set) var averageFPS: Double = 0.0
    @Published private(set) var minFPS: Double = 120.0
    @Published private(set) var maxFPS: Double = 0.0
    
    @Published private(set) var textureGenTime: Double = 0.0  // milliseconds
    @Published private(set) var textureUploadTime: Double = 0.0  // milliseconds
    @Published private(set) var textureGenCount: Int = 0
    
    @Published private(set) var frameTimeVariance: Double = 0.0  // milliseconds (stutter indicator)
    @Published private(set) var frameTimeMax: Double = 0.0  // milliseconds
    
    @Published private(set) var memoryUsage: Int64 = 0  // bytes
    
    // MARK: - Internal State
    
    private var frameTimes: [Double] = []  // milliseconds
    private let frameTimeHistorySize = 120  // 1 second at 120fps
    
    private var textureGenTimes: [Double] = []
    private var textureUploadTimes: [Double] = []
    private let timingHistorySize = 60  // Keep last 60 measurements
    
    private var lastFrameTime: CFTimeInterval = 0
    private var frameCount: Int = 0
    private var fpsSum: Double = 0.0
    
    private let updateInterval: TimeInterval = 1.0  // Update published values every second
    private var lastUpdateTime: CFTimeInterval = 0
    
    // MARK: - Initialization
    
    init() {
        lastFrameTime = CACurrentMediaTime()
        lastUpdateTime = CACurrentMediaTime()
    }
    
    // MARK: - Frame Rate Monitoring
    
    /// Record a frame render (called from render loop, may be any thread)
    func recordFrame() {
        let currentTime = CACurrentMediaTime()
        
        if lastFrameTime > 0 {
            let frameTime = (currentTime - lastFrameTime) * 1000.0  // Convert to milliseconds
            let fps = 1000.0 / frameTime
            
            // Update frame time history
            frameTimes.append(frameTime)
            if frameTimes.count > frameTimeHistorySize {
                frameTimes.removeFirst()
            }
            
            // Calculate variance (stutter indicator)
            var newVariance: Double = 0
            var newMaxFrameTime: Double = 0
            if frameTimes.count >= 2 {
                let mean = frameTimes.reduce(0, +) / Double(frameTimes.count)
                newVariance = frameTimes.map { pow($0 - mean, 2) }.reduce(0, +) / Double(frameTimes.count)
                newMaxFrameTime = frameTimes.max() ?? 0.0
            }
            
            // Update FPS statistics
            frameCount += 1
            fpsSum += fps
            
            // Update @Published properties on main thread for thread safety
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentFPS = fps
                self.frameTimeVariance = newVariance
                self.frameTimeMax = newMaxFrameTime
                if fps < self.minFPS {
                    self.minFPS = fps
                }
                if fps > self.maxFPS {
                    self.maxFPS = fps
                }
            }
        }
        
        lastFrameTime = currentTime
        
        // Update published values periodically
        if currentTime - lastUpdateTime >= updateInterval {
            updatePublishedMetrics()
            lastUpdateTime = currentTime
        }
    }
    
    private func updatePublishedMetrics() {
        // Calculate values locally first
        let newAverageFPS = frameCount > 0 ? fpsSum / Double(frameCount) : 0
        let newTextureGenTime = !textureGenTimes.isEmpty ? textureGenTimes.reduce(0, +) / Double(textureGenTimes.count) : 0
        let newTextureUploadTime = !textureUploadTimes.isEmpty ? textureUploadTimes.reduce(0, +) / Double(textureUploadTimes.count) : 0
        
        // Update @Published properties on main thread for thread safety
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.averageFPS = newAverageFPS
            self.textureGenTime = newTextureGenTime
            self.textureUploadTime = newTextureUploadTime
        }
    }
    
    // MARK: - Texture Generation Timing
    
    /// Record texture generation time (called from background thread)
    func recordTextureGeneration(duration: TimeInterval) {
        let durationMs = duration * 1000.0  // Convert to milliseconds
        textureGenTimes.append(durationMs)
        if textureGenTimes.count > timingHistorySize {
            textureGenTimes.removeFirst()
        }
        DispatchQueue.main.async { [weak self] in
            self?.textureGenCount += 1
        }
    }
    
    /// Record texture upload time (called from background thread)
    func recordTextureUpload(duration: TimeInterval) {
        let durationMs = duration * 1000.0  // Convert to milliseconds
        textureUploadTimes.append(durationMs)
        if textureUploadTimes.count > timingHistorySize {
            textureUploadTimes.removeFirst()
        }
    }
    
    // MARK: - Memory Usage
    
    /// Update memory usage estimate (thread-safe)
    func updateMemoryUsage(textureCount: Int, averageTextureSize: Int64) {
        let newMemory = Int64(textureCount) * averageTextureSize
        DispatchQueue.main.async { [weak self] in
            self?.memoryUsage = newMemory
        }
    }
    
    // MARK: - Reset
    
    /// Reset all metrics (must be called from main thread)
    func reset() {
        // Ensure we're on main thread for @Published updates
        if Thread.isMainThread {
            performReset()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performReset()
            }
        }
    }
    
    private func performReset() {
        currentFPS = 0.0
        averageFPS = 0.0
        minFPS = 120.0
        maxFPS = 0.0
        textureGenTime = 0.0
        textureUploadTime = 0.0
        textureGenCount = 0
        frameTimeVariance = 0.0
        frameTimeMax = 0.0
        memoryUsage = 0
        
        frameTimes.removeAll()
        textureGenTimes.removeAll()
        textureUploadTimes.removeAll()
        
        frameCount = 0
        fpsSum = 0.0
        lastFrameTime = CACurrentMediaTime()
        lastUpdateTime = CACurrentMediaTime()
    }
    
    // MARK: - Debug String
    
    /// Get formatted debug string with all metrics
    func debugString() -> String {
        return """
        FPS: \(String(format: "%.1f", currentFPS)) (avg: \(String(format: "%.1f", averageFPS)), min: \(String(format: "%.1f", minFPS)), max: \(String(format: "%.1f", maxFPS)))
        Texture Gen: \(String(format: "%.2f", textureGenTime))ms (count: \(textureGenCount))
        Texture Upload: \(String(format: "%.2f", textureUploadTime))ms
        Frame Variance: \(String(format: "%.2f", frameTimeVariance))ms (max: \(String(format: "%.2f", frameTimeMax))ms)
        Memory: \(formatBytes(memoryUsage))
        """
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
}

