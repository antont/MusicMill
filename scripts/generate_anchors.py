#!/usr/bin/env python3
"""
Generate style anchors from a trained RAVE model.

Encodes representative audio from each style folder and saves
the average latent vectors as "anchors" that can be used for
controllable generation.

Usage:
    python generate_anchors.py --model path/to/model.ts
    python generate_anchors.py --model percussion  # Uses pretrained model
"""

import argparse
import json
import os
import sys
from pathlib import Path
from collections import defaultdict
import numpy as np

try:
    import torch
    import torchaudio
except ImportError:
    print("Error: PyTorch and torchaudio required.")
    print("Install with: pip install torch torchaudio")
    sys.exit(1)

# Default paths
ANALYSIS_DIR = os.path.expanduser("~/Documents/MusicMill/Analysis")
MODELS_DIR = os.path.expanduser("~/Documents/MusicMill/RAVE")
PRETRAINED_DIR = os.path.expanduser("~/Documents/MusicMill/RAVE/pretrained")
ANCHORS_FILE = os.path.expanduser("~/Documents/MusicMill/RAVE/anchors.json")


def load_model(model_path: str):
    """Load RAVE model for encoding."""
    # Check if it's a name or path
    if not model_path.endswith('.ts'):
        # Try pretrained directory
        pretrained_path = Path(PRETRAINED_DIR) / f"{model_path}.ts"
        if pretrained_path.exists():
            model_path = str(pretrained_path)
        else:
            # Try models directory
            models_path = Path(MODELS_DIR) / "models" / model_path
            if models_path.exists():
                # Find the latest .ts file
                ts_files = list(models_path.glob("*.ts"))
                if ts_files:
                    model_path = str(ts_files[0])
    
    if not os.path.exists(model_path):
        print(f"Error: Model not found: {model_path}")
        sys.exit(1)
    
    print(f"Loading model: {model_path}")
    model = torch.jit.load(model_path, map_location="cpu")
    
    # Move to MPS if available
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = model.to(device)
    model.eval()
    
    print(f"  Using device: {device}")
    return model, device


def load_audio(audio_path: Path, target_sr: int = 48000) -> torch.Tensor:
    """Load audio file and resample to target sample rate."""
    waveform, sr = torchaudio.load(str(audio_path))
    
    # Convert to mono if stereo
    if waveform.shape[0] > 1:
        waveform = waveform.mean(dim=0, keepdim=True)
    
    # Resample if needed
    if sr != target_sr:
        resampler = torchaudio.transforms.Resample(sr, target_sr)
        waveform = resampler(waveform)
    
    return waveform


def encode_audio(model, audio: torch.Tensor, device: str) -> np.ndarray:
    """Encode audio to RAVE latent space."""
    # Add batch dimension: [channels, samples] -> [batch, channels, samples]
    audio = audio.unsqueeze(0).to(device)
    
    with torch.no_grad():
        # RAVE encode returns [batch, latent_dim, time]
        latent = model.encode(audio)
    
    # Convert to numpy and average over time
    latent_np = latent.cpu().numpy()
    
    # Average over time dimension to get single vector per track
    latent_mean = np.mean(latent_np, axis=-1)  # [batch, latent_dim]
    
    return latent_mean.squeeze(0)  # [latent_dim]


def find_style_audio():
    """Find audio files organized by style from analysis results."""
    analysis_path = Path(ANALYSIS_DIR)
    if not analysis_path.exists():
        print(f"Analysis directory not found: {ANALYSIS_DIR}")
        return {}
    
    style_audio = defaultdict(list)
    
    for analysis_dir in analysis_path.iterdir():
        if not analysis_dir.is_dir() or analysis_dir.name.startswith('.'):
            continue
        
        analysis_json = analysis_dir / "analysis.json"
        if not analysis_json.exists():
            continue
        
        with open(analysis_json) as f:
            analysis = json.load(f)
        
        # Get organized styles mapping
        organized = analysis.get('organizedStyles', {})
        for style, file_paths in organized.items():
            for file_path in file_paths:
                path = Path(file_path)
                if path.exists():
                    style_audio[style].append(path)
    
    return dict(style_audio)


def main():
    parser = argparse.ArgumentParser(description="Generate RAVE style anchors")
    parser.add_argument('--model', '-m', required=True,
                        help='Model path or name (e.g., percussion, musicmill_v2)')
    parser.add_argument('--output', '-o', default=ANCHORS_FILE,
                        help=f'Output JSON file (default: {ANCHORS_FILE})')
    parser.add_argument('--max-per-style', type=int, default=10,
                        help='Maximum tracks to encode per style (default: 10)')
    parser.add_argument('--chunk-seconds', type=float, default=30,
                        help='Seconds of audio to encode per track (default: 30)')
    
    args = parser.parse_args()
    
    print("=" * 60)
    print("MusicMill RAVE Style Anchor Generation")
    print("=" * 60)
    
    # Load model
    model, device = load_model(args.model)
    
    # Find style audio
    print("\nFinding style audio from analysis...")
    style_audio = find_style_audio()
    
    if not style_audio:
        print("No style-organized audio found.")
        print("Make sure MusicMill analysis has been run.")
        sys.exit(1)
    
    print(f"Found {len(style_audio)} styles:")
    for style, files in style_audio.items():
        print(f"  {style}: {len(files)} tracks")
    
    # Encode each style
    print("\nEncoding styles to latent space...")
    anchors = {}
    
    sample_rate = 48000
    chunk_samples = int(args.chunk_seconds * sample_rate)
    
    for style, audio_files in style_audio.items():
        print(f"\n  Encoding '{style}'...")
        
        # Limit number of files
        files_to_encode = audio_files[:args.max_per_style]
        
        latents = []
        for audio_path in files_to_encode:
            try:
                # Load audio
                audio = load_audio(audio_path, sample_rate)
                
                # Take chunk from middle of track
                total_samples = audio.shape[-1]
                start = max(0, (total_samples - chunk_samples) // 2)
                end = min(total_samples, start + chunk_samples)
                audio_chunk = audio[:, start:end]
                
                # Encode
                latent = encode_audio(model, audio_chunk, device)
                latents.append(latent)
                
                print(f"    ✓ {audio_path.name[:40]}...")
                
            except Exception as e:
                print(f"    ✗ {audio_path.name}: {e}")
        
        if latents:
            # Average latents for this style
            anchor = np.mean(latents, axis=0)
            
            # Also compute std for variation control
            anchor_std = np.std(latents, axis=0) if len(latents) > 1 else np.zeros_like(anchor)
            
            anchors[style] = {
                'mean': anchor.tolist(),
                'std': anchor_std.tolist(),
                'num_tracks': len(latents)
            }
            
            print(f"    Anchor created from {len(latents)} tracks")
    
    # Save anchors
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    result = {
        'model': args.model,
        'latent_dim': len(next(iter(anchors.values()))['mean']) if anchors else 0,
        'styles': anchors
    }
    
    with open(output_path, 'w') as f:
        json.dump(result, f, indent=2)
    
    print("\n" + "=" * 60)
    print(f"Anchors saved to: {output_path}")
    print(f"Styles: {len(anchors)}")
    print(f"Latent dimension: {result['latent_dim']}")
    print("\nUsage in rave_server.py:")
    print("  python rave_server.py --model MODEL --anchors " + str(output_path))


if __name__ == "__main__":
    main()


