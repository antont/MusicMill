import Foundation
import Metal
import MetalKit
import QuartzCore
import CoreGraphics

/// Metal renderer for RGB waveform display with texture-based scrolling
/// Renders waveform to texture once, then scrolls texture efficiently on GPU
class MetalWaveformRenderer {
    
    // MARK: - Properties
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    
    // Render pipelines
    private var scrollPipelineState: MTLRenderPipelineState?
    private var barRenderPipelineState: MTLRenderPipelineState?
    private var directRenderPipelineState: MTLRenderPipelineState?
    
    // Pre-allocated vertex buffer for full-screen quad (reused every frame)
    private var quadVertexBuffer: MTLBuffer?
    
    // Texture generation
    private var waveformTextures: [String: MTLTexture] = [:] // Cache by phrase ID
    private let pixelsPerPoint: CGFloat = 1.0  // 1 pixel per waveform point for smooth, gap-free rendering
    
    // Direct rendering buffers
    private var waveformBuffers: [String: MTLBuffer] = [:] // Cache by phrase ID
    
    // Performance monitoring
    weak var performanceMonitor: WaveformPerformanceMonitor?
    
    // GPU Profiling
    var enableGPUProfiling: Bool = false
    private var gpuTimeSum: Double = 0
    private var gpuFrameCount: Int = 0
    private var lastGPUReportTime: CFTimeInterval = 0
    private var gpuProfileLog: [String] = []
    
    /// Get collected GPU profile data
    func getGPUProfileLog() -> [String] {
        return gpuProfileLog
    }
    
    /// Clear GPU profile data
    func clearGPUProfileLog() {
        gpuProfileLog.removeAll()
    }
    
    // Colors (matching DJ software aesthetics)
    private let bassColor = SIMD4<Float>(0.2, 0.4, 0.9, 1.0)      // Blue
    private let midColor = SIMD4<Float>(0.3, 0.8, 0.3, 1.0)       // Green
    private let highColor = SIMD4<Float>(1.0, 0.5, 0.2, 1.0)       // Orange
    
    // MARK: - Initialization
    
    init?(device: MTLDevice) {
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = commandQueue
        
        // Load shader library
        guard let library = device.makeDefaultLibrary() else {
            return nil
        }
        self.library = library
        
        // Setup render pipelines
        setupRenderPipelines()
        
        // Pre-allocate vertex buffer for full-screen quad (reused every frame)
        setupQuadVertexBuffer()
    }
    
