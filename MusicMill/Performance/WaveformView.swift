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
    
    // Bar width for rendering
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1
    
    var body: some View {
        GeometryReader { geo in
            if let phrase = phrase, let waveform = phrase.waveform {
                TimelineView(.animation(minimumInterval: 1.0/30.0)) { _ in
                    Canvas { context, size in
                        renderScrollingWaveform(context: context, size: size, 
                                               currentWaveform: waveform,
                                               nextWaveform: nextPhrase?.waveform,
                                               branchWaveform: branchPhrase?.waveform)
                    }
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
        
        let hasBranch = branchWaveform != nil && nextPhrase != nil
        let playheadX = size.width / 2
        
        // Map progress to waveform data points
        let currentDataPoint = playbackProgress * Double(pointCount)
        
        // Calculate pixels per data point (zoom level)
        let pixelsPerPoint: CGFloat = 4  // Adjust for zoom level
        
        // Calculate where the current phrase ends in screen coordinates
        let remainingPoints = Double(pointCount) - currentDataPoint
        let currentEndScreenX = playheadX + CGFloat(remainingPoints) * pixelsPerPoint
        
        // Layout calculations
        let mainCenterY: CGFloat
        let branchCenterY: CGFloat
        let waveformHeight: CGFloat
        
        if hasBranch {
            waveformHeight = size.height * 0.42
            mainCenterY = size.height * 0.28
            branchCenterY = size.height * 0.72
            
            // Draw separator line
            if currentEndScreenX < size.width {
                var splitPath = Path()
                splitPath.move(to: CGPoint(x: max(playheadX, currentEndScreenX), y: size.height * 0.5))
                splitPath.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
                context.stroke(splitPath, with: .color(.white.opacity(0.2)), lineWidth: 1)
            }
        } else {
            waveformHeight = size.height * 0.85
            mainCenterY = size.height / 2
            branchCenterY = 0
        }
        
        // Build paths for batched rendering (much faster than individual draws)
        var bassPath = Path()
        var midPath = Path()
        var highPath = Path()
        var bassPathPast = Path()
        var midPathPast = Path()
        var highPathPast = Path()
        var branchBassPath = Path()
        var branchMidPath = Path()
        var branchHighPath = Path()
        
        let step = barWidth + barSpacing
        var screenX: CGFloat = 0
        
        while screenX < size.width {
            // Calculate which data point this screen position corresponds to
            let offsetFromPlayhead = screenX - playheadX
            let dataOffset = offsetFromPlayhead / pixelsPerPoint
            let dataPoint = currentDataPoint + Double(dataOffset)
            
            let isPast = screenX < playheadX
            let isInCurrent = dataPoint >= 0 && dataPoint < Double(pointCount)
            let isInNext = dataPoint >= Double(pointCount)
            let nextDataIndex = Int(dataPoint) - pointCount
            
            // Render main waveform (current phrase or continuation)
            if isInCurrent {
                let idx = Int(dataPoint)
                if idx >= 0 && idx < pointCount {
                    addWaveformBars(to: isPast ? &bassPathPast : &bassPath,
                                   midPath: isPast ? &midPathPast : &midPath,
                                   highPath: isPast ? &highPathPast : &highPath,
                                   waveform: currentWaveform, index: idx,
                                   x: screenX, centerY: mainCenterY, maxHeight: waveformHeight)
                }
            } else if isInNext, let next = nextWaveform, nextDataIndex >= 0 && nextDataIndex < next.points {
                // Continue with next phrase
                addWaveformBars(to: &bassPath, midPath: &midPath, highPath: &highPath,
                               waveform: next, index: nextDataIndex,
                               x: screenX, centerY: mainCenterY, maxHeight: waveformHeight)
            }
            
            // Render branch waveform
            if hasBranch, isInNext, let branch = branchWaveform,
               nextDataIndex >= 0 && nextDataIndex < branch.points {
                addWaveformBars(to: &branchBassPath, midPath: &branchMidPath, highPath: &branchHighPath,
                               waveform: branch, index: nextDataIndex,
                               x: screenX, centerY: branchCenterY, maxHeight: waveformHeight)
            }
            
            screenX += step
        }
        
        // Draw all paths in batches (much faster)
        context.fill(bassPathPast, with: .color(bassColor.opacity(0.35)))
        context.fill(midPathPast, with: .color(midColor.opacity(0.35)))
        context.fill(highPathPast, with: .color(highColor.opacity(0.35)))
        
        context.fill(bassPath, with: .color(bassColor))
        context.fill(midPath, with: .color(midColor))
        context.fill(highPath, with: .color(highColor))
        
        // Branch paths (tinted cyan)
        if hasBranch {
            context.fill(branchBassPath, with: .color(Color.cyan.opacity(0.9)))
            context.fill(branchMidPath, with: .color(Color.cyan.opacity(0.7)))
            context.fill(branchHighPath, with: .color(Color.cyan.opacity(0.5)))
        }
        
        // Draw labels
        if hasBranch, currentEndScreenX > playheadX && currentEndScreenX < size.width - 80 {
            let continueText = context.resolve(Text("→ CONTINUE").font(.system(size: 9, weight: .bold)).foregroundColor(.orange))
            context.draw(continueText, at: CGPoint(x: currentEndScreenX + 50, y: 12))
            
            let branchText = context.resolve(Text("↳ BRANCH").font(.system(size: 9, weight: .bold)).foregroundColor(.cyan))
            context.draw(branchText, at: CGPoint(x: currentEndScreenX + 50, y: size.height - 12))
        }
        
        // Draw phrase boundary marker
        if currentEndScreenX > playheadX && currentEndScreenX < size.width {
            var boundaryPath = Path()
            boundaryPath.move(to: CGPoint(x: currentEndScreenX, y: 0))
            boundaryPath.addLine(to: CGPoint(x: currentEndScreenX, y: size.height))
            context.stroke(boundaryPath, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        
        // Draw centered playhead
        var playheadPath = Path()
        playheadPath.move(to: CGPoint(x: playheadX, y: 0))
        playheadPath.addLine(to: CGPoint(x: playheadX, y: size.height))
        context.stroke(playheadPath, with: .color(color), lineWidth: 2)
        
        // Playhead triangle
        var trianglePath = Path()
        trianglePath.move(to: CGPoint(x: playheadX - 5, y: 0))
        trianglePath.addLine(to: CGPoint(x: playheadX + 5, y: 0))
        trianglePath.addLine(to: CGPoint(x: playheadX, y: 6))
        trianglePath.closeSubpath()
        context.fill(trianglePath, with: .color(color))
    }
    
    private func addWaveformBars(to bassPath: inout Path, midPath: inout Path, highPath: inout Path,
                                  waveform: WaveformData, index: Int,
                                  x: CGFloat, centerY: CGFloat, maxHeight: CGFloat) {
        let bassAmp = CGFloat(min(max(waveform.low[safe: index] ?? 0, 0), 1))
        let midAmp = CGFloat(min(max(waveform.mid[safe: index] ?? 0, 0), 1))
        let highAmp = CGFloat(min(max(waveform.high[safe: index] ?? 0, 0), 1))
        
        let bassH = bassAmp * maxHeight * 0.5
        let midH = midAmp * maxHeight * 0.35
        let highH = highAmp * maxHeight * 0.15
        
        // Mirrored bars centered on centerY
        // Bass (innermost)
        if bassH > 0.5 {
            bassPath.addRect(CGRect(x: x, y: centerY - bassH/2, width: barWidth, height: bassH))
        }
        // Mid
        if midH > 0.5 {
            midPath.addRect(CGRect(x: x, y: centerY - bassH/2 - midH/2, width: barWidth, height: midH/2))
            midPath.addRect(CGRect(x: x, y: centerY + bassH/2, width: barWidth, height: midH/2))
        }
        // High (outermost)
        if highH > 0.5 {
            highPath.addRect(CGRect(x: x, y: centerY - bassH/2 - midH/2 - highH/2, width: barWidth, height: highH/2))
            highPath.addRect(CGRect(x: x, y: centerY + bassH/2 + midH/2, width: barWidth, height: highH/2))
        }
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

