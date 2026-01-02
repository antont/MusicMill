import Foundation
import Combine

/// Test harness for waveform rendering performance
/// Generates synthetic data and measures metrics for both rendering approaches
class WaveformPerformanceTest {
    
    private let monitor = WaveformPerformanceMonitor()
    private var testResults: [String: Any] = [:]
    
    /// Generate synthetic WaveformData for testing
    private func generateSyntheticWaveform(points: Int = 500) -> WaveformData {
        var low: [Float] = []
        var mid: [Float] = []
        var high: [Float] = []
        
        for i in 0..<points {
            // Generate sine waves with different frequencies for each band
            let t = Float(i) / Float(points)
            low.append((sin(t * Float.pi * 2.0 * 2.0) + 1.0) / 2.0)      // 2 cycles
            mid.append((sin(t * Float.pi * 2.0 * 5.0) + 1.0) / 2.0)      // 5 cycles
            high.append((sin(t * Float.pi * 2.0 * 10.0) + 1.0) / 2.0)     // 10 cycles
        }
        
        return WaveformData(low: low, mid: mid, high: high, points: points)
    }
    
    /// Test continuous scrolling (no phrase changes)
    func testContinuousScrolling(duration: TimeInterval = 10.0) -> [String: Any] {
        monitor.reset()
        
        let startTime = Date()
        var frameCount = 0
        
        // Simulate 120fps for specified duration
        let targetFPS = 120.0
        let frameInterval = 1.0 / targetFPS
        var lastFrameTime = startTime
        
        while Date().timeIntervalSince(startTime) < duration {
            let currentTime = Date()
            if currentTime.timeIntervalSince(lastFrameTime) >= frameInterval {
                monitor.recordFrame()
                frameCount += 1
                lastFrameTime = currentTime
            }
        }
        
        return [
            "test": "continuous_scrolling",
            "duration": duration,
            "frames": frameCount,
            "avgFPS": monitor.averageFPS,
            "minFPS": monitor.minFPS,
            "maxFPS": monitor.maxFPS,
            "frameVariance": monitor.frameTimeVariance,
            "maxFrameTime": monitor.frameTimeMax
        ]
    }
    
    /// Test rapid phrase changes
    func testRapidPhraseChanges(changeInterval: TimeInterval = 2.0, duration: TimeInterval = 30.0) -> [String: Any] {
        monitor.reset()
        
        let startTime = Date()
        var phraseChangeCount = 0
        var lastChangeTime = startTime
        
        // Simulate phrase changes at regular intervals
        while Date().timeIntervalSince(startTime) < duration {
            let currentTime = Date()
            if currentTime.timeIntervalSince(lastChangeTime) >= changeInterval {
                // Simulate texture generation time (blocking)
                let genStart = CACurrentMediaTime()
                // Simulate CPU work (texture generation)
                Thread.sleep(forTimeInterval: 0.01) // 10ms texture gen
                let genEnd = CACurrentMediaTime()
                monitor.recordTextureGeneration(duration: genEnd - genStart)
                
                phraseChangeCount += 1
                lastChangeTime = currentTime
            }
            
            // Continue recording frames
            monitor.recordFrame()
        }
        
        return [
            "test": "rapid_phrase_changes",
            "duration": duration,
            "phraseChanges": phraseChangeCount,
            "avgTextureGenTime": monitor.textureGenTime,
            "textureGenCount": monitor.textureGenCount,
            "avgFPS": monitor.averageFPS,
            "minFPS": monitor.minFPS
        ]
    }
    
    /// Test long phrase playback
    func testLongPhrasePlayback(duration: TimeInterval = 30.0) -> [String: Any] {
        monitor.reset()
        
        let startTime = Date()
        var frameCount = 0
        
        // Simulate 120fps for long duration
        let targetFPS = 120.0
        let frameInterval = 1.0 / targetFPS
        var lastFrameTime = startTime
        
        while Date().timeIntervalSince(startTime) < duration {
            let currentTime = Date()
            if currentTime.timeIntervalSince(lastFrameTime) >= frameInterval {
                monitor.recordFrame()
                frameCount += 1
                lastFrameTime = currentTime
            }
        }
        
        return [
            "test": "long_phrase_playback",
            "duration": duration,
            "frames": frameCount,
            "avgFPS": monitor.averageFPS,
            "frameVariance": monitor.frameTimeVariance,
            "memoryUsage": monitor.memoryUsage
        ]
    }
    
    /// Run all tests and generate comparison report
    func runAllTests() -> String {
        var report = "=== Waveform Rendering Performance Test Report ===\n\n"
        
        // Test 1: Continuous scrolling
        let continuousResults = testContinuousScrolling(duration: 5.0)
        report += formatTestResults(continuousResults)
        report += "\n"
        
        // Test 2: Rapid phrase changes
        let rapidResults = testRapidPhraseChanges(changeInterval: 2.0, duration: 10.0)
        report += formatTestResults(rapidResults)
        report += "\n"
        
        // Test 3: Long phrase playback
        let longResults = testLongPhrasePlayback(duration: 10.0)
        report += formatTestResults(longResults)
        report += "\n"
        
        report += "=== End of Report ===\n"
        
        return report
    }
    
    private func formatTestResults(_ results: [String: Any]) -> String {
        var output = "Test: \(results["test"] ?? "unknown")\n"
        for (key, value) in results.sorted(by: { $0.key < $1.key }) {
            if key != "test" {
                output += "  \(key): \(value)\n"
            }
        }
        return output
    }
}

