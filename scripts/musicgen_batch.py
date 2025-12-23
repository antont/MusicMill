#!/usr/bin/env python3
"""
MusicGen Batch Generator for MusicMill

Generates music in the background using your DJ collection as style references.
Can run during a live set - triggered tracks appear as they complete.

Usage:
    # Generate 5 tracks using random references from your collection
    python musicgen_batch.py --count 5 --duration 120
    
    # Generate with specific reference
    python musicgen_batch.py --reference /path/to/track.mp3 --duration 90
    
    # Run as background daemon during performance
    python musicgen_batch.py --daemon --interval 300  # New track every 5 minutes
"""

import argparse
import warnings
warnings.filterwarnings('ignore')

import os
import sys
import time
import random
import subprocess
from pathlib import Path
from datetime import datetime

# Suppress xformers warning
os.environ['XFORMERS_MORE_DETAILS'] = '0'

import torch
import soundfile as sf
import numpy as np

# Set torch backend before importing audiocraft
from audiocraft.modules.transformer import set_efficient_attention_backend
set_efficient_attention_backend('torch')

from audiocraft.models import MusicGen

# Configuration
DJ_COLLECTION = Path.home() / "Music/PioneerDJ"
OUTPUT_DIR = Path.home() / "Documents/MusicMill/Generated"
SAMPLE_RATE = 32000

# Style prompts that work well with darkwave/witch house
STYLE_PROMPTS = [
    "dark electronic, heavy bass, atmospheric",
    "witch house, lo-fi, chopped vocals, reverb",
    "darkwave synthwave, analog pads, 80s drums",
    "industrial electronic, distorted, mechanical rhythm",
    "dark ambient, ethereal, deep bass, minimal",
    "gothic electronic, haunting melodies, driving beat",
    "cold wave, synthesizers, dark atmosphere",
    "dark techno, pulsing bass, hypnotic",
]


def find_reference_tracks(collection_path: Path) -> list[Path]:
    """Find all audio files in the DJ collection"""
    extensions = {'.mp3', '.wav', '.flac', '.m4a', '.aiff'}
    tracks = []
    for ext in extensions:
        tracks.extend(collection_path.rglob(f'*{ext}'))
    return tracks


def convert_to_wav(input_path: Path, duration: float = 30) -> Path:
    """Convert audio file to WAV for MusicGen"""
    output_path = Path('/tmp') / f'musicgen_ref_{hash(str(input_path)) % 10000}.wav'
    
    subprocess.run([
        'ffmpeg', '-y', '-i', str(input_path),
        '-ar', str(SAMPLE_RATE),
        '-ac', '1',
        '-t', str(duration),  # Use first N seconds as reference
        str(output_path)
    ], capture_output=True)
    
    return output_path


def generate_track(
    model: MusicGen,
    prompt: str,
    reference_path: Path | None = None,
    duration: int = 120,
    output_dir: Path = OUTPUT_DIR
) -> Path:
    """Generate a single track"""
    
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    
    model.set_generation_params(duration=duration)
    
    if reference_path:
        # Convert reference to WAV
        ref_wav = convert_to_wav(reference_path, duration=30)
        ref_audio, ref_sr = sf.read(str(ref_wav))
        ref_tensor = torch.tensor(ref_audio).float().unsqueeze(0).unsqueeze(0)
        
        print(f"  Reference: {reference_path.name[:50]}...")
        print(f"  Prompt: {prompt}")
        
        wav = model.generate_with_chroma([prompt], ref_tensor, ref_sr)
        
        # Clean up temp file
        ref_wav.unlink(missing_ok=True)
        
        output_name = f"gen_{timestamp}_ref.wav"
    else:
        print(f"  Prompt: {prompt}")
        wav = model.generate([prompt])
        output_name = f"gen_{timestamp}.wav"
    
    # Save
    audio = wav[0, 0].cpu().numpy()
    output_path = output_dir / output_name
    sf.write(str(output_path), audio, SAMPLE_RATE)
    
    # Also save metadata
    meta_path = output_path.with_suffix('.txt')
    with open(meta_path, 'w') as f:
        f.write(f"Generated: {timestamp}\n")
        f.write(f"Duration: {duration}s\n")
        f.write(f"Prompt: {prompt}\n")
        if reference_path:
            f.write(f"Reference: {reference_path}\n")
    
    return output_path


