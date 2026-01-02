#include <metal_stdlib>
using namespace metal;

// Vertex shader for full-screen quad
// Using interleaved vertex data: position (x,y) and texCoord (u,v)
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

// Fragment shader for scrolling waveform texture
// Samples the pre-rendered waveform texture with UV offset based on playback progress
// For centered playhead: scrollOffset positions the texture so playhead (at progress) is at screen center
fragment float4 fragment_scroll(VertexOut in [[stage_in]],
                                texture2d<float> waveformTexture [[texture(0)]],
                                sampler textureSampler [[sampler(0)]],
                                constant float &scrollOffset [[buffer(0)]],
                                constant float &alpha [[buffer(1)]]) {
    // Calculate UV coordinates with scroll offset for centered playhead
    // scrollOffset is 0-1 (playback progress in the waveform)
    // Screen center is at u=0.5, we want texture position scrollOffset to appear there
    float screenU = in.texCoord.x;
    
    // Map screen U (0-1) to texture U, centered on scrollOffset
    // When screenU=0.5 (center), we want textureU=scrollOffset
    // When screenU=0 (left edge), we want textureU=scrollOffset-0.5
    // When screenU=1 (right edge), we want textureU=scrollOffset+0.5
    float textureU = scrollOffset + (screenU - 0.5);
    
    // Clamp to valid range [0, 1] to avoid sampling outside texture
    // The sampler uses clampToEdge, so values outside [0,1] will sample edge pixels
    textureU = clamp(textureU, 0.0, 1.0);
    
    float2 uv = float2(textureU, in.texCoord.y);
    
    // Sample texture with linear filtering for smooth scrolling
    // The sampler is configured with linear min/mag filter for smooth interpolation between pixels
    float4 color = waveformTexture.sample(textureSampler, uv);
    
    // Apply alpha for "played" portion dimming (left of playhead at screen center)
    // screenU < 0.5 means we're to the left of center (played portion)
    float finalAlpha = (screenU < 0.5) ? color.a * alpha * 0.35 : color.a * alpha;
    
    // Draw playhead line at screen center (u = 0.5)
    // Draw a 2-pixel wide line for visibility
    float playheadWidth = 0.002; // ~2 pixels at typical resolution
    if (abs(screenU - 0.5) < playheadWidth) {
        return float4(1.0, 1.0, 1.0, 1.0); // White playhead line
    }
    
    // Draw playhead triangle at top (if near top of screen and at center)
    if (in.texCoord.y > 0.95 && abs(screenU - 0.5) < 0.01) {
        // Simple triangle approximation
        float triangleWidth = 0.01;
        float triangleHeight = 0.05;
        if (abs(screenU - 0.5) < triangleWidth && in.texCoord.y > (1.0 - triangleHeight)) {
            return float4(1.0, 0.5, 0.0, 1.0); // Orange triangle (matching playhead color)
        }
    }
    
    return float4(color.rgb, finalAlpha);
}

// Fragment shader for rendering RGB waveform bars directly from amplitude data
// This is used during texture generation phase
struct WaveformBarParams {
    float bassAmp;
    float midAmp;
    float highAmp;
    float centerY;
    float maxHeight;
    float barX;
    float barWidth;
    float viewHeight;
};

fragment float4 fragment_waveform_bar(VertexOut in [[stage_in]],
                                     constant WaveformBarParams &params [[buffer(0)]]) {
    float2 pos = in.position.xy;
    float x = pos.x;
    float y = pos.y;
    
    // Check if we're within the bar's X range
    if (x < params.barX || x > params.barX + params.barWidth) {
        discard_fragment();
    }
    
    float centerY = params.centerY;
    float distFromCenter = abs(y - centerY);
    
    // Calculate bar heights
    float bassH = params.bassAmp * params.maxHeight * 0.5;
    float midH = params.midAmp * params.maxHeight * 0.35;
    float highH = params.highAmp * params.maxHeight * 0.15;
    
    float4 color = float4(0.0);
    
    // Bass (innermost, blue)
    if (distFromCenter <= bassH / 2.0) {
        color = float4(0.2, 0.4, 0.9, 1.0); // Blue
    }
    // Mid (green)
    else if (distFromCenter <= (bassH + midH) / 2.0) {
        color = float4(0.3, 0.8, 0.3, 1.0); // Green
    }
    // High (outermost, orange)
    else if (distFromCenter <= (bassH + midH + highH) / 2.0) {
        color = float4(1.0, 0.5, 0.2, 1.0); // Orange
    }
    else {
        discard_fragment();
    }
    
    return color;
}

