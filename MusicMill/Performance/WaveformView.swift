import SwiftUI

/// DJ-style RGB waveform display
/// Shows frequency bands: Blue = bass, Green = mids, Orange = highs
/// Playback position shown with white line, played portion dimmed
struct WaveformView: View {
    let waveform: WaveformData
    var playbackProgress: Double = 0  // 0-1, current position (0 = no position shown)
    var showPlayhead: Bool = true
    var height: CGFloat = 40
    
    // Colors matching DJ software aesthetics
    private let bassColor = Color(red: 0.2, green: 0.4, blue: 0.9)      // Blue
    private let midColor = Color(red: 0.3, green: 0.8, blue: 0.3)       // Green
    private let highColor = Color(red: 1.0, green: 0.5, blue: 0.2)      // Orange
    
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                renderWaveform(context: context, size: size)
            }
        }
        .frame(height: height)
        .background(Color.black.opacity(0.3))
        .cornerRadius(4)
    }
    
    private func renderWaveform(context: GraphicsContext, size: CGSize) {
        let pointCount = waveform.points
        guard pointCount > 0 else { return }
        
        let pointWidth = size.width / CGFloat(pointCount)
        let centerY = size.height / 2
        
        for i in 0..<pointCount {
            let x = CGFloat(i) * pointWidth
            let progress = Double(i) / Double(pointCount)
            let isPlayed = showPlayhead && progress < playbackProgress
            let alpha: Double = isPlayed ? 0.35 : 1.0
            
            // Get amplitudes (clamped to valid range)
            let bassAmp = CGFloat(min(max(waveform.low[safe: i] ?? 0, 0), 1))
            let midAmp = CGFloat(min(max(waveform.mid[safe: i] ?? 0, 0), 1))
            let highAmp = CGFloat(min(max(waveform.high[safe: i] ?? 0, 0), 1))
            
            // Scale heights - bass gets most space
            let maxHeight = size.height * 0.9
            let bassH = bassAmp * maxHeight * 0.45
            let midH = midAmp * maxHeight * 0.35
            let highH = highAmp * maxHeight * 0.20
            
            // Draw mirrored waveform (centered)
            // Top half
            drawBar(context: context, x: x, y: centerY - (bassH + midH + highH) / 2,
                   width: pointWidth, height: highH / 2, color: highColor.opacity(alpha))
            drawBar(context: context, x: x, y: centerY - (bassH + midH) / 2,
                   width: pointWidth, height: midH / 2, color: midColor.opacity(alpha))
            drawBar(context: context, x: x, y: centerY - bassH / 2,
                   width: pointWidth, height: bassH / 2, color: bassColor.opacity(alpha))
            
            // Bottom half (mirrored)
            drawBar(context: context, x: x, y: centerY,
                   width: pointWidth, height: bassH / 2, color: bassColor.opacity(alpha))
            drawBar(context: context, x: x, y: centerY + bassH / 2,
                   width: pointWidth, height: midH / 2, color: midColor.opacity(alpha))
            drawBar(context: context, x: x, y: centerY + bassH / 2 + midH / 2,
                   width: pointWidth, height: highH / 2, color: highColor.opacity(alpha))
        }
        
        // Draw playhead line
        if showPlayhead && playbackProgress > 0 && playbackProgress < 1 {
            let playheadX = size.width * playbackProgress
            var playheadPath = Path()
            playheadPath.move(to: CGPoint(x: playheadX, y: 0))
            playheadPath.addLine(to: CGPoint(x: playheadX, y: size.height))
            context.stroke(playheadPath, with: .color(.white), lineWidth: 2)
        }
    }
    
    private func drawBar(context: GraphicsContext, x: CGFloat, y: CGFloat,
                        width: CGFloat, height: CGFloat, color: Color) {
        guard height > 0 else { return }
        let rect = CGRect(x: x, y: y, width: max(width - 0.5, 0.5), height: height)
        context.fill(Path(rect), with: .color(color))
    }
}

/// Compact waveform for branch cards (no playhead)
struct CompactWaveformView: View {
    let waveform: WaveformData
    var height: CGFloat = 20
    
    var body: some View {
        WaveformView(
            waveform: waveform,
            playbackProgress: 0,
            showPlayhead: false,
            height: height
        )
    }
}

/// Scrolling waveform with centered playhead (like Rekordbox/Serato)
/// The waveform scrolls past a fixed playhead in the center
/// Can show current phrase + next phrase continuation, and optionally a branch alternative
/// Uses Metal rendering for 120fps on ProMotion displays
struct ScrollingWaveformView: View {
    let phrase: PhraseNode?
    let playbackProgress: Double  // 0-1
    var trackPlaybackProgress: Double? = nil  // 0-1 position in full track (for useOriginalFile)
    var nextPhrase: PhraseNode? = nil  // Next phrase in sequence (continuation)
    var branchPhrase: PhraseNode? = nil  // Alternative branch option
    var color: Color = .orange
    var useOriginalFile: Bool = false  // If true, generate waveform from original file instead of phrase.waveform
    var useDirectRendering: Bool = false  // If true, use GPU direct rendering instead of texture generation
    var zoomLevel: Float = 1.0  // 1.0 = full view, 2.0 = 2x zoom (half visible), etc.
    var performanceMonitor: WaveformPerformanceMonitor? = nil  // Optional external monitor for UI display
    
    var body: some View {
        // Use Metal renderer for optimal 120fps performance
            MetalWaveformView(
                phrase: phrase,
                playbackProgress: playbackProgress,
                trackPlaybackProgress: trackPlaybackProgress,
                nextPhrase: nextPhrase,
                branchPhrase: branchPhrase,
                color: color,
                useOriginalFile: useOriginalFile,
                useDirectRendering: useDirectRendering,
                zoomLevel: zoomLevel,
                performanceMonitor: performanceMonitor
            )
        .background(Color.black)
    }
}

// Safe array access extension
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // Sample waveform data
        let sampleWaveform = WaveformData(
            low: (0..<150).map { Float(sin(Double($0) * 0.1) * 0.5 + 0.5) },
            mid: (0..<150).map { Float(sin(Double($0) * 0.15) * 0.4 + 0.4) },
            high: (0..<150).map { Float(sin(Double($0) * 0.2) * 0.3 + 0.3) },
            points: 150
        )
        
        Text("Full waveform with playhead")
        WaveformView(waveform: sampleWaveform, playbackProgress: 0.4, height: 60)
            .padding()
        
        Text("Compact waveform (no playhead)")
        CompactWaveformView(waveform: sampleWaveform, height: 25)
            .padding()
    }
    .background(Color(NSColor.windowBackgroundColor))
}

