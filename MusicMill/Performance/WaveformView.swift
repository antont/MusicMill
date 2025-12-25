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
struct ScrollingWaveformView: View {
    let phrase: PhraseNode?
    let playbackProgress: Double  // 0-1
    var nextPhrase: PhraseNode? = nil  // Next phrase in sequence (continuation)
    var branchPhrase: PhraseNode? = nil  // Alternative branch option
    var color: Color = .orange
    
    // Colors matching DJ software aesthetics
    private let bassColor = Color(red: 0.2, green: 0.4, blue: 0.9)      // Blue
    private let midColor = Color(red: 0.3, green: 0.8, blue: 0.3)       // Green
    private let highColor = Color(red: 1.0, green: 0.5, blue: 0.2)      // Orange
    
    var body: some View {
        GeometryReader { geo in
            if let phrase = phrase, let waveform = phrase.waveform {
                Canvas { context, size in
                    renderScrollingWaveform(context: context, size: size, 
                                           currentWaveform: waveform,
                                           nextWaveform: nextPhrase?.waveform,
                                           branchWaveform: branchPhrase?.waveform)
                }
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .overlay(
                        Text("No waveform")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    )
            }
        }
        .background(Color.black)
    }
    
    private func renderScrollingWaveform(context: GraphicsContext, size: CGSize, 
                                         currentWaveform: WaveformData,
                                         nextWaveform: WaveformData?,
                                         branchWaveform: WaveformData?) {
        let pointCount = currentWaveform.points
        guard pointCount > 0 else { return }
        
        let hasBranch = branchWaveform != nil
        let playheadX = size.width / 2
        let centerPoint = Int(Double(pointCount) * playbackProgress)
        
        // Calculate where the current phrase ends in screen coordinates
        let remainingCurrentPoints = pointCount - centerPoint
        let currentEndScreenX = playheadX + CGFloat(remainingCurrentPoints * 3)
        
        // If we have a branch, split the view: top half = continuation, bottom half = branch
        // Otherwise, use full height for the waveform
        let mainCenterY: CGFloat
        let branchCenterY: CGFloat
        let waveformHeight: CGFloat
        
        if hasBranch {
            // Split view
            waveformHeight = size.height * 0.45
            mainCenterY = size.height * 0.25
            branchCenterY = size.height * 0.75
            
            // Draw separator line where split begins
            if currentEndScreenX < size.width {
                var splitPath = Path()
                splitPath.move(to: CGPoint(x: currentEndScreenX, y: size.height * 0.5))
                splitPath.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
                context.stroke(splitPath, with: .color(.white.opacity(0.3)), lineWidth: 1)
            }
        } else {
            waveformHeight = size.height * 0.9
            mainCenterY = size.height / 2
            branchCenterY = 0  // Not used
        }
        
        // Draw each visible point
        for screenX in stride(from: 0, to: Int(size.width), by: 3) {
            let pointOffset = screenX - Int(playheadX)
            let dataIndex = centerPoint + (pointOffset / 3)
            let x = CGFloat(screenX)
            let isPast = x < playheadX
            
            // Determine which waveform to use and the alpha
            let isInCurrentPhrase = dataIndex >= 0 && dataIndex < pointCount
            let isInNextPhrase = !isInCurrentPhrase && dataIndex >= pointCount
            let nextIndex = dataIndex - pointCount
            
            // Main waveform (current + next continuation)
            if isInCurrentPhrase {
                let alpha: Double = isPast ? 0.4 : 1.0
                drawWaveformBar(context: context, waveform: currentWaveform, index: dataIndex,
                               x: x, centerY: mainCenterY, maxHeight: waveformHeight, alpha: alpha)
            } else if isInNextPhrase, let next = nextWaveform, nextIndex < next.points {
                // Draw next phrase continuation
                drawWaveformBar(context: context, waveform: next, index: nextIndex,
                               x: x, centerY: mainCenterY, maxHeight: waveformHeight, alpha: 0.7)
            }
            
            // Branch waveform (only shown after current phrase ends)
            if hasBranch, let branch = branchWaveform, isInNextPhrase, nextIndex < branch.points {
                drawWaveformBar(context: context, waveform: branch, index: nextIndex,
                               x: x, centerY: branchCenterY, maxHeight: waveformHeight, alpha: 0.9,
                               tint: .cyan)
            }
        }
        
        // Draw branch label if we have one
        if hasBranch, currentEndScreenX < size.width {
            // Continuation label (top)
            let continueText = context.resolve(Text("→ CONTINUE").font(.system(size: 8, weight: .bold)).foregroundColor(.orange.opacity(0.8)))
            context.draw(continueText, at: CGPoint(x: currentEndScreenX + 40, y: mainCenterY - waveformHeight/2 - 6))
            
            // Branch label (bottom)
            let branchText = context.resolve(Text("↳ BRANCH").font(.system(size: 8, weight: .bold)).foregroundColor(.cyan.opacity(0.8)))
            context.draw(branchText, at: CGPoint(x: currentEndScreenX + 40, y: branchCenterY - waveformHeight/2 - 6))
        }
        
        // Draw phrase boundary marker
        if currentEndScreenX > playheadX && currentEndScreenX < size.width {
            var boundaryPath = Path()
            boundaryPath.move(to: CGPoint(x: currentEndScreenX, y: 0))
            boundaryPath.addLine(to: CGPoint(x: currentEndScreenX, y: size.height))
            context.stroke(boundaryPath, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
        }
        
        // Draw centered playhead
        var playheadPath = Path()
        playheadPath.move(to: CGPoint(x: playheadX, y: 0))
        playheadPath.addLine(to: CGPoint(x: playheadX, y: size.height))
        context.stroke(playheadPath, with: .color(color), lineWidth: 2)
        
        // Draw playhead triangle at top
        var trianglePath = Path()
        trianglePath.move(to: CGPoint(x: playheadX - 6, y: 0))
        trianglePath.addLine(to: CGPoint(x: playheadX + 6, y: 0))
        trianglePath.addLine(to: CGPoint(x: playheadX, y: 8))
        trianglePath.closeSubpath()
        context.fill(trianglePath, with: .color(color))
    }
    
    private func drawWaveformBar(context: GraphicsContext, waveform: WaveformData, index: Int,
                                 x: CGFloat, centerY: CGFloat, maxHeight: CGFloat, alpha: Double,
                                 tint: Color? = nil) {
        // Get amplitudes
        let bassAmp = CGFloat(min(max(waveform.low[safe: index] ?? 0, 0), 1))
        let midAmp = CGFloat(min(max(waveform.mid[safe: index] ?? 0, 0), 1))
        let highAmp = CGFloat(min(max(waveform.high[safe: index] ?? 0, 0), 1))
        
        // Scale heights
        let bassH = bassAmp * maxHeight * 0.45
        let midH = midAmp * maxHeight * 0.35
        let highH = highAmp * maxHeight * 0.20
        
        // Colors (optionally tinted)
        let bass = tint ?? bassColor
        let mid = tint?.opacity(0.8) ?? midColor
        let high = tint?.opacity(0.6) ?? highColor
        
        // Draw mirrored waveform
        // Top half
        drawBar(context: context, x: x, y: centerY - (bassH + midH + highH) / 2,
               width: 2.5, height: highH / 2, color: high.opacity(alpha))
        drawBar(context: context, x: x, y: centerY - (bassH + midH) / 2,
               width: 2.5, height: midH / 2, color: mid.opacity(alpha))
        drawBar(context: context, x: x, y: centerY - bassH / 2,
               width: 2.5, height: bassH / 2, color: bass.opacity(alpha))
        
        // Bottom half
        drawBar(context: context, x: x, y: centerY,
               width: 2.5, height: bassH / 2, color: bass.opacity(alpha))
        drawBar(context: context, x: x, y: centerY + bassH / 2,
               width: 2.5, height: midH / 2, color: mid.opacity(alpha))
        drawBar(context: context, x: x, y: centerY + bassH / 2 + midH / 2,
               width: 2.5, height: highH / 2, color: high.opacity(alpha))
    }
    
    private func drawBar(context: GraphicsContext, x: CGFloat, y: CGFloat,
                        width: CGFloat, height: CGFloat, color: Color) {
        guard height > 0 else { return }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        context.fill(Path(rect), with: .color(color))
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

