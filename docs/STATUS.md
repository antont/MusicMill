# MusicMill Project Status

**Last Updated**: December 21, 2025 (Late Afternoon)

## Executive Summary

MusicMill now has **complete core analysis and granular synthesis implementation**. The architecture is complete with proper tempo/key detection, FFT-based spectral analysis, and a real-time granular synthesizer using AVAudioSourceNode render callbacks. Audio output tests are in place.

## Current State

### ✅ Implemented & Working

| Component | Status | Notes |
|-----------|--------|-------|
| Directory scanning | **Working** | Finds MP3, WAV, AIFF, M4A files |
| Segment extraction | **Working** | Creates 30-second training segments |
| **Tempo detection** | **Working** | Autocorrelation-based BPM detection (60-200 BPM) |
| **Key detection** | **Working** | Chromagram + Krumhansl-Schmuckler profiles |
| **Spectral centroid** | **Working** | FFT-based calculation (returns Hz values) |
| **Granular synthesizer** | **Working** | AVAudioSourceNode render callback, grain pool |
| UI scaffold | **Working** | TrainingView, PerformanceView complete |
| Style organization | **Working** | Uses folder structure as labels |
| SampleLibrary | **Working** | Load from analysis, lazy buffer loading |
| SampleGenerator | **Working** | Connects library to granular synthesizer |
| **GenerationController** | **Working** | Loads samples on Performance tab open |
| **Audio output tests** | **Working** | Tests granular synthesis audio capture |

### 🔧 Known Limitations

| Component | Issue | Notes |
|-----------|-------|-------|
| **xcodebuild audio** | No hardware | Tests pass but audio capture limited in sandbox |
| **Apple Music DRM** | Can't read | DRM-protected M4A files will fail to analyze |

### ❌ Skeleton/Future

| Component | Issue | Priority |
|-----------|-------|----------|
| **Neural synthesis** | Returns silence - placeholder only | LOW (future) |
| **MLSoundClassifier** | API usage needs fixing | MEDIUM |
| **Rekordbox parsing** | Skeleton only | LOW |

### 🔧 Skeletons (Code Exists, Not Functional)

- `SpectralAnalyzer.swift` - Has structure, not tested
- `SegmentExtractor.swift` - Onset detection outline only
- `StructureAnalyzer.swift` - Chord detection outline only
- `RekordboxParser.swift` - XML parsing outline only
- `NeuralGenerator.swift` - Returns zeros

## Analysis Results

Analyzed BLVCKCEILING tracks:

```
Total: 4+ audio files → 20+ training segments
Storage: ~/Documents/MusicMill/Analysis/BLVCKCEILING_*/

Features extracted:
- Tempo (BPM): Autocorrelation-based detection
- Key: Chromagram + key profile correlation  
- Energy: RMS-based loudness measure
- Spectral Centroid: FFT-based brightness (Hz)
- Zero Crossing Rate: Texture measure
```

## How to Test

### 1. Run All Tests
```bash
cd /Users/tonialatalo/src/MusicMill
xcodebuild test -project MusicMill.xcodeproj -scheme MusicMill \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ./DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

### 2. Run the App
```bash
open DerivedData/Build/Products/Debug/MusicMill.app
```

Then:
1. Go to **Training** tab
2. Click **Select Directory** and choose a music folder (MP3 or non-DRM M4A)
3. Click **Analyze Collection**
4. Go to **Performance** tab
5. Wait for "Ready: X samples loaded" message
6. Click **Play** to start granular synthesis

### 3. Check Analysis Results
```bash
cat ~/Documents/MusicMill/Analysis/*/analysis.json | python3 -m json.tool | head -50
ls ~/Documents/MusicMill/Analysis/*/Segments/
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        MusicMill                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────────┐    │
│  │  Analysis    │───▶│SampleLibrary │───▶│GranularSynth   │    │
│  │  Pipeline    │    │   (indexed)  │    │   (real-time)  │    │
│  └──────────────┘    └──────────────┘    └────────────────┘    │
│         │                    │                    │             │
│         ▼                    ▼                    ▼             │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────────┐    │
│  │FeatureExtract│    │SampleGenerat │    │ AVAudioEngine  │    │
│  │ tempo, key,  │    │ style/tempo  │    │ audio output   │    │
│  │ energy, etc  │    │ matching     │    │                │    │
│  └──────────────┘    └──────────────┘    └────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              GenerationController                        │   │
│  │    Links Performance UI sliders → Synthesis Engine       │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Key Files

| File | Purpose |
|------|---------|
| `FeatureExtractor.swift` | Tempo, key, energy, spectral features |
| `GranularSynthesizer.swift` | Real-time grain scheduling & mixing |
| `SampleLibrary.swift` | Indexed sample storage with matching |
| `SampleGenerator.swift` | High-level generation with parameters |
| `GenerationController.swift` | Connects UI to synthesis engine |
| `AnalysisStorage.swift` | Persists analysis to Documents |

## File Locations

- **Analysis results**: `~/Documents/MusicMill/Analysis/{collection_id}/`
- **Segments**: `~/Documents/MusicMill/Analysis/{collection_id}/Segments/`
- **Models**: `~/Library/Application Support/MusicMill/Models/`
