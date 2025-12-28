# MusicMill

HyperMusic: Navigate your music collection as a graph of interconnected phrases. DJ-oriented music navigation and performance system for macOS.

<img width="1201" height="839" alt="image" src="https://github.com/user-attachments/assets/6b628737-5aa7-495e-a52e-b9593d6fdc73" />

## Overview

**Primary Focus**: MusicMill's **HyperMusic** system transforms your music collection into a navigable graph of interconnected musical phrases. Instead of playing songs linearly, you can branch between compatible phrases from different tracks, enabling seamless DJ-style transitions across your entire collection.

**Core Concept**: Music is analyzed and broken into structural phrases (intro, verse, chorus, drop, outro). Each phrase is connected to compatible phrases from other tracks based on musical similarity (tempo, key, energy, spectral characteristics). Navigate the graph to create unique mixes that flow naturally between tracks.

## HyperMusic System

### How It Works

1. **Analysis**: Your music collection is analyzed to extract:
   - Musical phrases/segments (detected via structure analysis)
   - Tempo (BPM) and key information
   - Energy levels and spectral characteristics
   - Beat grids and downbeat positions
   - RGB waveforms for visual feedback

2. **Graph Construction**: Phrases are connected into a weighted graph where edges represent musical compatibility:
   - **Tempo compatibility**: Same BPM, half-time, or double-time relationships
   - **Key compatibility**: Same key, relative major/minor, or circle of fifths neighbors
   - **Energy matching**: Similar energy levels or complementary builds/drops
   - **Spectral similarity**: Timbral matching via spectral centroid

3. **Navigation**: Play songs normally or tap any compatible phrase to branch to a different track:
   - **Same Track Sequential**: Gapless playback within the same song
   - **Cross-Track Transition**: Switch to compatible phrases from other tracks at phrase boundaries
   - **Beat-aligned cuts**: (Future) Immediate transitions synchronized to beats

## Features

### HyperMusic (Current Focus)
- **Phrase Graph Analysis**: Analyzes music collection and builds navigable phrase graph
- **Musical Compatibility Scoring**: Links phrases based on tempo, key, energy, and spectral similarity
- **Graph Navigation Interface**: Visual timeline with branch options to compatible phrases
- **Dual-Deck DJ Controls**: Professional mixing interface with cue/preview deck
- **RGB Waveform Display**: DJ-style waveform visualization (bass/mid/high frequencies)
- **Beat Grid Visualization**: Shows beat positions and phrase boundaries
- **Phrase Boundary Transitions**: Smooth switching between tracks at phrase boundaries
- **Persistent Graph Storage**: Saves phrase graph to disk for fast loading

### Experimental / Future Work
- **ML Classification**: Style/genre classification models (early experiments)
- **Granular Synthesis**: Real-time grain-based audio generation (experimental)
- **RAVE Neural Synthesis**: Deep learning audio generation via PyTorch MPS (research)
- **Real-time Generative Synthesis**: Generate new audio based on style/tempo/energy controls (future)

### Known Limitations
- DRM-protected files (Apple Music M4A) cannot be analyzed
- Beat-aligned immediate cuts not yet implemented (phrase boundary transitions work)
- DJ-style transitions (crossfade, EQ swap, filter sweep) reserved for future implementation

## Architecture

The HyperMusic system consists of three main components:

1. **Analysis Pipeline** (`scripts/analyze_library.py`, `scripts/build_phrase_graph.py`):
   - Scans music collection for audio files (MP3, AAC, WAV, AIFF, M4A)
   - Extracts musical phrases/segments via structure analysis
   - Computes tempo, key, energy, spectral features, and beat grids
   - Builds weighted phrase graph with compatibility links
   - Generates RGB waveforms for visual display

2. **Phrase Database** (`MusicMill/Analysis/PhraseDatabase.swift`):
   - Manages phrase graph persistence (JSON format)
   - Provides graph queries (find compatible phrases, get links, etc.)
   - Handles graph loading and caching

3. **Playback & Performance Interface** (`MusicMill/Performance/HyperPhraseView.swift`, `MusicMill/Generation/HyperPhrasePlayer.swift`):
   - Graph-aware playback engine with phrase navigation
   - Dual-deck DJ interface with cue/preview capabilities
   - Real-time waveform visualization
   - Transition engine (reserved for future DJ-style transitions)

## Requirements

- macOS 13.0 or later
- Xcode 14.0 or later
- Swift 5.9 or later
- M3 Mac (optimized for Apple Silicon)

## Project Structure

