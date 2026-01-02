import SwiftUI
import MetalKit
import QuartzCore
import AppKit
import AVFoundation

/// Metal-based scrolling waveform view targeting 120fps on ProMotion displays
/// Uses texture-based scrolling for efficient GPU rendering
struct MetalWaveformView: NSViewRepresentable {
    let phrase: PhraseNode?
    let playbackProgress: Double  // 0-1 (phrase-relative or track-relative depending on useOriginalFile)
    var trackPlaybackProgress: Double? = nil  // 0-1 position in full track (used when useOriginalFile is true)
    var nextPhrase: PhraseNode? = nil
    var branchPhrase: PhraseNode? = nil
    var color: Color = .orange
    var useOriginalFile: Bool = false  // If true, generate waveform from original file
    var useDirectRendering: Bool = false  // If true, use GPU direct rendering instead of texture generation
    var zoomLevel: Float = 1.0  // 1.0 = full view, 2.0 = 2x zoom (half visible), etc.
    var performanceMonitor: WaveformPerformanceMonitor? = nil  // Optional external monitor for UI display
    
    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // Fallback to empty view if Metal not available
            let fallbackView = MTKView()
            fallbackView.isHidden = true
            return fallbackView
        }
        
        let mtkView = MTKView()
        mtkView.device = device
        mtkView.delegate = context.coordinator
        mtkView.preferredFramesPerSecond = 120  // Target ProMotion 120fps
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        
        // Setup coordinator
        context.coordinator.setup(device: device, view: mtkView)
        
        return mtkView
    }
    
    func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.update(
            phrase: phrase,
            playbackProgress: playbackProgress,
            trackPlaybackProgress: trackPlaybackProgress,
            nextPhrase: nextPhrase,
            branchPhrase: branchPhrase,
            playheadColor: color,
            useOriginalFile: useOriginalFile,
            useDirectRendering: useDirectRendering,
            zoomLevel: zoomLevel
        )
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(externalMonitor: performanceMonitor)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        private var renderer: MetalWaveformRenderer?
        private var lastFrameTime: CFTimeInterval = 0
        private var frameCount: Int = 0
        private var frameTimeSum: Double = 0
        
        // Performance monitoring - use external monitor if provided, otherwise create internal one
        let performanceMonitor: WaveformPerformanceMonitor
        
        init(externalMonitor: WaveformPerformanceMonitor? = nil) {
            self.performanceMonitor = externalMonitor ?? WaveformPerformanceMonitor()
            super.init()
        }
        
        // Current state
        private var currentPhrase: PhraseNode?
        private var currentPlaybackProgress: Double = 0
        private var lastProgressUpdate: Double = 0
        private var currentNextPhrase: PhraseNode?
        private var currentBranchPhrase: PhraseNode?
        private var currentPlayheadColor: Color = .orange
        private var currentUseOriginalFile: Bool = false
        private var currentUseDirectRendering: Bool = false
        private var currentZoomLevel: Float = 1.0
        
        // Store latest progress values from SwiftUI (updated via updateNSView)
        private var latestPlaybackProgress: Double = 0
        private var latestTrackPlaybackProgress: Double? = nil
        
        // Track last phrase ID to avoid unnecessary texture regeneration
        private var lastPhraseId: String?
        private var lastViewSize: CGSize = .zero
        
        // Textures (for texture-based rendering)
        private var currentTexture: MTLTexture?
        private var nextTexture: MTLTexture?
        private var branchTexture: MTLTexture?
        
        // Buffers (for direct rendering)
        private var currentBuffer: MTLBuffer?
        private var nextBuffer: MTLBuffer?
        private var branchBuffer: MTLBuffer?
        
        private var viewSize: CGSize = .zero
        
        func setup(device: MTLDevice, view: MTKView) {
            renderer = MetalWaveformRenderer(device: device)
            renderer?.performanceMonitor = performanceMonitor
            viewSize = view.bounds.size
            
            // Setup CADisplayLink for 120fps on ProMotion
            setupDisplayLink()
        }
        
        private func setupDisplayLink() {
            // On macOS, MTKView handles frame updates automatically via draw(in:)
            // Frame rate is controlled by MTKView.preferredFramesPerSecond (set in makeNSView)
            // We can monitor frame rate in draw(in:) if needed
            lastFrameTime = CACurrentMediaTime()
        }
        
        private func updateFrameRateMonitoring() {
            // Frame rate monitoring (called from draw(in:))
            let currentTime = CACurrentMediaTime()
            let frameTime = currentTime - lastFrameTime
            lastFrameTime = currentTime
            
            frameCount += 1
            frameTimeSum += frameTime
            
            // Log frame rate every 120 frames (1 second at 120fps)
            if frameCount >= 120 {
                let avgFrameTime = frameTimeSum / Double(frameCount)
                let fps = 1.0 / avgFrameTime
                
                #if DEBUG
                if fps < 115 {
                    print("MetalWaveformView: Frame rate dropped to \(Int(fps))fps (target: 120fps)")
                }
                #endif
                
                frameCount = 0
                frameTimeSum = 0
            }
        }
        
        func update(phrase: PhraseNode?,
                   playbackProgress: Double,
                   trackPlaybackProgress: Double?,
                   nextPhrase: PhraseNode?,
                   branchPhrase: PhraseNode?,
                   playheadColor: Color,
                   useOriginalFile: Bool = false,
                   useDirectRendering: Bool = false,
                   zoomLevel: Float = 1.0) {
            let phraseChanged = phrase?.id != currentPhrase?.id
            let nextChanged = nextPhrase?.id != currentNextPhrase?.id
            let branchChanged = branchPhrase?.id != currentBranchPhrase?.id
            
            currentPhrase = phrase
            // Store latest progress values
            latestPlaybackProgress = playbackProgress
            latestTrackPlaybackProgress = trackPlaybackProgress
            
            // Use track progress if available and using original file, otherwise use phrase progress
            currentPlaybackProgress = (useOriginalFile && trackPlaybackProgress != nil) ? trackPlaybackProgress! : playbackProgress
            currentNextPhrase = nextPhrase
            currentBranchPhrase = branchPhrase
            currentPlayheadColor = playheadColor
            currentUseOriginalFile = useOriginalFile
            currentUseDirectRendering = useDirectRendering
            currentZoomLevel = zoomLevel
            
            // Only update textures/buffers when phrases actually change
            if phraseChanged || nextChanged || branchChanged {
                if useDirectRendering {
                    updateBuffers()
                } else {
                    updateTextures()
                }
            }
        }
        
        private func updateTextures() {
            guard let renderer = renderer, viewSize.height > 0, viewSize.width > 0 else { return }
            
            // Only regenerate textures if phrase changed or view size changed significantly
            let phraseId = currentPhrase?.id ?? ""
            let sizeChanged = abs(viewSize.width - lastViewSize.width) > 1 || abs(viewSize.height - lastViewSize.height) > 1
            
            if phraseId == lastPhraseId && !sizeChanged && currentTexture != nil {
                // No need to regenerate - phrase and size haven't changed
                return
            }
            
            lastPhraseId = phraseId
            lastViewSize = viewSize
            
            // Generate texture for current phrase
            if let phrase = currentPhrase {
                if currentUseOriginalFile {
                    // Generate waveform from original file asynchronously
                    let filePath = phrase.audioFile
                    let phraseId = phrase.id
                    
                    WaveformGenerator.shared.generateWaveform(from: filePath) { [weak self] (waveform: WaveformData?) in
                        guard let self = self,
                              let waveform = waveform,
                              self.currentPhrase?.id == phraseId else { return }
                        
                        // Generate texture on background queue with lower priority to not interfere with audio
                        DispatchQueue.global(qos: .utility).async {
                            let texture = self.renderer?.generateTexture(
                                from: waveform,
                                height: self.viewSize.height,
                                phraseId: "\(phraseId)_full",
                                viewWidth: self.viewSize.width
                            )
                            
                            DispatchQueue.main.async {
                                // Double-check phrase hasn't changed
                                if self.currentPhrase?.id == phraseId {
                                    self.currentTexture = texture
                                }
                            }
                        }
                    }
                    
                    // Use phrase waveform as placeholder while loading (only if we don't have a texture yet)
                    if currentTexture == nil, let placeholderWaveform = phrase.waveform {
                        currentTexture = renderer.generateTexture(
                            from: placeholderWaveform,
                            height: viewSize.height,
                            phraseId: phrase.id,
                            viewWidth: viewSize.width
                        )
                    }
                    // Keep existing texture if available - don't set to nil
                } else {
                    // Use phrase waveform directly
                    if let waveform = phrase.waveform {
                        currentTexture = renderer.generateTexture(
                            from: waveform,
                            height: viewSize.height,
                            phraseId: phrase.id,
                            viewWidth: viewSize.width
                        )
                    } else {
                        currentTexture = nil
                    }
                }
            } else {
                currentTexture = nil
            }
            
            // Generate texture for next phrase (always use phrase waveform for preview)
            if let nextPhrase = currentNextPhrase, let waveform = nextPhrase.waveform {
                nextTexture = renderer.generateTexture(
                    from: waveform,
                    height: viewSize.height,
                    phraseId: nextPhrase.id,
                    viewWidth: viewSize.width
                )
            } else {
                nextTexture = nil
            }
            
            // Generate texture for branch phrase (always use phrase waveform for preview)
            if let branchPhrase = currentBranchPhrase, let waveform = branchPhrase.waveform {
                branchTexture = renderer.generateTexture(
                    from: waveform,
                    height: viewSize.height,
                    phraseId: branchPhrase.id,
                    viewWidth: viewSize.width
                )
            } else {
                branchTexture = nil
            }
        }
        
        private func updateBuffers() {
            guard let renderer = renderer, viewSize.height > 0, viewSize.width > 0 else { return }
            
            // Only regenerate buffers if phrase changed
            let phraseId = currentPhrase?.id ?? ""
            
            if phraseId == lastPhraseId && currentBuffer != nil {
                // No need to regenerate - phrase hasn't changed
                return
            }
            
            lastPhraseId = phraseId
            lastViewSize = viewSize
            
            // Generate buffer for current phrase
            if let phrase = currentPhrase {
                if currentUseOriginalFile {
                    // Generate waveform from original file asynchronously
                    let filePath = phrase.audioFile
                    let phraseId = phrase.id
                    
                    WaveformGenerator.shared.generateWaveform(from: filePath) { [weak self] (waveform: WaveformData?) in
                        guard let self = self,
                              let waveform = waveform,
                              self.currentPhrase?.id == phraseId else { return }
                        
                        // Generate buffer on background queue
                        DispatchQueue.global(qos: .utility).async {
                            let buffer = self.renderer?.createWaveformBuffer(
                                from: waveform,
                                phraseId: "\(phraseId)_full"
                            )
                            
                            DispatchQueue.main.async {
                                if self.currentPhrase?.id == phraseId {
                                    self.currentBuffer = buffer
                                }
                            }
                        }
                    }
                    
                    // Use phrase waveform as placeholder while loading
                    if currentBuffer == nil, let placeholderWaveform = phrase.waveform {
                        currentBuffer = renderer.createWaveformBuffer(
                            from: placeholderWaveform,
                            phraseId: phrase.id
                        )
                    }
                } else {
                    // Use phrase waveform directly
                    if let waveform = phrase.waveform {
                        currentBuffer = renderer.createWaveformBuffer(
                            from: waveform,
                            phraseId: phrase.id
                        )
                    } else {
                        currentBuffer = nil
                    }
                }
            } else {
                currentBuffer = nil
            }
            
            // Generate buffer for next phrase
            if let nextPhrase = currentNextPhrase, let waveform = nextPhrase.waveform {
                nextBuffer = renderer.createWaveformBuffer(
                    from: waveform,
                    phraseId: nextPhrase.id
                )
            } else {
                nextBuffer = nil
            }
            
            // Generate buffer for branch phrase
            if let branchPhrase = currentBranchPhrase, let waveform = branchPhrase.waveform {
                branchBuffer = renderer.createWaveformBuffer(
                    from: waveform,
                    phraseId: branchPhrase.id
                )
            } else {
                branchBuffer = nil
            }
        }
        
        // MARK: - MTKViewDelegate
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            viewSize = size
            // Regenerate textures/buffers with new size
            if currentUseDirectRendering {
                updateBuffers()
            } else {
                updateTextures()
            }
        }
        
        func draw(in view: MTKView) {
            guard let renderer = renderer,
                  let drawable = view.currentDrawable else {
                return
            }
            
            // Update frame rate monitoring
            updateFrameRateMonitoring()
            
            // Record frame for performance monitoring
            performanceMonitor.recordFrame()
            
            // Update view size if changed (but don't regenerate textures/buffers unless size changed significantly)
            let newSize = view.bounds.size
            if abs(newSize.width - viewSize.width) > 1 || abs(newSize.height - viewSize.height) > 1 {
                viewSize = newSize
                if currentUseDirectRendering {
                    updateBuffers()
                } else {
                    updateTextures()
                }
            }
            
            // Update progress every frame from stored values (smooth scrolling)
            // This ensures progress updates smoothly even if SwiftUI doesn't call updateNSView every frame
            // Always update to latest value for smooth scrolling
            let newProgress = (currentUseOriginalFile && latestTrackPlaybackProgress != nil) ? latestTrackPlaybackProgress! : latestPlaybackProgress
            currentPlaybackProgress = newProgress
            
            let hasBranch = currentBranchPhrase != nil && currentNextPhrase != nil
            
            // Convert SwiftUI Color to SIMD4<Float>
            // Convert to RGB color space first to support getRed:green:blue:alpha:
            let nsColor = NSColor(currentPlayheadColor).usingColorSpace(.deviceRGB) ?? NSColor.white
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            let playheadColor = SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
            
            // Debug: Print progress only for main view (with phrase) and only occasionally
            #if DEBUG
            if currentPhrase != nil && currentPlaybackProgress > 0 && Int.random(in: 0..<600) == 0 {
                // Print roughly once per 5 seconds at 120fps, only for active views
                print("[MetalWaveformView] Progress: \(String(format: "%.2f", currentPlaybackProgress)), phrase: \(currentPhrase?.id ?? "none")")
            }
            #endif
            
            // Render waveform using appropriate method
            if currentUseDirectRendering {
                // Direct rendering from buffers (supports zoom)
                let pointCount = currentPhrase?.waveform?.points ?? currentNextPhrase?.waveform?.points ?? 500
                renderer.renderDirectWaveform(
                    to: drawable,
                    currentBuffer: currentBuffer,
                    nextBuffer: nextBuffer,
                    branchBuffer: branchBuffer,
                    playbackProgress: currentPlaybackProgress,
                    hasBranch: hasBranch,
                    viewSize: viewSize,
                    playheadColor: playheadColor,
                    pointCount: pointCount,
                    zoomLevel: currentZoomLevel
                )
            } else {
                // Texture-based rendering
                renderer.renderScrollingWaveform(
                    to: drawable,
                    currentTexture: currentTexture,
                    nextTexture: nextTexture,
                    branchTexture: branchTexture,
                    playbackProgress: currentPlaybackProgress,
                    hasBranch: hasBranch,
                    viewSize: viewSize,
                    playheadColor: playheadColor
                )
            }
        }
        
        deinit {
            // Cleanup handled automatically by MTKView
        }
    }
}

