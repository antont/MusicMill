# Plan: Variety and Evolution in Granular Synthesis

## Current Problem

The synthesis loops a short sample repetitively despite high quality scores (90.9%). Missing:
- **Variety**: Only uses one source at a time
- **Evolution**: Position stays static, doesn't scan through source
- **Scale**: Only 4 tracks analyzed, need 200+

## Goals

1. **Multi-source synthesis** with smooth crossfading between segments
2. **Position evolution** - scan through sources over time
3. **Scale analysis** to handle 200+ tracks efficiently
4. **Add variety metrics** to QA to detect repetitive output

---

## Part 1: Multi-Source Synthesis

### Current State
- `currentSourceIndex` selects ONE source buffer
- All grains come from same source
- No crossfading between sources

### Proposed Changes

Add to `GrainParameters`:
```swift
var sourceBlend: Float = 0.0      // 0-1 blend between two sources
var autoSourceSwitch: Bool = true // Automatically switch sources
var switchInterval: TimeInterval = 8.0 // Seconds between source switches
```

Update `scheduleNewGrain`:
```swift
// Select source based on blend
let sourceA = currentSourceIndex
let sourceB = (currentSourceIndex + 1) % sourceBuffers.count

// Alternate grains between sources based on blend
if Float.random(in: 0...1) < sourceBlend {
    // Grain from source B
} else {
    // Grain from source A
}
```

Add source switching timer:
```swift
private var timeSinceSourceSwitch: TimeInterval = 0.0

// In render loop:
if params.autoSourceSwitch {
    timeSinceSourceSwitch += frameDuration
    if timeSinceSourceSwitch >= params.switchInterval {
        currentSourceIndex = (currentSourceIndex + 1) % sourceBuffers.count
        timeSinceSourceSwitch = 0
    }
}
```

---

## Part 2: Position Evolution

### Current State
- `currentPosition` is set externally but doesn't auto-evolve
- Grains always come from same region of source

### Proposed Changes

Add to `GrainParameters`:
```swift
var positionEvolution: Float = 0.1  // How fast position scans (0=static, 1=fast)
var evolutionMode: EvolutionMode = .forward

enum EvolutionMode {
    case forward    // Scan forward through source
    case backward   // Scan backward
    case pingPong   // Back and forth
    case random     // Jump to random positions
}
```

Update render loop:
```swift
// Evolve position over time
let evolutionSpeed = params.positionEvolution * 0.01 // Adjust scale
switch params.evolutionMode {
case .forward:
    currentPosition += evolutionSpeed
    if currentPosition >= 1.0 { currentPosition = 0.0 }
case .backward:
    currentPosition -= evolutionSpeed
    if currentPosition <= 0.0 { currentPosition = 1.0 }
case .pingPong:
    currentPosition += evolutionSpeed * evolutionDirection
    if currentPosition >= 1.0 || currentPosition <= 0.0 {
        evolutionDirection *= -1
    }
case .random:
    if timeSincePositionJump >= 2.0 { // Every 2 seconds
        currentPosition = Float.random(in: 0...1)
        timeSincePositionJump = 0
    }
}
```

---

## Part 3: Scale Analysis (200+ tracks)

### Current State
- Manual directory selection in UI
- All segments loaded into memory
- Analysis stored per-collection

### Proposed Changes

#### 3.1 Batch Analysis CLI
```swift
// New: AnalysisBatch.swift
class AnalysisBatch {
    /// Analyzes multiple directories in sequence
    func analyzeDirectories(_ urls: [URL]) async throws -> BatchResult
    
    /// Resumes interrupted analysis
    func resumeAnalysis(from checkpoint: URL) async throws
    
    /// Progress callback
    var onProgress: ((Int, Int, String) -> Void)?
}
```

#### 3.2 Lazy Segment Loading
```swift
// SampleLibrary changes
class SampleLibrary {
    // Don't load all buffers at once
    private var segmentMetadata: [SegmentInfo] = []  // Lightweight
    private var loadedBuffers: [String: AVAudioPCMBuffer] = [] // LRU cache
    private let maxLoadedBuffers = 20 // Keep only 20 in memory
    
    /// Loads buffer on demand
    func getBuffer(for segment: SegmentInfo) async throws -> AVAudioPCMBuffer
}
```

#### 3.3 Smart Segment Selection
```swift
// Select segments that match current performance parameters
func selectSegments(
    style: String?,
    tempo: ClosedRange<Double>?,
    energy: ClosedRange<Double>?,
    count: Int = 5
) -> [SegmentInfo]
```

---

## Part 4: Variety Metrics in QA

### New Metrics

Add to `FeatureExtractor.AudioFeatures`:
```swift
let selfSimilarity: Double  // How repetitive is the audio (0=varied, 1=loop)
let spectralVariance: Double // How much spectrum changes over time
```

Add to `QualityScore`:
```swift
let varietyScore: Double // Penalize repetitive output
```

### Implementation

```swift
/// Calculates self-similarity using autocorrelation at longer lags
func calculateSelfSimilarity(audioData: [Float]) -> Double {
    // Check correlation at 1, 2, 4, 8 second lags
    // High correlation at short lags = repetitive
}

/// Calculates spectral variance over time
func calculateSpectralVariance(audioData: [Float]) -> Double {
    // Compute spectrogram
    // Measure variance across time frames
}
```

---

## Implementation Order

### Phase 1: Position Evolution (Quick Win)
- Add `positionEvolution` and `evolutionMode` to GrainParameters
- Update render loop to evolve position
- **Immediate improvement** in perceived variety

### Phase 2: Multi-Source Blending
- Add `sourceBlend` and `autoSourceSwitch`
- Implement source switching timer
- **Mixes content** from different segments

### Phase 3: Variety Metrics
- Add `selfSimilarity` and `spectralVariance` to features
- Add `varietyScore` to QualityAnalyzer
- **Detects** when output is repetitive

### Phase 4: Scale to 200+ Tracks
- Implement batch analysis
- Add lazy loading with LRU cache
- Add smart segment selection
- **Enables** large collection support

---

## Files to Modify

| Phase | File | Changes |
|-------|------|---------|
| 1 | `GranularSynthesizer.swift` | Add evolution parameters and logic |
| 2 | `GranularSynthesizer.swift` | Add source blending and switching |
| 3 | `FeatureExtractor.swift` | Add variety metrics |
| 3 | `QualityAnalyzer.swift` | Add varietyScore |
| 4 | `AnalysisBatch.swift` (new) | Batch analysis support |
| 4 | `SampleLibrary.swift` | Lazy loading, smart selection |

## Success Criteria

- Position evolution: Output no longer sounds like a static loop
- Multi-source: Audible variety from different segments
- Variety metrics: Self-similarity < 0.5 for good output
- Scale: Can analyze and use 200+ tracks

## Estimated Effort

- Phase 1: 1-2 hours
- Phase 2: 2-3 hours
- Phase 3: 2-3 hours
- Phase 4: 4-6 hours

**Total: ~12-14 hours**


