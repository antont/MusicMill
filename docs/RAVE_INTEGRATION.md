# RAVE Integration for MusicMill

RAVE (Realtime Audio Variational autoEncoder) provides neural audio synthesis for MusicMill, enabling high-quality generative music output.

## Overview

RAVE is a deep learning model that:
1. **Encodes** audio into a compact latent representation
2. **Decodes** latent vectors back into audio
3. Runs fast enough for **real-time synthesis** (291x realtime on M3 Max)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     RAVE Pipeline                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Audio Input    Encoder      Latent Space      Decoder      │
│  ┌─────────┐   ┌───────┐    ┌───────────┐    ┌───────┐     │
│  │ 44.1kHz │ → │ Conv  │ →  │ 4 dims ×  │ →  │ Conv  │ →   │
│  │ Waveform│   │ Stack │    │ N frames  │    │ Stack │     │
│  └─────────┘   └───────┘    └───────────┘    └───────┘     │
│                                   ↑                         │
│                          CONTROL POINT                      │
│                     (manipulate for effects)                │
└─────────────────────────────────────────────────────────────┘
```

## Latent Space Controls

The percussion model uses **4 latent dimensions** with ~2048x compression:
- 1 latent frame = 2048 audio samples (~46ms at 44.1kHz)

### Control Mapping to MusicMill Goals

| Control | Implementation | Effect |
|---------|---------------|--------|
| **Style** | Blend latents from different encoded sources | Morphs between musical styles |
| **Energy** | Scale latent magnitude (×0.3 to ×2.0) | Changes dynamics/intensity |
| **Tempo** | Interpolate latent time axis | Speeds up or slows down patterns |
| **Timbre** | Weight individual dimensions | Adjusts tonal character |
| **Evolution** | Structured latent patterns (LFOs) | Creates movement over time |

### Example: Style Interpolation

```python
# Encode reference tracks from different styles
z_darkwave = model.encode(darkwave_audio)
z_synthpop = model.encode(synthpop_audio)

# Blend based on style slider (0.0 to 1.0)
style_blend = 0.7  # 70% darkwave, 30% synthpop
z_mixed = style_blend * z_darkwave + (1 - style_blend) * z_synthpop

# Decode to audio
output = model.decode(z_mixed)
```

### Example: Energy Control

```python
# Energy via latent scaling
energy_level = 0.5  # 0.0 = quiet, 1.0 = loud
scale = 0.3 + energy_level * 1.7  # Maps to 0.3x - 2.0x

z_scaled = z_base * scale
output = model.decode(z_scaled)
```

### Example: Tempo Control

```python
import torch.nn.functional as F

# Tempo via time interpolation
tempo_factor = 1.5  # 1.5x faster

z_stretched = F.interpolate(
    z_base, 
    scale_factor=1.0/tempo_factor,  # Compress = faster
    mode='linear'
)
output = model.decode(z_stretched)
```

## Setup

### Prerequisites

```bash
# Create Python environment
cd ~/Documents/MusicMill/RAVE
python3 -m venv venv
source venv/bin/activate
pip install torch torchaudio scipy
```

### Download Pretrained Model

```bash
# Percussion model (67MB, good for testing)
curl -L "https://play.forum.ircam.fr/rave-vst-api/get_model/percussion" \
     -o pretrained/percussion.ts
```

### Train on Your Collection

```bash
# 1. Preprocess audio
rave preprocess --input_path /path/to/your/music \
                --output_path preprocessed/ \
                --lazy

# 2. Train model (takes 1-2 hours on M3 Max)
rave train --config v2 \
           --db_path preprocessed/ \
           --name my_collection \
           --val_every 100
```

## Performance

Tested on M3 Max (36GB):

| Batch Size | Audio Duration | Speed |
|------------|---------------|-------|
| 10 frames | 0.4s | 14.5x realtime |
| 50 frames | 2.1s | 99.8x realtime |
| 100 frames | 4.3s | 192.9x realtime |
| 200 frames | 8.5s | **291.2x realtime** |

## Swift Integration

RAVE runs via PyTorch MPS (Python). Integration options:

### Option 1: Subprocess (Simple)
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/path/to/venv/bin/python")
process.arguments = ["rave_server.py", "--generate", "output.wav"]
try process.run()
```

### Option 2: Unix Socket (Real-time)
```swift
// Swift sends latent vectors via socket
// Python decodes and streams audio back
```

### Option 3: Pre-generation (Batch)
```swift
// Generate audio chunks ahead of time
// Swift plays from buffer while Python generates more
```

## Limitations

### Why Not Core ML?

RAVE uses "cached convolutions" for streaming - internal state that persists between calls. This is incompatible with Core ML's static computation graph.