    private func setupQuadVertexBuffer() {
        // Full-screen quad vertices (interleaved: position + texCoord)
        // This is allocated ONCE and reused for all rendering
        let vertices: [Float] = [
            -1.0, -1.0,  0.0, 1.0,  // Bottom left: pos(-1,-1), tex(0,1)
             1.0, -1.0,  1.0, 1.0,  // Bottom right: pos(1,-1), tex(1,1)
            -1.0,  1.0,  0.0, 0.0,  // Top left: pos(-1,1), tex(0,0)
             1.0,  1.0,  1.0, 0.0   // Top right: pos(1,1), tex(1,0)
        ]
        
        quadVertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.size, options: [.storageModeShared])
    }
    
    private func setupRenderPipelines() {
        // Scrolling pipeline (samples texture with UV offset)
        let scrollVertexFunction = library.makeFunction(name: "vertex_main")
        let scrollFragmentFunction = library.makeFunction(name: "fragment_scroll")
        
        // Direct rendering pipeline (renders from WaveformData buffer)
        let directVertexFunction = library.makeFunction(name: "vertex_main")
        let directFragmentFunction = library.makeFunction(name: "fragment_waveform_direct")
        
        // Create vertex descriptor for interleaved vertex data
        let vertexDescriptor = MTLVertexDescriptor()
        
        // Position attribute (offset 0, stride 16 bytes = 4 floats)
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        
        // TexCoord attribute (offset 8 bytes, stride 16 bytes)
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = 8
        vertexDescriptor.attributes[1].bufferIndex = 0
        
        // Buffer layout
        vertexDescriptor.layouts[0].stride = 16  // 4 floats * 4 bytes
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        let scrollPipelineDescriptor = MTLRenderPipelineDescriptor()
        scrollPipelineDescriptor.vertexFunction = scrollVertexFunction
        scrollPipelineDescriptor.fragmentFunction = scrollFragmentFunction
        scrollPipelineDescriptor.vertexDescriptor = vertexDescriptor
        scrollPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        scrollPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        scrollPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        scrollPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        scrollPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        scrollPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        scrollPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        scrollPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            scrollPipelineState = try device.makeRenderPipelineState(descriptor: scrollPipelineDescriptor)
        } catch {
            print("MetalWaveformRenderer: Failed to create scroll pipeline: \(error)")
        }
        
        // Setup direct rendering pipeline
        let directPipelineDescriptor = MTLRenderPipelineDescriptor()
        directPipelineDescriptor.vertexFunction = directVertexFunction
        directPipelineDescriptor.fragmentFunction = directFragmentFunction
        directPipelineDescriptor.vertexDescriptor = vertexDescriptor
        directPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        directPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        directPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        directPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        directPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        directPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        directPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        directPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            directRenderPipelineState = try device.makeRenderPipelineState(descriptor: directPipelineDescriptor)
        } catch {
            print("MetalWaveformRenderer: Failed to create direct render pipeline: \(error)")
        }
    }
    
    // MARK: - Texture Generation
    
    /// Generate Metal texture from WaveformData
    /// Renders RGB bars to texture for efficient scrolling
    func generateTexture(from waveform: WaveformData, height: CGFloat, phraseId: String, viewWidth: CGFloat = 0) -> MTLTexture? {
        // Check cache first
        if let cached = waveformTextures[phraseId] {
            return cached
        }
        
        let pointCount = waveform.points
        guard pointCount > 0 else { return nil }
        
        // Calculate texture dimensions
        // Use 1 pixel per waveform point for smooth, gap-free rendering
        // Texture width should match waveform data exactly - scrolling is handled in shader
        let textureWidth = pointCount
        let textureHeight = Int(height)
        
        // Create texture descriptor
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: textureWidth,
            height: textureHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        // Use shared storage for CPU writes (works on both Intel and Apple Silicon)
        textureDescriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }
        
        // Render waveform bars to texture
        renderWaveformToTexture(waveform: waveform, texture: texture, height: height)
        
        // Cache texture
        waveformTextures[phraseId] = texture
        
        return texture
    }
    
    private func renderWaveformToTexture(waveform: WaveformData, texture: MTLTexture, height: CGFloat) {
        // Use direct texture data update (CPU-based, but only done once per phrase)
        // This is acceptable since texture generation happens infrequently (only when phrase changes)
        updateTextureData(waveform: waveform, texture: texture, height: height)
    }
    
    private func updateTextureData(waveform: WaveformData, texture: MTLTexture, height: CGFloat) {
        let startTime = CACurrentMediaTime()
        
        let width = texture.width
        let textureHeight = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        
        // Allocate buffer for texture data
        let dataSize = width * textureHeight * bytesPerPixel
        var textureData = [UInt8](repeating: 0, count: dataSize)
        
        let pointCount = waveform.points
        let centerY = Float(textureHeight) / 2.0
        let maxHeight = Float(textureHeight) * 0.9
        
        // Render each waveform point as RGB bars
        // Each point gets exactly 1 pixel (texture width = pointCount)
        for i in 0..<pointCount {
            let bassAmp = min(max(waveform.low[safe: i] ?? 0, 0), 1)
            let midAmp = min(max(waveform.mid[safe: i] ?? 0, 0), 1)
            let highAmp = min(max(waveform.high[safe: i] ?? 0, 0), 1)
            
            let bassH = bassAmp * maxHeight * 0.5
            let midH = midAmp * maxHeight * 0.35
            let highH = highAmp * maxHeight * 0.15
            
            // Each waveform point maps to exactly one pixel column
            let x = i
            
            // Draw mirrored bars for this pixel column
            for y in 0..<textureHeight {
                let distFromCenter = abs(Float(y) - centerY)
                let totalHeight = (bassH + midH + highH) / 2.0
                
                if distFromCenter <= totalHeight {
                    let pixelIndex = (y * width + x) * bytesPerPixel
                    
                    var r: UInt8 = 0
                    var g: UInt8 = 0
                    var b: UInt8 = 0
                    var a: UInt8 = 255
                    
                    // Determine color based on distance from center
                    if distFromCenter <= bassH / 2.0 {
                        // Bass (blue)
                        r = 51   // 0.2 * 255
                        g = 102  // 0.4 * 255
                        b = 230  // 0.9 * 255
                    } else if distFromCenter <= (bassH + midH) / 2.0 {
                        // Mid (green)
                        r = 77   // 0.3 * 255
                        g = 204  // 0.8 * 255
                        b = 77   // 0.3 * 255
                    } else {
                        // High (orange)
                        r = 255  // 1.0 * 255
                        g = 128  // 0.5 * 255
                        b = 51   // 0.2 * 255
                    }
                    
                    textureData[pixelIndex] = b     // Blue
                    textureData[pixelIndex + 1] = g // Green
                    textureData[pixelIndex + 2] = r // Red
                    textureData[pixelIndex + 3] = a // Alpha
                }
            }
        }
        
        // Update texture with data
        let uploadStartTime = CACurrentMediaTime()
        let region = MTLRegionMake2D(0, 0, width, textureHeight)
        texture.replace(region: region, mipmapLevel: 0, withBytes: textureData, bytesPerRow: bytesPerRow)
        let uploadEndTime = CACurrentMediaTime()
        
        // Record performance metrics
        let genDuration = uploadStartTime - startTime
        let uploadDuration = uploadEndTime - uploadStartTime
        
        performanceMonitor?.recordTextureGeneration(duration: genDuration)
        performanceMonitor?.recordTextureUpload(duration: uploadDuration)
        
        // Update memory usage estimate (rough: width * height * 4 bytes per pixel)
        let textureSize = Int64(width * textureHeight * 4)
        let textureCount = waveformTextures.count
        performanceMonitor?.updateMemoryUsage(textureCount: textureCount, averageTextureSize: textureSize)
    }
    
    // MARK: - Rendering
    
    /// Render scrolling waveform to drawable (texture-based)
    func renderScrollingWaveform(to drawable: CAMetalDrawable,
                                 currentTexture: MTLTexture?,
                                 nextTexture: MTLTexture?,
                                 branchTexture: MTLTexture?,
                                 playbackProgress: Double,
                                 hasBranch: Bool,
                                 viewSize: CGSize,
                                 playheadColor: SIMD4<Float>) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: createRenderPassDescriptor(drawable: drawable)),
              let pipelineState = scrollPipelineState else {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // Calculate scroll offset for centered playhead
        var scrollOffset = Float(playbackProgress)
        
        // Use pre-allocated vertex buffer (no allocation per frame!)
        guard let vertexBuffer = quadVertexBuffer else { return }
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        let sampler = createSampler()
        var alpha: Float = 1.0
        
        // Render main waveform (current or next)
        if let texture = currentTexture ?? nextTexture {
            renderEncoder.setFragmentTexture(texture, index: 0)
            renderEncoder.setFragmentSamplerState(sampler, index: 0)
            renderEncoder.setFragmentBytes(&scrollOffset, length: MemoryLayout<Float>.size, index: 0)
            renderEncoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 1)
            
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        
        // Render branch waveform if present (lower half, tinted cyan)
        if hasBranch, let branchTexture = branchTexture {
            // Use viewport to render to lower half
            let viewport = MTLViewport(
                originX: 0,
                originY: Double(viewSize.height / 2),
                width: Double(viewSize.width),
                height: Double(viewSize.height / 2),
                znear: 0,
                zfar: 1
            )
            renderEncoder.setViewport(viewport)
            
            var branchAlpha: Float = 0.8
            renderEncoder.setFragmentTexture(branchTexture, index: 0)
            renderEncoder.setFragmentBytes(&scrollOffset, length: MemoryLayout<Float>.size, index: 0)
            renderEncoder.setFragmentBytes(&branchAlpha, length: MemoryLayout<Float>.size, index: 1)
            
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            
            // Reset viewport for playhead rendering
            let fullViewport = MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(viewSize.width),
                height: Double(viewSize.height),
                znear: 0,
                zfar: 1
            )
            renderEncoder.setViewport(fullViewport)
        }
        
        // Draw playhead line (centered)
        drawPlayhead(renderEncoder: renderEncoder, viewSize: viewSize, color: playheadColor)
        
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        
        // GPU Profiling for texture-based rendering
        if enableGPUProfiling {
            let submitTime = CACurrentMediaTime()
            commandBuffer.addCompletedHandler { [weak self] buffer in
                guard let self = self else { return }
                let gpuTime = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
                let totalTime = (CACurrentMediaTime() - submitTime) * 1000.0
                
                self.gpuTimeSum += gpuTime
                self.gpuFrameCount += 1
                
                let now = CACurrentMediaTime()
                if now - self.lastGPUReportTime >= 1.0 {
                    let avgGPU = self.gpuTimeSum / Double(self.gpuFrameCount)
                    let log = "[Texture] Frames:\(self.gpuFrameCount) AvgGPU:\(String(format: "%.3f", avgGPU))ms Total:\(String(format: "%.3f", totalTime))ms"
                    self.gpuProfileLog.append(log)
                    self.gpuTimeSum = 0
                    self.gpuFrameCount = 0
                    self.lastGPUReportTime = now
                }
            }
        }
        
        commandBuffer.commit()
    }
    
    private func drawPlayhead(renderEncoder: MTLRenderCommandEncoder, viewSize: CGSize, color: SIMD4<Float>) {
        // Playhead is drawn in the fragment shader by checking if we're at screen center (u=0.5)
        // This is handled in the shader, so this function is a placeholder
        // Could be enhanced with a separate render pass for more complex playhead rendering
    }
    
    private func createRenderPassDescriptor(drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }
    
    private func createSampler() -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }
    
    // MARK: - Direct Rendering (GPU-based)
    
    /// Create Metal buffer from WaveformData for direct GPU rendering
    /// Interleaved format: [low0, mid0, high0, low1, mid1, high1, ...]
    func createWaveformBuffer(from waveform: WaveformData, phraseId: String) -> MTLBuffer? {
        // Check cache first
        if let cached = waveformBuffers[phraseId] {
            return cached
        }
        
        let pointCount = waveform.points
        guard pointCount > 0 else { return nil }
        
        // Create interleaved buffer: [low0, mid0, high0, low1, mid1, high1, ...]
        var bufferData: [Float] = []
        bufferData.reserveCapacity(pointCount * 3)
        
        for i in 0..<pointCount {
            bufferData.append(waveform.low[safe: i] ?? 0)
            bufferData.append(waveform.mid[safe: i] ?? 0)
            bufferData.append(waveform.high[safe: i] ?? 0)
        }
        
        // Create Metal buffer with shared storage for CPU-GPU access
        let bufferSize = bufferData.count * MemoryLayout<Float>.size
        guard let buffer = device.makeBuffer(bytes: bufferData, length: bufferSize, options: [.storageModeShared]) else {
            return nil
        }
        
        // Cache buffer
        waveformBuffers[phraseId] = buffer
        
        // Update memory usage estimate
        performanceMonitor?.updateMemoryUsage(textureCount: waveformBuffers.count, averageTextureSize: Int64(bufferSize))
        
        return buffer
    }
    
    /// Render waveform directly from buffer (GPU-based, no texture generation)
    /// zoomLevel: 1.0 = full waveform, 2.0 = 2x zoom (half visible), 4.0 = 4x zoom, etc.
    func renderDirectWaveform(to drawable: CAMetalDrawable,
                             currentBuffer: MTLBuffer?,
                             nextBuffer: MTLBuffer?,
                             branchBuffer: MTLBuffer?,
                             playbackProgress: Double,
                             hasBranch: Bool,
                             viewSize: CGSize,
                             playheadColor: SIMD4<Float>,
                             pointCount: Int,
                             zoomLevel: Float = 1.0) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: createRenderPassDescriptor(drawable: drawable)),
              let pipelineState = directRenderPipelineState else {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // Calculate scroll offset
        var scrollOffset = Float(playbackProgress)
        
        // Use pre-allocated vertex buffer (no allocation per frame!)
        guard let vertexBuffer = quadVertexBuffer else { return }
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        var alpha: Float = 1.0
        var pointCountInt = Int32(pointCount)
        var viewHeight = Float(viewSize.height)
        var zoom = max(zoomLevel, 0.1)  // Prevent division by zero
        
        // Render main waveform (current or next)
        if let buffer = currentBuffer ?? nextBuffer {
            renderEncoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            renderEncoder.setFragmentBytes(&pointCountInt, length: MemoryLayout<Int32>.size, index: 1)
            renderEncoder.setFragmentBytes(&scrollOffset, length: MemoryLayout<Float>.size, index: 2)
            renderEncoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 3)
            renderEncoder.setFragmentBytes(&viewHeight, length: MemoryLayout<Float>.size, index: 4)
            renderEncoder.setFragmentBytes(&zoom, length: MemoryLayout<Float>.size, index: 5)
            
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        
        // Render branch waveform if present (lower half)
        if hasBranch, let branchBuffer = branchBuffer {
            let viewport = MTLViewport(
                originX: 0,
                originY: Double(viewSize.height / 2),
                width: Double(viewSize.width),
                height: Double(viewSize.height / 2),
                znear: 0,
                zfar: 1
            )
            renderEncoder.setViewport(viewport)
            
            var branchAlpha: Float = 0.8
            var branchViewHeight = Float(viewSize.height / 2)
            renderEncoder.setFragmentBuffer(branchBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentBytes(&pointCountInt, length: MemoryLayout<Int32>.size, index: 1)
            renderEncoder.setFragmentBytes(&scrollOffset, length: MemoryLayout<Float>.size, index: 2)
            renderEncoder.setFragmentBytes(&branchAlpha, length: MemoryLayout<Float>.size, index: 3)
            renderEncoder.setFragmentBytes(&branchViewHeight, length: MemoryLayout<Float>.size, index: 4)
            renderEncoder.setFragmentBytes(&zoom, length: MemoryLayout<Float>.size, index: 5)
            
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            
            // Reset viewport
            let fullViewport = MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(viewSize.width),
                height: Double(viewSize.height),
                znear: 0,
                zfar: 1
            )
            renderEncoder.setViewport(fullViewport)
        }
        
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        
        // GPU Profiling: measure actual GPU execution time
        if enableGPUProfiling {
            let submitTime = CACurrentMediaTime()
            commandBuffer.addCompletedHandler { [weak self] buffer in
                guard let self = self else { return }
                let gpuTime = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0 // ms
                let totalTime = (CACurrentMediaTime() - submitTime) * 1000.0 // ms
                
                self.gpuTimeSum += gpuTime
                self.gpuFrameCount += 1
                
                // Report every second
                let now = CACurrentMediaTime()
                if now - self.lastGPUReportTime >= 1.0 {
                    let avgGPU = self.gpuTimeSum / Double(self.gpuFrameCount)
                    let log = "[Direct] Frames:\(self.gpuFrameCount) AvgGPU:\(String(format: "%.3f", avgGPU))ms Total:\(String(format: "%.3f", totalTime))ms"
                    self.gpuProfileLog.append(log)
                    self.gpuTimeSum = 0
                    self.gpuFrameCount = 0
                    self.lastGPUReportTime = now
                }
            }
        }
        
        commandBuffer.commit()
    }
    
    // MARK: - Cleanup
    
    func clearCache() {
        waveformTextures.removeAll()
        waveformBuffers.removeAll()
    }
    
    func removeTexture(for phraseId: String) {
        waveformTextures.removeValue(forKey: phraseId)
        waveformBuffers.removeValue(forKey: phraseId)
    }
}

