# MusicMill

DJ-oriented Music Machine Learning (ML) system for macOS.

<img width="1201" height="839" alt="image" src="https://github.com/user-attachments/assets/6b628737-5aa7-495e-a52e-b9593d6fdc73" />

## Overview

**Primary Goal**: MusicMill is a generative music instrument that synthesizes new audio in real-time based on your DJ collection. The system learns from your collection's styles and variations, then provides intuitive controls (style, tempo, energy) that allow you to direct the generative output in real-time - similar to how you'd normally switch folders/songs and mix tracks, but creating new music instead of just playing existing tracks.

**Stepping Stone**: Track selection/recommendations serve as a debug helper feature - showing example tracks or segments that match the current desired audio output. This helps verify the model understands your collection correctly.

## Core Concept

Instead of selecting from existing tracks, MusicMill generates new audio in real-time based on:
- **Style controls**: Select the musical style/genre you want
- **Tempo controls**: Set the desired BPM
- **Energy controls**: Adjust intensity/dynamics
- **Mixing controls**: Crossfade, volume, EQ for live performance

The generative model learns from your DJ collection using:
- **Unsupervised learning** from raw audio data
- **Supervised learning** from labels (folder structure, metadata)
- **Rekordbox metadata** (cue points, play history, play counts) when available

## Features

### Working
- **Music Collection Analysis**: Scans directories for audio files (MP3, AAC, WAV, AIFF, M4A)
- **Segment Extraction**: Extracts 30-second training segments from tracks
- **Persistent Storage**: Saves analysis results to `~/Documents/MusicMill/Analysis/`
- **Basic Feature Extraction**: Energy, zero crossing rate, RMS energy
- **Performance Interface**: UI for style/tempo/energy controls

### In Progress
- **Tempo Detection**: Implementing autocorrelation-based BPM detection
- **Key Detection**: Implementing chromagram-based key analysis
- **Granular Synthesis**: Real-time grain-based audio generation
- **RAVE Neural Synthesis**: Deep learning audio generation via PyTorch MPS

### Planned
- **Real-time Generative Synthesis**: Generate new audio using granular synthesis
- **Style-guided Generation**: Control output style using classification
- **RAVE-based Instrument**: Train RAVE on your collection for neural synthesis

### Known Limitations
- DRM-protected files (Apple Music M4A) cannot be analyzed
- Tempo/key detection currently returns null (being fixed)
- Granular synthesizer is skeleton-only (being rewritten)

## Architecture

The system consists of four main components:

1. **Analysis Pipeline**: Scans music collection, extracts audio features, and processes metadata (including Rekordbox data)
2. **Model Training**: 
   - Classification models (MLSoundClassifier) for style understanding
   - Generative models (to be implemented) for audio synthesis
   - Can use both supervised (labels) and unsupervised learning
3. **Generative Engine**: Real-time audio synthesis based on control parameters (style, tempo, energy)
4. **Live Performance Interface**: Real-time control interface for directing generative output

## Requirements

- macOS 13.0 or later
- Xcode 14.0 or later
- Swift 5.9 or later
- M3 Mac (optimized for Apple Silicon)

## Project Structure

```
MusicMill/
├── MusicMill/
│   ├── App/              # App entry point and main views
│   ├── Analysis/         # Audio analysis and feature extraction
│   ├── Generation/       # Synthesis engines (granular, neural)
│   ├── ML/               # Model training (classification)
│   ├── Performance/      # Live performance interface
│   └── Training/         # Training UI
├── scripts/
│   ├── rave_server.py    # RAVE inference server
│   ├── setup_rave.sh     # Python environment setup
│   └── synth.sh          # Quick synthesis test
├── docs/
│   ├── RAVE_INTEGRATION.md  # Neural synthesis documentation
│   └── plans/            # Development plans
└── README.md
```

## Getting Started

1. Open the project in Xcode
2. Select your music collection directory in the Training tab
3. Analyze your collection to extract training samples
4. Train classification models on your collection
5. (Future) Train generative models for synthesis
6. Switch to the Performance tab to use the generative interface

## Usage

### Training Models

1. Open the app and navigate to the "Training" tab
2. Click "Select Directory" and choose your music collection folder
3. Click "Analyze Collection" to scan and prepare training data
4. Train classification models to understand styles in your collection
5. (Future) Train generative models for audio synthesis

### Live Performance (Generative)

1. Navigate to the "Performance" tab
2. Select a style/genre from the dropdown
3. Adjust tempo (BPM) and energy sliders
4. The generative engine synthesizes audio matching your controls
5. Use mixing controls (crossfade, volume, EQ) for live performance
6. (Helper) View example tracks/segments that match current output for debugging

## Synthesis Approaches

MusicMill supports multiple synthesis backends:

### 1. Granular Synthesis (Swift/Native)
- Breaks audio into small "grains" (10-100ms)
- Recombines grains with pitch/time manipulation
- Low latency, runs natively in Swift
- Good for texture and ambient generation

### 2. RAVE Neural Synthesis (PyTorch MPS)
- Deep learning variational autoencoder for audio
- Trained on your music collection
- Generates continuous, musical output
- Runs at **291x realtime** on M3 Max via MPS

#### RAVE Control Mapping

| MusicMill Control | RAVE Implementation |
|-------------------|---------------------|
| **Style** | Interpolate between encoded style anchors |
| **Energy** | Scale latent magnitude (0.3x - 2.0x) |
| **Tempo** | Stretch/compress latent time axis |
| **Timbre** | Individual latent dimension weights |

The key insight: RAVE compresses audio into a low-dimensional latent space (4 dimensions). Each dimension captures different audio characteristics. By encoding reference tracks from your collection and manipulating these latent vectors, you get intuitive control over the generated output.

See `docs/RAVE_INTEGRATION.md` for detailed technical documentation.

## Technical Details

- Uses AVFoundation for audio I/O and real-time synthesis
- MLSoundClassifier for style/genre classification (stepping stone)
- Core ML for model inference (classification)
- **PyTorch MPS** for RAVE neural synthesis (Apple Silicon GPU)
- SwiftUI for the user interface
- Combine framework for reactive programming
- **Challenge**: Real-time audio generation is complex - initial output may be experimental/poor quality, but that's part of the exploration

## Training Data Sources

The system can learn from multiple sources:

1. **Audio Data**: Raw audio files for unsupervised learning
2. **Directory Structure**: Folders as style/genre labels
3. **Rekordbox Metadata**: 
   - Cue points
   - Play history
   - Play counts
   - Other collection metadata

## Notes

- The system organizes training data by directory structure (folders = style labels)
- Audio segments are extracted for training (30-second clips by default)
- Tracks are classified once when loading the collection (for debug/helper features)
- Models are saved locally in Application Support directory
- **Audio generation is the primary challenge** - this is experimental and initial output quality may be limited

## Future Enhancements

- **RAVE Training Pipeline**: Train custom models on your DJ collection
- **Latent Space Exploration**: Tools to find meaningful control axes in trained models
- **Style Anchors**: Encode reference tracks to create style interpolation targets
- **MIDI Integration**: Map external controllers to latent space parameters
- **Multi-layer Synthesis**: Blend granular and neural approaches
- **Recording and Export**: Save generated performances
- **MLX Port**: Native Apple Silicon neural synthesis (alternative to PyTorch)