| Approach | Result |
|----------|--------|
| Direct tracing | ❌ In-place ops fail |
| ONNX export | ❌ Dynamic shapes fail |
| TorchScript | ❌ Scripted model too complex |

**PyTorch MPS is fast enough** (291x realtime) that Core ML isn't needed.

### Model Requirements

- Training requires ~1-2 hours of audio minimum
- More data = better generalization
- Style transfer works best with similar genres

## Files

```
~/Documents/MusicMill/RAVE/
├── venv/                    # Python environment
├── pretrained/
│   └── percussion.ts        # Pretrained model (67MB)
├── preprocessed/            # Processed training data
├── models/                  # Trained models
└── control_demo_*.wav       # Example control outputs
```

## Demo Files

Listen to these to understand control effects:

| File | Demonstrates |
|------|--------------|
| `control_demo_1_base.wav` | Base random generation |
| `control_demo_2_low_energy.wav` | Low energy (0.3x scaling) |
| `control_demo_2_high_energy.wav` | High energy (2.0x scaling) |
| `control_demo_3_dim0_only.wav` | Dimension 0 isolated |
| `control_demo_3_dim1_only.wav` | Dimension 1 isolated |
| `control_demo_3_dim2_only.wav` | Dimension 2 isolated |
| `control_demo_3_dim3_only.wav` | Dimension 3 isolated |
| `control_demo_4_slow_tempo.wav` | Slow tempo (0.5x) |
| `control_demo_4_fast_tempo.wav` | Fast tempo (2.0x) |
| `control_demo_5_smooth_evolution.wav` | Structured LFO patterns |

## UI Controls

The RAVE tab in MusicMill provides comprehensive control over neural synthesis:

### Macro Controls

| Control | Description | Implementation |
|---------|-------------|----------------|
| **Energy** | Overall intensity/dynamics | Scales latent magnitude |
| **Texture** | Tonal character variation | Maps to variation amount |
| **Chaos** | Randomness/unpredictability | Adds random noise to latent |

### Tempo

BPM slider (40-200) controls playback speed via latent time-axis interpolation.

### Latent Dimensions

Direct control over individual latent dimensions (4 for percussion, 16 for vintage):
- Each dimension affects different timbral qualities
- Experiment to discover interesting combinations
- Reset/Randomize buttons for exploration

### Modulation (LFO)

Built-in LFO for automated parameter sweeps:
- Waveforms: Sine, Triangle, Square, Random
- Rate: 0.1 - 10 Hz
- Target: Energy, Texture, Chaos, or specific dimension
- Depth: 0 - 100%

### Presets

Quick presets for common settings:
- **Calm**: Low energy, minimal chaos
- **Balanced**: Neutral settings
- **Intense**: High energy, moderate chaos
- **Chaotic**: Maximum randomness

## Future Work

### Style-to-Parameter Mapping

After analyzing DJ sets, we can correlate audio features with RAVE latent dimensions:

1. **Extract features** from source tracks (spectral centroid, energy envelope, rhythm patterns)
2. **Train mapping** from features to latent dimensions that produce similar output
3. **Create style presets** that automatically configure RAVE for a genre
4. **"Match this track"** feature: encode reference, use as style anchor

This would enable:
- Selecting a style from your collection
- RAVE automatically producing similar-sounding output
- Smooth interpolation between styles during performance

### Voice Input Control

Use microphone input (humming, beatboxing) to drive RAVE in real-time:

- **Humming → Percussion**: Hum "bm bm ts ts" → RAVE outputs actual drums
- **Voice → Synth**: Sing melodies → RAVE transforms to synth textures  
- **Beatboxing → Full Drums**: Real-time voice-to-drums conversion

This leverages RAVE's encode-decode architecture:
```
Microphone → Encode → Latent Space → Decode → Percussion/Synth Output
```

The timing and dynamics of your voice control the output rhythm and intensity.

### Additional Enhancements

- **MIDI control**: Map MIDI CC to latent dimensions for hardware control
- **Audio reactive**: Use input audio features to modulate parameters
- **Pattern memory**: Save and recall interesting latent configurations
- **Multi-model blending**: Mix output from multiple RAVE models

### Alternative Models to Explore

**MusicGen** (Meta) - True generative music model:
- Generates coherent music from text prompts or melody conditioning
- Runs locally on M3 Max (1.5B parameter model fits in 36GB)
- Speed: ~10-20 seconds to generate 10 seconds of audio (not realtime)
- Use case: Batch pre-generate variations, use as source material
- Could complement RAVE for offline content creation

## References

- [RAVE Paper](https://arxiv.org/abs/2111.05011) - Original research
- [acids-rave](https://github.com/acids-ircam/RAVE) - Official implementation
- [RAVE VST](https://forum.ircam.fr/projects/detail/rave-vst/) - Pretrained models

