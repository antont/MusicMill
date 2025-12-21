# Plan: Improve Rhythm Coherence in Granular Synthesis

## Problem Analysis

Quality metrics revealed the main issue with current granular synthesis:

| Metric | Score | Status |
|--------|-------|--------|
| Noise Match | 99.9% | Excellent |
| Clarity Match | 100% | Excellent |
| **Rhythm Match** | **38.6%** | **Poor** |

The output has **onset regularity of 0.61** (chaotic) because grains are scheduled randomly without respect to the source's rhythmic structure.

## Root Cause

Current grain scheduling in `GranularSynthesizer.swift`:
```swift
// Grains scheduled at fixed rate (grainDensity grains/sec)
// Position within source is random (positionJitter)
// No alignment to beats or onsets
```

This creates irregular, chaotic output regardless of source rhythm.

## Proposed Solutions

### Option A: Beat-Aligned Grain Scheduling (Recommended)

**Approach**: Schedule grains to align with detected beats from source audio.

**Implementation**:
1. Detect beats/onsets in source audio during loading
2. Store onset positions as "preferred grain start points"
3. When scheduling grains, snap to nearest onset position
4. Add small jitter around onsets for variation

**Pros**: Preserves rhythmic feel of source
**Cons**: Requires pre-analysis of source

### Option B: Tempo-Locked Grain Rate

**Approach**: Set grain density to match source tempo.

**Implementation**:
1. Extract tempo from source during loading
2. Set grainDensity = tempo / 60 * subdivision (e.g., 8th notes)
3. Grains fire at rhythmically meaningful intervals

**Pros**: Simple, maintains pulse
**Cons**: May not align with actual beat positions

### Option C: Onset-Triggered Grains

**Approach**: Trigger grains at detected onsets in real-time.

**Implementation**:
1. Pre-detect all onsets in source
2. As playback position advances, trigger grain at each onset
3. Use onset envelope as grain amplitude

**Pros**: Most faithful to source rhythm
**Cons**: Loses granular "texture" effect

### Option D: Hybrid Approach (Best of All)

**Approach**: Combine tempo-locked rate with beat-aligned positions.

**Implementation**:
1. Extract tempo AND onset positions from source
2. Set base grain rate from tempo
3. Snap grain positions to nearest detected onset
4. Allow configurable blend between random and beat-aligned

## Recommended Implementation: Option D (Hybrid)

### Phase 1: Add Onset Detection to Source Loading

In `GranularSynthesizer.swift`:
```swift
struct SourceBuffer {
    let buffer: AVAudioPCMBuffer
    let tempo: Double?
    let onsets: [TimeInterval]  // NEW: detected onset times
}

func loadSource(from url: URL, identifier: String) throws {
    // ... existing loading ...
    
    // NEW: Detect onsets for rhythmic alignment
    let onsets = detectOnsets(buffer)
    sourceBuffers.append(SourceBuffer(buffer: buffer, tempo: tempo, onsets: onsets))
}
```

### Phase 2: Beat-Aligned Grain Scheduling

Update `scheduleNewGrain()`:
```swift
private func scheduleNewGrain(params: GrainParameters) {
    // Get nearest onset position instead of random
    let basePosition = currentPlaybackPosition
    let nearestOnset = findNearestOnset(to: basePosition, onsets: source.onsets)
    
    // Blend between random and beat-aligned based on parameter
    let alignmentStrength = params.rhythmAlignment // NEW: 0-1
    let randomPosition = basePosition + randomJitter
    let finalPosition = lerp(randomPosition, nearestOnset, alignmentStrength)
    
    // Create grain at this position
    ...
}
```

### Phase 3: Tempo-Synced Grain Rate

Add tempo synchronization option:
```swift
struct GrainParameters {
    // ... existing ...
    var rhythmAlignment: Float = 0.8  // NEW: 0=random, 1=beat-locked
    var tempoSync: Bool = true        // NEW: sync grain rate to source tempo
}
```

### Phase 4: Update Quality Metrics

After implementation, rhythm match should improve from 38.6% to 70%+.

## Files to Modify

| File | Changes |
|------|---------|
| `GranularSynthesizer.swift` | Add onset detection, beat-aligned scheduling |
| `FeatureExtractor.swift` | Expose onset detection as public API |
| `SampleLibrary.swift` | Store onset positions with samples |
| `GranularSynthesizer.GrainParameters` | Add rhythmAlignment, tempoSync |

## Success Criteria

- Rhythm Match improves from 38.6% to **70%+**
- Output sounds more musical/rhythmic to human listener
- Maintains granular texture while preserving pulse

## Estimated Effort

- Phase 1 (onset detection): 1-2 hours
- Phase 2 (beat-aligned scheduling): 2-3 hours  
- Phase 3 (tempo sync): 1 hour
- Phase 4 (testing): 1 hour

**Total: ~6 hours**

