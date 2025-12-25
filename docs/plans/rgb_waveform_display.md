# RGB Waveform Display Plan

## Goal

Add DJ-style RGB waveforms to phrase boxes showing:
- Frequency-colored waveform (blue=bass, green=mid, red=high)
- Playback position indicator
- Both main strip and branch cards

## Implementation

### Phase 1: Waveform Data Generation (Python)

**File: `scripts/build_phrase_graph.py`**

Add waveform extraction after loading each audio segment:

```python
def extract_waveform_rgb(audio_path: str, num_points: int = 150) -> dict:
    """Extract low-res RGB waveform data for display."""
    y, sr = librosa.load(audio_path, sr=22050, mono=False)
    if y.ndim == 1:
        y = np.array([y, y])  # Mono to stereo
    
    # Mix to mono for analysis
    y_mono = librosa.to_mono(y)
    
    # Compute STFT for frequency bands
    D = np.abs(librosa.stft(y_mono, n_fft=2048, hop_length=512))
    
    # Split into frequency bands
    freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)
    low_mask = freqs < 250      # Bass
    mid_mask = (freqs >= 250) & (freqs < 4000)  # Mids
    high_mask = freqs >= 4000   # Highs
    
    low = np.mean(D[low_mask, :], axis=0)
    mid = np.mean(D[mid_mask, :], axis=0)
    high = np.mean(D[high_mask, :], axis=0)
    
    # Resample to num_points
    low_resampled = np.interp(
        np.linspace(0, len(low)-1, num_points),
        np.arange(len(low)), low
    )
    # ... same for mid, high
    
    # Normalize to 0-1
    max_val = max(low.max(), mid.max(), high.max()) + 1e-6
    
    return {
        "low": (low_resampled / max_val).tolist(),
        "mid": (mid_resampled / max_val).tolist(), 
        "high": (high_resampled / max_val).tolist(),
        "points": num_points
    }
```

Add to PhraseNode dataclass:
```python
waveform: Optional[dict] = None  # {low: [], mid: [], high: [], points: int}
```

### Phase 2: Swift Data Model

**File: `MusicMill/Analysis/PhraseDatabase.swift`**

```swift
struct WaveformData: Codable {
    let low: [Float]   // Bass amplitude (0-1) per point
    let mid: [Float]   // Mid amplitude (0-1) per point  
    let high: [Float]  // High amplitude (0-1) per point
    let points: Int
}

// Add to PhraseNode:
let waveform: WaveformData?
```

### Phase 3: Waveform View Component

**File: `MusicMill/Performance/WaveformView.swift`** (new)

```swift
struct WaveformView: View {
    let waveform: WaveformData
    let playbackProgress: Double  // 0-1, current position
    let height: CGFloat
    
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let pointWidth = size.width / CGFloat(waveform.points)
                
                for i in 0..<waveform.points {
                    let x = CGFloat(i) * pointWidth
                    let played = Double(i) / Double(waveform.points) < playbackProgress
                    
                    // Stack: bass (bottom), mid, high (top)
                    let bassH = CGFloat(waveform.low[i]) * size.height * 0.4
                    let midH = CGFloat(waveform.mid[i]) * size.height * 0.35
                    let highH = CGFloat(waveform.high[i]) * size.height * 0.25
                    
                    // Colors (dimmed if played)
                    let alpha: Double = played ? 0.4 : 1.0
                    
                    // Bass - blue/purple
                    let bassRect = CGRect(x: x, y: size.height - bassH, width: pointWidth, height: bassH)
                    context.fill(Path(bassRect), with: .color(.blue.opacity(alpha)))
                    
                    // Mid - green  
                    let midRect = CGRect(x: x, y: size.height - bassH - midH, width: pointWidth, height: midH)
                    context.fill(Path(midRect), with: .color(.green.opacity(alpha)))
                    
                    // High - orange/red
                    let highRect = CGRect(x: x, y: size.height - bassH - midH - highH, width: pointWidth, height: highH)
                    context.fill(Path(highRect), with: .color(.orange.opacity(alpha)))
                }
                
                // Playback position line
                let posX = size.width * playbackProgress
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: posX, y: 0)); p.addLine(to: CGPoint(x: posX, y: size.height)) },
                    with: .color(.white),
                    lineWidth: 2
                )
            }
        }
        .frame(height: height)
    }
}
```

### Phase 4: Integration

**Update `phraseBox()` in HyperPhraseView.swift:**
- Replace energy bar with WaveformView
- Pass current playback progress for active phrase

**Update `CompactPhraseCard`:**
- Add smaller WaveformView (no playback indicator needed)

### Phase 5: Playback Progress Tracking

**Update `HyperPhrasePlayer.swift`:**
- Add `@Published var playbackProgress: Double = 0` 
- Update in render loop: `playbackProgress = Double(playbackPosition) / Double(bufferLength)`

## Data Flow

```
Python Analysis → phrase_graph.json (with waveform arrays)
                        ↓
Swift PhraseDatabase.load() → PhraseNode.waveform
                        ↓
HyperPhraseView → WaveformView (renders Canvas)
                        ↓
HyperPhrasePlayer.playbackProgress → animates position
```

## File Changes Summary

1. `scripts/build_phrase_graph.py` - Add waveform extraction
2. `MusicMill/Analysis/PhraseDatabase.swift` - Add WaveformData struct
3. `MusicMill/Performance/WaveformView.swift` - New file
4. `MusicMill/Performance/HyperPhraseView.swift` - Use WaveformView
5. `MusicMill/Generation/HyperPhrasePlayer.swift` - Publish playback progress

## Estimated Points per Phrase

- 150 points × 3 bands × 4 bytes = ~1.8KB per phrase
- 603 phrases × 1.8KB = ~1MB added to phrase_graph.json
- Acceptable size increase

