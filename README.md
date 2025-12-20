# MusicMill

DJ-oriented Music Machine Learning (ML) system for macOS.

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

### Current (Skeleton)
- **Music Collection Analysis**: Scans and analyzes your DJ collection, supporting MP3, AAC, WAV, AIFF formats
- **Style Classification**: Trains MLSoundClassifier models to identify musical styles/genres from your collection
- **Track Classification**: Automatically classifies tracks when loading your collection (helper/debug feature)
- **Performance Interface**: UI scaffolding for style/tempo/energy controls

### Planned (Primary Goals)
- **Real-time Generative Synthesis**: Generate new audio segments based on learned styles
- **Style-guided Generation**: Control output style using trained classification models
- **Tempo/Energy Control**: Direct the generative model's tempo and energy characteristics
- **Live Performance Controls**: Real-time mixing, crossfading, and effects

### Helper/Debug Features
- **Track Recommendations**: Show example tracks/segments matching current desired output (for debugging/verification)
- **Collection Analysis**: Understand what styles exist in your collection

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
│   ├── ML/               # Model training (classification + generation)
│   ├── Performance/      # Live performance interface & generative engine
│   └── Training/         # Training UI
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

## Technical Details

- Uses AVFoundation for audio I/O and real-time synthesis
- MLSoundClassifier for style/genre classification (stepping stone)
- Core ML for model inference
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

- **Generative Model Implementation**: Core audio synthesis engine (primary goal)
- **Improved Generation Quality**: Better models and techniques for higher quality output
- **MIDI Integration**: External controllers for live performance
- **Advanced Effects**: Real-time audio effects and processing
- **Multi-layer Synthesis**: Simultaneous generation of multiple audio layers
- **Recording and Export**: Save generated performances
