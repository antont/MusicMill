# RAVE Input/Output Waveform Analysis

Generated: 2024-12-22

## Test Methodology

Processed 8 different input signals through both RAVE models (percussion & vintage):
- Sine wave (200 Hz, pure tone)
- LFO sine (200 Hz with 5 Hz amplitude modulation)
- Rhythm clicks (120 BPM, sharp transients)
- Noise bursts (beatbox-like, 120 BPM)
- Square wave (100 Hz, rich harmonics)
- White noise (continuous broadband)
- Chirp (frequency sweep 100→600 Hz)
- Kick pattern (synthetic kick drum, 120 BPM)

All signals: 1 second duration, 48 kHz, ~0.3 peak amplitude

## Key Findings

### 1. RAVE Processing Latency

| Signal Type | Latency (approx) |
|-------------|-----------------|
| Noise bursts | 40-50 ms |
| Transients | 20-40 ms |
| Continuous tones | 50-90 ms |

The output is always **time-shifted** relative to input due to encoder/decoder processing.

### 2. Amplitude Response Summary

| Signal | Percussion | Vintage |
|--------|-----------|---------|
| Sine wave | **0.75x** (attenuated) | **0.43x** (nearly silent!) |
| LFO sine | 1.31x | 1.13x |
| Rhythm clicks | 1.39x | **2.21x** |
| Noise bursts | **2.02x** | 1.52x |
| Square wave | **0.39x** | **0.33x** |
| White noise | 0.68x | 0.76x |
| Chirp | 0.67x | 0.73x |
| Kick pattern | 0.83x | **2.50x** |

**Critical insight**: 
- Pure tones are **severely attenuated** (down to 0.33x)
- Transients/impulses are **amplified** (up to 2.50x)

### 3. Visual Pattern: "Blob" Structure

All outputs show a characteristic pattern:

```
Input:  ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿  (continuous)
Output: ░░███░░░░░░███░░░░░░███░  (discrete "blobs")
```

This is due to RAVE's frame-based processing:
- Frame size: ~2048 samples = **42.7ms at 48kHz**
- Each frame produces a "blob" of output
- Gaps between frames create a granular feel

### 4. Spectral Transformation

**Input spectra** vary widely:
- Sine: single narrow peak at 200 Hz
- Square: harmonics at 100, 300, 500, 700... Hz  
- Noise: flat broadband

**Output spectra** are remarkably similar:
- Always broadband noise-like (10⁰ to 10² magnitude)
- Peaks around 1-2 kHz typical for both models
- RAVE essentially "texturizes" any input

### 5. Model-Specific Behaviors

**Percussion model:**
- Best response to noise bursts (2.02x)
- Responds to amplitude dynamics (LFO preserved)
- Adds percussive texture to any input

**Vintage model:**
- Loves transients! Kick pattern gets 2.50x boost
- Pure tones almost completely silenced (0.43x for sine)
- More "vintage synth" texture added

## Implications for Voice Input

### What Works
✅ **Beatboxing** - percussive sounds like "ts ts", "pf pf"
✅ **Clicks and pops** - tongue clicks, lip pops
✅ **Breathy sounds** - contain noise energy
✅ **Sharp consonants** - contain transients

### What Doesn't Work
❌ **Humming/singing** - pure tones get attenuated
❌ **Sustained vowels** - too clean, no noise
❌ **Whistling** - pure tone, gets silenced

### Why Noise Excitation Helps
Adding noise to input:
1. Provides broadband energy RAVE can work with
2. Fills spectral gaps in voice
3. Creates pseudo-transients for RAVE to respond to

## Recommended Settings for Voice Input

```
Input Gain: 3-5x (voices are quieter than test signals)
Noise Excitation: 40-60% (critical for non-percussive sounds)
Output Gain: 2-3x (compensate for processing loss)
```

## Technical Implications

### Frame Boundary Artifacts
The visible gaps between output "blobs" explain:
- Why output sounds "granular" not smooth
- Why there's a ~40-90ms latency
- Why continuous input doesn't create continuous output

### Why RAVE Isn't a Simple "Effect"
RAVE doesn't just filter or process - it:
1. **Encodes** input to latent space (lossy compression)
2. **Decodes** back to audio (reconstruction)

The latent space was trained on specific audio types (percussion, vintage synths).
Input signals that don't match this training data reconstruct poorly.

## Visualizations Location

All analysis images saved to:
`/tmp/rave_waveform_analysis/{model_name}/{signal_name}.png`

Each image shows:
- Top left: Input waveform (first 200ms, blue)
- Top right: Output waveform (first 200ms, green)
- Bottom left: Input spectrum (0-6kHz)
- Bottom right: Output spectrum (0-6kHz)
- Footer: RMS values and gain ratio