// MARK: - Direct Waveform Rendering

// Waveform point structure for direct rendering
struct WaveformPoint {
    float low;
    float mid;
    float high;
};

// Fragment shader for direct waveform rendering from WaveformData buffer
// Renders RGB bars directly from amplitude data without texture generation
// OPTIMIZED: Reduced branching, early exits, step functions
// Supports zoom: zoomLevel=1.0 shows full waveform, zoomLevel=2.0 shows half (2x zoom), etc.
fragment float4 fragment_waveform_direct(VertexOut in [[stage_in]],
                                        device const WaveformPoint* waveformData [[buffer(0)]],
                                        constant int &pointCount [[buffer(1)]],
                                        constant float &scrollOffset [[buffer(2)]],
                                        constant float &alpha [[buffer(3)]],
                                        constant float &viewHeight [[buffer(4)]],
                                        constant float &zoomLevel [[buffer(5)]]) {
    float screenU = in.texCoord.x;
    float screenV = in.texCoord.y;
    
    // Early exit for playhead line (white vertical line at center)
    float playheadDist = abs(screenU - 0.5);
    if (playheadDist < 0.002) {
        return float4(1.0, 1.0, 1.0, 1.0);
    }
    
    // Playhead triangle at top
    if (screenV > 0.95 && playheadDist < 0.01) {
        return float4(1.0, 0.5, 0.0, 1.0);
    }
    
    // Map screen U to waveform point index, centered on scrollOffset
    // zoomLevel affects how much of the waveform is visible
    // zoomLevel=1.0: full waveform visible (screenU 0-1 maps to waveform 0-1)
    // zoomLevel=2.0: half waveform visible (2x zoom, screenU 0-1 maps to 0.25 of waveform)
    // zoomLevel=4.0: quarter waveform visible (4x zoom), etc.
    float viewSpan = 1.0 / max(zoomLevel, 0.1);  // How much of waveform is visible (0-1)
    float halfSpan = viewSpan * 0.5;
    
    // Center the view on scrollOffset, scaled by zoom
    float textureU = scrollOffset + (screenU - 0.5) * viewSpan;
    textureU = clamp(textureU, 0.0, 1.0);
    
    int pointIndex = clamp(int(textureU * float(pointCount - 1) + 0.5), 0, pointCount - 1);
    
    // Read waveform data
    WaveformPoint point = waveformData[pointIndex];
    
    // Calculate vertical position
    float halfHeight = viewHeight * 0.5;
    float maxHeight = viewHeight * 0.9;
    float screenY = screenV * viewHeight;
    float distFromCenter = abs(screenY - halfHeight);
    
    // Calculate bar heights (half because we mirror)
    float bassH = point.low * maxHeight * 0.25;
    float midH = point.mid * maxHeight * 0.175;
    float highH = point.high * maxHeight * 0.075;
    float totalHeight = bassH + midH + highH;
    
    // Early exit if outside bar
    if (distFromCenter > totalHeight) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    
    // Determine color using step functions (branchless)
    float inBass = step(distFromCenter, bassH);
    float inMid = step(distFromCenter, bassH + midH) - inBass;
    float inHigh = 1.0 - inBass - inMid;
    
    float4 color = inBass * float4(0.2, 0.4, 0.9, 1.0) +
                   inMid * float4(0.3, 0.8, 0.3, 1.0) +
                   inHigh * float4(1.0, 0.5, 0.2, 1.0);
    
    // Apply alpha dimming for played portion
    float dimFactor = mix(0.35, 1.0, step(0.5, screenU));
    return float4(color.rgb, color.a * alpha * dimFactor);
}

