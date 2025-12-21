# MusicMill Analysis Overview

## What the Analysis Does

The analysis pipeline extracts multiple types of information from your music collection to support generative synthesis. Here's what gets analyzed:

## 1. File Discovery (`AudioAnalyzer.scanDirectory`)

**What it does:**
- Scans the directory recursively for audio files
- Supports formats: MP3, AAC, M4A, WAV, AIFF
- Extracts basic file metadata (duration, format)

**Output:**
- List of all audio files found
- File format and duration for each file
- Note: DRM-protected files (like Apple Music M4A) are skipped with a warning

## 2. Audio Feature Extraction (`FeatureExtractor.extractFeatures`)

**What it extracts from each audio file:**

### Tempo (BPM)
- Estimated beats per minute
- Used for tempo matching and synchronization

### Musical Key
- Detected key (e.g., "C", "Am", "D#m")
- Used for harmonic matching and key-based generation

### Energy (0.0 - 1.0)
- Overall energy/intensity of the track
- Higher values = more intense/loud sections
- Used to match energy levels in generation

### Spectral Centroid
- "Brightness" of the sound
- Higher values = brighter/more treble
- Lower values = darker/more bass
- Used for timbral matching

### Zero Crossing Rate
- Measure of "roughness" or "noisiness"
- Higher values = more noise/roughness
- Used for texture matching

### RMS Energy
- Root Mean Square energy (overall loudness)
- Different from "Energy" - this is the actual signal level
- Used for volume normalization and matching

### Duration
- Track length in seconds
- Used for segment extraction and timing

## 3. Style Organization (`TrainingDataManager.organizeByDirectoryStructure`)

**What it does:**
- Groups files by their folder structure
- Uses folder names as style/genre labels
- Example: Files in `BLVCKCEILING/BALANCE/` get label "BALANCE"

**Output:**
- Dictionary mapping style labels to audio files
- Used for training classification models
- Used for style-based generation control

## 4. Training Segment Extraction (`AudioAnalyzer.extractTrainingSegments`)

**What it does:**
- Extracts ~30-second segments from each track
- Segments are used for training ML models
- Multiple segments per track (if track is long enough)

**Output:**
- List of audio segments with metadata
- Each segment is labeled with its style (from folder structure)

## 5. Advanced Analysis (Future/Planned)

### Spectral Analysis (`SpectralAnalyzer`)
- **Mel-spectrograms**: Frequency representation for neural models
- **Chromagrams**: Pitch class representation (12 semitones)
- **STFT**: Short-Time Fourier Transform for frequency analysis
- **Harmonic/Percussive Separation**: Separates melodic from rhythmic content

### Segment-Level Analysis (`SegmentExtractor`)
- **Onset Detection**: Finds beat/note start times
- **Beat Tracking**: Identifies beat positions
- **Phrase Boundaries**: Detects musical phrases
- **Style Classification per Segment**: Different parts of a track may have different styles

### Structure Analysis (`StructureAnalyzer`)
- **Chord Progressions**: Detects chord sequences
- **Section Detection**: Identifies intro, verse, chorus, bridge, outro
- **Repetition Detection**: Finds repeating patterns
- **Phrase Boundaries**: Musical phrase structure

### Rekordbox Metadata (`RekordboxParser`)
- **Cue Points**: DJ cue points from Rekordbox
- **Play History**: When tracks were played
- **Play Counts**: How often tracks were played
- **BPM/Key from Rekordbox**: Pre-analyzed metadata

## How This Supports Generation

1. **Style Matching**: Folder structure provides style labels for training
2. **Feature Matching**: Tempo, key, energy used to find similar segments
3. **Granular Synthesis**: Segments become "grains" for sample-based generation
4. **Neural Training**: Spectral features train generative models
5. **Structure Understanding**: Chord progressions and sections guide generation
6. **DJ Metadata**: Cue points and play history indicate important sections

## Example Analysis Output

When analyzing the BLVCKCEILING collection:

```
[1] Scanning directory for audio files...
✓ Found 4 audio files
  1. BLVCKCEILING - BALANCE.mp3
     Format: MP3
     Duration: 180s (3.0 min)

[2] Extracting audio features from first file...
✓ Features extracted for: BLVCKCEILING - BALANCE.mp3
  • Tempo: 128.0 BPM
  • Key: Am
  • Energy: 0.756 (0.0 = quiet, 1.0 = loud)
  • Spectral Centroid: 2345.2 (brightness)
  • Zero Crossing Rate: 0.0234 (roughness)
  • RMS Energy: 0.1234 (loudness)
  • Duration: 180s

[3] Organizing files by directory structure (styles)...
✓ Organized into 3 style categories:
  • BALANCE: 1 file
  • silver paint: 1 file
  • UnknownAlbum: 2 files

[4] Extracting training segments...
✓ Extracted 6 training segments from BLVCKCEILING - BALANCE.mp3
  (Each segment is ~30 seconds for training)
```

## Current Status

✅ **Implemented:**
- File discovery
- Basic feature extraction (tempo, key, energy, spectral features)
- Style organization by folder structure
- Training segment extraction

🚧 **Skeleton/Placeholder:**
- Spectral analysis (STFT, mel-spectrograms, chromagrams)
- Segment-level analysis (onset detection, beat tracking)
- Structure analysis (chord progressions, sections)
- Rekordbox metadata parsing

These advanced features are implemented as skeletons and will be expanded as needed for different generation approaches.


