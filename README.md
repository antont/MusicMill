# MusicMill

DJ-oriented Music Machine Learning (ML) system for macOS.

## Overview

MusicMill analyzes your DJ music collection locally on an M3 Mac using Apple's MLSoundClassifier, trains models to understand musical styles, and provides a live performance interface with generative-style controls. The system allows you to direct the style in real-time, similar to switching folders and songs, and mixing tracks.

## Features

- **Music Collection Analysis**: Scans and analyzes your DJ collection, supporting MP3, AAC, WAV, AIFF formats
- **Style Classification**: Trains MLSoundClassifier models to identify musical styles/genres from your collection
- **Live Performance Interface**: Real-time controls for style selection, tempo/energy adjustment, and intelligent track selection
- **Real-time Mixing**: Crossfade, volume, and EQ controls for live performances
- **Intelligent Recommendations**: Model-based track recommendations matching your selected style and preferences

## Architecture

The system consists of three main components:

1. **Analysis Pipeline**: Scans music collection and extracts audio features
2. **Model Training**: Trains MLSoundClassifier on style/genre classification
3. **Live Performance Interface**: Real-time control interface for performances

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
│   ├── ML/               # Model training and inference
│   ├── Performance/      # Live performance interface
│   ├── Audio/            # Real-time audio processing
│   └── Training/         # Training UI
└── README.md
```

## Getting Started

1. Open the project in Xcode
2. Select your music collection directory in the Training tab
3. Analyze your collection to extract training samples
4. Train a model on your collection
5. Switch to the Performance tab to use the live interface

## Usage

### Training a Model

1. Open the app and navigate to the "Training" tab
2. Click "Select Directory" and choose your music collection folder
3. Click "Analyze Collection" to scan and prepare training data
4. Enter a model name and click "Train Model"
5. The trained model will be saved and available for use

### Live Performance

1. Navigate to the "Performance" tab
2. Select a style/genre from the dropdown
3. Adjust tempo (BPM) and energy sliders to your preference
4. Browse recommended tracks based on your selections
5. Click a track to load it for playback
6. Use playback controls to play, pause, and adjust volume

## Technical Details

- Uses AVFoundation for audio I/O and playback
- MLSoundClassifier for style/genre classification
- Core ML for model inference
- SwiftUI for the user interface
- Combine framework for reactive programming

## Notes

- The system organizes training data by directory structure (folders = style labels)
- Audio segments are extracted for training (30-second clips by default)
- Real-time inference enables dynamic style matching during playback
- Models are saved locally in Application Support directory

## Future Enhancements

- Generative capabilities for creating new music segments
- MIDI integration for external controllers
- Advanced effects and filters
- Multi-track simultaneous playback
- Recording and export functionality