def batch_generate(
    count: int = 5,
    duration: int = 120,
    use_references: bool = True,
    specific_reference: Path | None = None
):
    """Generate multiple tracks"""
    
    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    print(f"Device: {device}")
    
    # Use melody model for reference-based, medium for prompt-only
    model_name = 'facebook/musicgen-melody' if use_references else 'facebook/musicgen-medium'
    print(f"Loading {model_name}...")
    model = MusicGen.get_pretrained(model_name, device=device)
    
    # Find reference tracks
    if use_references and not specific_reference:
        tracks = find_reference_tracks(DJ_COLLECTION)
        print(f"Found {len(tracks)} tracks in DJ collection")
        if not tracks:
            print("Warning: No tracks found, generating without references")
            use_references = False
    
    print(f"\nGenerating {count} tracks ({duration}s each)...")
    print(f"Output: {OUTPUT_DIR}\n")
    
    for i in range(count):
        print(f"[{i+1}/{count}] Generating...")
        
        # Pick random prompt
        prompt = random.choice(STYLE_PROMPTS)
        
        # Pick random reference
        if specific_reference:
            ref = specific_reference
        elif use_references and tracks:
            ref = random.choice(tracks)
        else:
            ref = None
        
        start = time.time()
        output = generate_track(model, prompt, ref, duration)
        elapsed = time.time() - start
        
        print(f"  ✓ Saved: {output.name}")
        print(f"  Time: {elapsed:.0f}s ({duration/elapsed:.2f}x realtime)\n")
    
    print(f"Done! {count} tracks saved to {OUTPUT_DIR}")


def daemon_mode(interval: int = 300, duration: int = 120):
    """Run as background daemon, generating tracks periodically"""
    
    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    print(f"Device: {device}")
    print(f"Daemon mode: generating every {interval}s")
    
    model = MusicGen.get_pretrained('facebook/musicgen-melody', device=device)
    tracks = find_reference_tracks(DJ_COLLECTION)
    
    if not tracks:
        print("Error: No tracks in DJ collection")
        return
    
    print(f"Found {len(tracks)} reference tracks")
    print(f"Output: {OUTPUT_DIR}")
    print("\nStarting generation loop (Ctrl+C to stop)...\n")
    
    generation_count = 0
    
    try:
        while True:
            generation_count += 1
            print(f"=== Generation #{generation_count} ===")
            
            prompt = random.choice(STYLE_PROMPTS)
            ref = random.choice(tracks)
            
            start = time.time()
            output = generate_track(model, prompt, ref, duration)
            elapsed = time.time() - start
            
            print(f"  ✓ {output.name} ({elapsed:.0f}s)")
            
            # Wait for next generation
            wait_time = max(0, interval - elapsed)
            if wait_time > 0:
                print(f"  Waiting {wait_time:.0f}s until next generation...")
                time.sleep(wait_time)
            
    except KeyboardInterrupt:
        print(f"\n\nStopped. Generated {generation_count} tracks.")


def main():
    parser = argparse.ArgumentParser(description='MusicGen Batch Generator')
    parser.add_argument('--count', '-n', type=int, default=5,
                        help='Number of tracks to generate')
    parser.add_argument('--duration', '-d', type=int, default=120,
                        help='Duration per track in seconds')
    parser.add_argument('--reference', '-r', type=str,
                        help='Specific reference track to use')
    parser.add_argument('--no-reference', action='store_true',
                        help='Generate without reference audio')
    parser.add_argument('--daemon', action='store_true',
                        help='Run as background daemon')
    parser.add_argument('--interval', type=int, default=300,
                        help='Seconds between generations in daemon mode')
    parser.add_argument('--output', '-o', type=str,
                        help='Output directory')
    
    args = parser.parse_args()
    
    global OUTPUT_DIR
    if args.output:
        OUTPUT_DIR = Path(args.output)
    
    if args.daemon:
        daemon_mode(args.interval, args.duration)
    else:
        batch_generate(
            count=args.count,
            duration=args.duration,
            use_references=not args.no_reference,
            specific_reference=Path(args.reference) if args.reference else None
        )


if __name__ == '__main__':
    main()