```
MusicMill/
├── MusicMill/
│   ├── App/                    # App entry point and main views
│   ├── Analysis/               # Audio analysis and phrase graph
│   │   ├── PhraseDatabase.swift    # Graph data model and queries
│   │   ├── FeatureExtractor.swift  # Tempo, key, energy, spectral features
│   │   ├── StructureAnalyzer.swift  # Phrase/segment detection
│   │   └── ...
│   ├── Generation/             # Playback engines
│   │   ├── HyperPhrasePlayer.swift  # Graph-aware phrase playback
│   │   ├── TransitionEngine.swift   # DJ-style transitions (future)
│   │   └── ...
│   ├── Performance/            # Performance interface
│   │   ├── HyperPhraseView.swift    # Main graph navigation UI
│   │   ├── WaveformView.swift       # RGB waveform display
│   │   ├── Deck.swift               # Dual-deck DJ controls
│   │   └── ...
│   ├── ML/                     # ML experiments (classification)
│   └── Training/               # Training UI (for ML models)
├── scripts/
│   ├── analyze_library.py      # Music collection analysis
│   ├── build_phrase_graph.py   # Phrase graph construction
│   ├── rave_server.py          # RAVE inference (experimental)
│   └── ...
├── docs/
│   ├── plans/hypermusic_playback.md  # HyperMusic documentation
│   └── ...
└── README.md
```

## Getting Started

1. **Analyze Your Collection**: Run the analysis script to build the phrase graph:
   ```bash
   python3 scripts/analyze_library.py /path/to/your/music/collection
   python3 scripts/build_phrase_graph.py
   ```

2. **Open in Xcode**: Build and run the MusicMill app

3. **Load the Graph**: The app will automatically load the phrase graph from `~/Documents/MusicMill/Analysis/`

4. **Navigate**: Use the HyperPhraseView to navigate through your collection as a graph

## Usage

### Building the Phrase Graph

1. **Analyze Library**: Run `scripts/analyze_library.py` to extract features from your music collection
   - Detects phrases/segments, tempo, key, energy, beat grids
   - Outputs analysis JSON files

2. **Build Graph**: Run `scripts/build_phrase_graph.py` to construct the phrase graph
   - Creates weighted links between compatible phrases
   - Generates RGB waveforms for visualization
   - Outputs `phrase_graph.json`

### HyperMusic Navigation

1. **Start Playback**: The app loads the phrase graph and starts playing from a random phrase
2. **View Timeline**: See the current phrase in the center with compatible branches
3. **Navigate**: Tap any compatible phrase to queue a transition at the next phrase boundary
4. **DJ Controls**: Use dual-deck controls for cue/preview and professional mixing
5. **Waveform Visualization**: Monitor RGB waveforms showing bass/mid/high frequencies

## Musical Compatibility Scoring

Phrases are linked in the graph based on weighted compatibility scores:

- **Tempo Score**: Same BPM (±5%), half-time, or double-time relationships
- **Key Score**: Same key, relative major/minor, or circle of fifths neighbors  
- **Energy Score**: Similar energy levels or complementary builds/drops
- **Spectral Score**: Timbral matching via spectral centroid similarity

Each link has a total weight (0-1) and suggested transition type (crossfade, EQ swap, cut, filter).

## Experimental Features

### ML Classification (Early Experiments)
- Style/genre classification using MLSoundClassifier
- Can be used for filtering or organizing phrases by style
- See `MusicMill/ML/` for implementation

### Generative Synthesis (Research/Future)
- **Granular Synthesis**: Real-time grain-based audio generation (experimental)
- **RAVE Neural Synthesis**: Deep learning audio generation via PyTorch MPS (research)
  - See `docs/RAVE_INTEGRATION.md` for technical details
  - Runs at **291x realtime** on M3 Max via MPS
  - Experimental control mapping: style interpolation, energy scaling, tempo stretching

## Technical Details

- **Audio Analysis**: Uses librosa (Python) for tempo, key, energy, spectral analysis, and phrase detection
- **Graph Storage**: Phrase graph stored as JSON in `~/Documents/MusicMill/Analysis/`
- **Playback**: AVFoundation for real-time audio playback with phrase boundary detection
- **UI**: SwiftUI for the performance interface with Combine for reactive updates
- **Waveforms**: RGB waveform extraction (bass/mid/high frequency bands) for DJ-style visualization

## Analysis Output

The analysis pipeline generates:
- **Per-track analysis**: Tempo, key, energy contour, beat grid, phrase boundaries
- **Phrase graph**: Weighted graph with compatibility links between phrases
- **Waveform data**: RGB waveforms for visual display (150 points per phrase)
- **Metadata**: Track names, segment types, time ranges

## Future Enhancements

### HyperMusic Improvements
- **Beat-aligned Immediate Cuts**: Quick switch mode with beat synchronization
- **DJ-style Transitions**: Crossfade, EQ swap, filter sweep, echo out
- **Transition Controls**: Duration selector, transition type, manual crossfader
- **Loop Current Phrase**: Repeat current phrase for extended mixing
- **Relationship Tracking**: Learn from your transitions to improve compatibility scoring

### Experimental / Research
- **RAVE Training Pipeline**: Train custom models on your DJ collection (research)
- **ML Classification**: Improve style/genre classification for filtering
- **Recording and Export**: Save HyperMusic navigation sessions as mixes
- **MIDI Integration**: Map external controllers to graph navigation
