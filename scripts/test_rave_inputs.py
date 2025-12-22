#!/usr/bin/env python3
"""
Test RAVE style transfer with various input signals.
Explores how different inputs produce different outputs.
"""

import torch
import numpy as np
import scipy.io.wavfile as wav
import os
from pathlib import Path

# Find RAVE model
DOCS = Path.home() / "Documents"
RAVE_DIR = DOCS / "MusicMill" / "RAVE"
PRETRAINED = RAVE_DIR / "pretrained"

def load_model(model_name="percussion"):
    """Load a RAVE model."""
    model_path = PRETRAINED / f"{model_name}.ts"
    if not model_path.exists():
        print(f"Model not found: {model_path}")
        return None
    
    print(f"Loading model: {model_path}")
    model = torch.jit.load(str(model_path))
    model.eval()
    
    # Use MPS if available
    if torch.backends.mps.is_available():
        model = model.to("mps")
        print("Using MPS (Apple Silicon GPU)")
    
    return model

def generate_test_signals(duration=1.0, sample_rate=48000):
    """Generate various test input signals."""
    n_samples = int(duration * sample_rate)
    t = np.linspace(0, duration, n_samples, dtype=np.float32)
    
    signals = {}
    
    # 1. Silence
    signals["silence"] = np.zeros(n_samples, dtype=np.float32)
    
    # 2. Sine waves at different frequencies
    for freq in [100, 440, 1000, 4000]:
        signals[f"sine_{freq}hz"] = (0.5 * np.sin(2 * np.pi * freq * t)).astype(np.float32)
    
    # 3. White noise
    signals["white_noise"] = (0.3 * np.random.randn(n_samples)).astype(np.float32)
    
    # 4. Pink noise (1/f)
    white = np.random.randn(n_samples)
    # Simple approximation of pink noise via filtering
    pink = np.zeros(n_samples)
    b = [0.02109238, 0.07113478, 0.68873558]
    for i in range(3, n_samples):
        pink[i] = b[0] * white[i] + b[1] * white[i-1] + b[2] * pink[i-1]
    signals["pink_noise"] = (0.3 * pink / (np.abs(pink).max() + 1e-6)).astype(np.float32)
    
    # 5. Impulse/click
    impulse = np.zeros(n_samples, dtype=np.float32)
    impulse[0] = 1.0
    signals["impulse"] = impulse
    
    # 6. Click train (like a basic beat)
    click_train = np.zeros(n_samples, dtype=np.float32)
    click_interval = int(sample_rate / 4)  # 4 clicks per second
    for i in range(0, n_samples, click_interval):
        click_train[i:i+100] = 0.8 * np.exp(-np.arange(min(100, n_samples-i)) / 10)
    signals["click_train"] = click_train
    
    # 7. Drum-like transient (exponential decay with noise)
    drum = np.exp(-t * 20) * np.random.randn(n_samples) * 0.5
    signals["drum_transient"] = drum.astype(np.float32)
    
    # 8. Swept sine (chirp)
    chirp = 0.5 * np.sin(2 * np.pi * (100 + 2000 * t) * t)
    signals["chirp"] = chirp.astype(np.float32)
    
    # 9. Square wave
    square = 0.5 * np.sign(np.sin(2 * np.pi * 200 * t))
    signals["square_200hz"] = square.astype(np.float32)
    
    # 10. AM modulated signal (like humming with vibrato)
    carrier = np.sin(2 * np.pi * 200 * t)
    modulator = 0.5 + 0.5 * np.sin(2 * np.pi * 5 * t)  # 5 Hz tremolo
    signals["am_modulated"] = (0.5 * carrier * modulator).astype(np.float32)
    
    # 11. Rhythmic pattern (kick-like)
    pattern = np.zeros(n_samples, dtype=np.float32)
    beat_samples = int(sample_rate * 0.25)  # 4 beats per second
    for beat in range(4):
        start = beat * beat_samples
        if start < n_samples:
            decay_len = min(int(sample_rate * 0.1), n_samples - start)
            decay = np.exp(-np.arange(decay_len) / (sample_rate * 0.02))
            freq_sweep = 150 * np.exp(-np.arange(decay_len) / (sample_rate * 0.01)) + 50
            kick = decay * np.sin(2 * np.pi * np.cumsum(freq_sweep) / sample_rate)
            pattern[start:start+decay_len] += 0.8 * kick.astype(np.float32)
    signals["kick_pattern"] = pattern
    
    # 12. Voice-like formants
    f0 = 150  # fundamental
    formants = [500, 1500, 2500]  # vowel "ah" like
    voice = np.zeros(n_samples, dtype=np.float32)
    for i, f in enumerate([f0] + formants):
        amp = 1.0 / (i + 1)
        voice += amp * np.sin(2 * np.pi * f * t)
    voice = (0.3 * voice / np.abs(voice).max()).astype(np.float32)
    signals["voice_formants"] = voice
    
    return signals

