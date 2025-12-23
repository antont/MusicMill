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
# Only use actual imported music, not samples/demos
DJ_COLLECTION = Path.home() / "Music/PioneerDJ/Imported from Device/Contents"
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


def find_reference_tracks(collection_path: Path, min_size_kb: int = 1000) -> list[Path]:
    """Find all audio files in the DJ collection, filtering out small samples"""
    extensions = {'.mp3', '.wav', '.flac', '.m4a', '.aiff'}
    tracks = []
    for ext in extensions:
        for f in collection_path.rglob(f'*{ext}'):
            # Filter out small files (likely samples/FX, not full tracks)
            if f.stat().st_size > min_size_kb * 1024:
                tracks.append(f)
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
    
    successful = 0
    failed_refs = set()
    
    for i in range(count):
        print(f"[{i+1}/{count}] Generating...")
        
        # Pick random prompt
        prompt = random.choice(STYLE_PROMPTS)
        
        # Pick random reference (avoid previously failed ones)
        if specific_reference:
            ref = specific_reference
        elif use_references and tracks:
            available = [t for t in tracks if t not in failed_refs]
            if not available:
                print("  Warning: All references failed, generating without reference")
                ref = None
            else:
                ref = random.choice(available)
        else:
            ref = None
        
        start = time.time()
        try:
            output = generate_track(model, prompt, ref, duration)
            elapsed = time.time() - start
            print(f"  ✓ Saved: {output.name}")
            print(f"  Time: {elapsed:.0f}s ({duration/elapsed:.2f}x realtime)\n")
            successful += 1
        except RuntimeError as e:
            if "probability tensor" in str(e) or "nan" in str(e).lower():
                print(f"  ✗ Failed (bad reference audio): {ref.name if ref else 'N/A'}")
                if ref:
                    failed_refs.add(ref)
                # Retry without reference
                try:
                    print("  Retrying without reference...")
                    output = generate_track(model, prompt, None, duration)
                    elapsed = time.time() - start
                    print(f"  ✓ Saved: {output.name}")
                    successful += 1
                except Exception as e2:
                    print(f"  ✗ Retry also failed: {e2}")
            else:
                print(f"  ✗ Error: {e}")
    
    print(f"\nDone! {successful}/{count} tracks saved to {OUTPUT_DIR}")
    if failed_refs:
        print(f"Problematic references (skipped): {len(failed_refs)}")


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


def interactive_mode(duration: int = 90):
    """Interactive mode - enter reference + prompt, get generation"""
    
    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    print(f"Device: {device}")
    print("Loading MusicGen melody (with reference support)...")
    model = MusicGen.get_pretrained('facebook/musicgen-melody', device=device)
    
    tracks = find_reference_tracks(DJ_COLLECTION)
    print(f"Found {len(tracks)} tracks in DJ collection")
    print(f"Output: {OUTPUT_DIR}\n")
    
    print("=" * 60)
    print("INTERACTIVE MODE")
    print("=" * 60)
    print("Enter a reference track (path, number, or 'random')")
    print("Then enter your custom prompt")
    print("Type 'list' to see available tracks")
    print("Type 'quit' to exit")
    print("=" * 60)
    
    # Index tracks for easy selection
    track_index = {i: t for i, t in enumerate(tracks)}
    
    while True:
        print("\n")
        ref_input = input("Reference (path/number/random/list): ").strip()
        
        if ref_input.lower() == 'quit':
            break
        
        if ref_input.lower() == 'list':
            print("\nAvailable tracks:")
            for i, t in enumerate(tracks[:30]):  # Show first 30
                print(f"  {i}: {t.name[:60]}")
            if len(tracks) > 30:
                print(f"  ... and {len(tracks) - 30} more")
            continue
        
        # Resolve reference
        if ref_input.lower() == 'random':
            ref_path = random.choice(tracks)
        elif ref_input.isdigit():
            idx = int(ref_input)
            if idx in track_index:
                ref_path = track_index[idx]
            else:
                print(f"Invalid index. Use 0-{len(tracks)-1}")
                continue
        else:
            ref_path = Path(ref_input).expanduser()
            if not ref_path.exists():
                print(f"File not found: {ref_path}")
                continue
        
        print(f"Using: {ref_path.name}")
        
        # Get prompt
        prompt = input("Your prompt (or Enter for default): ").strip()
        if not prompt:
            prompt = random.choice(STYLE_PROMPTS)
            print(f"Using: {prompt}")
        
        # Generate
        print(f"\nGenerating {duration}s with your prompt...")
        start = time.time()
        
        model.set_generation_params(duration=duration)
        
        # Convert reference
        ref_wav = convert_to_wav(ref_path, duration=30)
        ref_audio, ref_sr = sf.read(str(ref_wav))
        ref_tensor = torch.tensor(ref_audio).float().unsqueeze(0).unsqueeze(0)
        
        wav = model.generate_with_chroma([prompt], ref_tensor, ref_sr)
        ref_wav.unlink(missing_ok=True)
        
        # Save
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        output_path = OUTPUT_DIR / f"interactive_{timestamp}.wav"
        
        audio = wav[0, 0].cpu().numpy()
        sf.write(str(output_path), audio, SAMPLE_RATE)
        
        elapsed = time.time() - start
        print(f"\n✓ Saved: {output_path}")
        print(f"  Time: {elapsed:.0f}s ({duration/elapsed:.2f}x realtime)")
        
        # Save metadata
        meta_path = output_path.with_suffix('.txt')
        with open(meta_path, 'w') as f:
            f.write(f"Generated: {timestamp}\n")
            f.write(f"Duration: {duration}s\n")
            f.write(f"Prompt: {prompt}\n")
            f.write(f"Reference: {ref_path}\n")


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
    parser.add_argument('--interactive', '-i', action='store_true',
                        help='Interactive mode - enter reference + prompt')
    parser.add_argument('--prompt', '-p', type=str,
                        help='Custom prompt (use with --reference)')
    parser.add_argument('--quick', '-q', action='store_true',
                        help='Quick single generation with reference + prompt')
    
    args = parser.parse_args()
    
    global OUTPUT_DIR
    if args.output:
        OUTPUT_DIR = Path(args.output)
    
    if args.quick:
        # Quick one-shot generation
        if not args.reference:
            print("Error: --quick requires --reference")
            sys.exit(1)
        prompt = args.prompt or random.choice(STYLE_PROMPTS)
        
        device = 'mps' if torch.backends.mps.is_available() else 'cpu'
        print(f"Quick generation on {device}...")
        model = MusicGen.get_pretrained('facebook/musicgen-melody', device=device)
        
        output = generate_track(
            model, prompt, 
            Path(args.reference), 
            args.duration, 
            OUTPUT_DIR
        )
        print(f"✓ {output}")
    elif args.interactive:
        interactive_mode(args.duration)
    elif args.daemon:
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