def style_transfer(model, audio, device="mps"):
    """Run audio through RAVE encode->decode."""
    # Convert to tensor
    audio_tensor = torch.tensor(audio, dtype=torch.float32, device=device)
    audio_tensor = audio_tensor.unsqueeze(0).unsqueeze(0)  # [1, 1, samples]
    
    with torch.no_grad():
        output = model.forward(audio_tensor)
    
    output_np = output.cpu().numpy().squeeze()
    
    # Handle stereo
    if len(output_np.shape) == 2:
        output_np = output_np.mean(axis=0)
    
    return output_np.astype(np.float32)

def analyze_audio(audio, name, sample_rate=48000):
    """Analyze audio characteristics."""
    # RMS energy
    rms = np.sqrt(np.mean(audio**2))
    
    # Peak
    peak = np.abs(audio).max()
    
    # Zero crossings (proxy for frequency content)
    zero_crossings = np.sum(np.abs(np.diff(np.sign(audio))) > 0)
    zcr = zero_crossings / len(audio)
    
    # Spectral centroid
    fft = np.abs(np.fft.rfft(audio))
    freqs = np.fft.rfftfreq(len(audio), 1/sample_rate)
    if fft.sum() > 0:
        centroid = np.sum(freqs * fft) / np.sum(fft)
    else:
        centroid = 0
    
    return {
        "name": name,
        "rms": rms,
        "peak": peak,
        "zcr": zcr,
        "centroid": centroid
    }

def main():
    # Output directory
    output_dir = Path("/tmp/rave_input_tests")
    output_dir.mkdir(exist_ok=True)
    
    # Load models
    models = {}
    for model_name in ["percussion", "vintage"]:
        model = load_model(model_name)
        if model:
            models[model_name] = model
    
    if not models:
        print("No models found!")
        return
    
    # Generate test signals
    print("\nGenerating test signals...")
    signals = generate_test_signals(duration=2.0)
    
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    
    # Process each signal through each model
    results = []
    
    for model_name, model in models.items():
        print(f"\n{'='*60}")
        print(f"Testing model: {model_name}")
        print('='*60)
        
        model_dir = output_dir / model_name
        model_dir.mkdir(exist_ok=True)
        
        for signal_name, signal in signals.items():
            print(f"\n  Processing: {signal_name}")
            
            # Analyze input
            input_stats = analyze_audio(signal, f"input_{signal_name}")
            print(f"    Input  - RMS: {input_stats['rms']:.4f}, Peak: {input_stats['peak']:.4f}, "
                  f"ZCR: {input_stats['zcr']:.4f}, Centroid: {input_stats['centroid']:.0f}Hz")
            
            # Style transfer
            try:
                output = style_transfer(model, signal, device)
                
                # Analyze output
                output_stats = analyze_audio(output, f"output_{signal_name}")
                print(f"    Output - RMS: {output_stats['rms']:.4f}, Peak: {output_stats['peak']:.4f}, "
                      f"ZCR: {output_stats['zcr']:.4f}, Centroid: {output_stats['centroid']:.0f}Hz")
                
                # Compute transformation ratio
                if input_stats['rms'] > 0.001:
                    rms_ratio = output_stats['rms'] / input_stats['rms']
                    print(f"    RMS ratio (output/input): {rms_ratio:.2f}x")
                
                # Save WAVs
                wav.write(str(model_dir / f"input_{signal_name}.wav"), 48000, signal)
                wav.write(str(model_dir / f"output_{signal_name}.wav"), 48000, output)
                
                results.append({
                    "model": model_name,
                    "signal": signal_name,
                    "input": input_stats,
                    "output": output_stats
                })
                
            except Exception as e:
                print(f"    Error: {e}")
    
    # Summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print('='*60)
    
    print(f"\nOutputs saved to: {output_dir}")
    print("\nKey findings:")
    
    for model_name in models.keys():
        print(f"\n{model_name.upper()} model:")
        model_results = [r for r in results if r["model"] == model_name]
        
        # Sort by output RMS
        model_results.sort(key=lambda x: x["output"]["rms"], reverse=True)
        
        print("  Signals that produce most output (by RMS):")
        for r in model_results[:5]:
            print(f"    - {r['signal']}: RMS {r['output']['rms']:.4f}")
        
        print("  Signals that produce least output:")
        for r in model_results[-3:]:
            print(f"    - {r['signal']}: RMS {r['output']['rms']:.4f}")

if __name__ == "__main__":
    main()

