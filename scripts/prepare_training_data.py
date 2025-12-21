#!/usr/bin/env python3
"""
Prepare training data for RAVE from MusicMill analysis or directly from MP3 collection.
Uses RAVE's lazy preprocessing to train directly on MP3/OGG files without conversion.

Reference: https://github.com/acids-ircam/RAVE#dataset-preparation
"""

import os
import sys
import json
import subprocess
import shutil
from pathlib import Path
import argparse

# Configuration
ANALYSIS_DIR = Path.home() / "Documents" / "MusicMill" / "Analysis"
PREPROCESSED_DIR = Path.home() / ".musicmill" / "rave_preprocessed"


def find_audio_files(input_path: Path, recursive: bool = True):
    """Find all audio files in a directory."""
    audio_extensions = {'.mp3', '.ogg', '.wav', '.flac', '.m4a', '.aiff', '.aac'}
    
    if not input_path.exists():
        print(f"❌ Directory not found: {input_path}")
        return []
    
    files = []
    if recursive:
        for ext in audio_extensions:
            files.extend(input_path.rglob(f"*{ext}"))
    else:
        for ext in audio_extensions:
            files.extend(input_path.glob(f"*{ext}"))
    
    return sorted(files)


def find_musicmill_segments():
    """Find analyzed segments from MusicMill Analysis directory."""
    segments = []
    
    if not ANALYSIS_DIR.exists():
        return segments
    
    for collection_dir in ANALYSIS_DIR.iterdir():
        if not collection_dir.is_dir():
            continue
            
        segments_dir = collection_dir / "Segments"
        if segments_dir.exists():
            segments.extend(find_audio_files(segments_dir, recursive=False))
    
    return segments


def get_total_duration(files):
    """Calculate total duration of audio files using ffprobe."""
    total_duration = 0
    for f in files:
        try:
            result = subprocess.run(
                ['ffprobe', '-v', 'error', '-show_entries', 
                 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1',
                 str(f)],
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                total_duration += float(result.stdout.strip())
        except:
            pass
    return total_duration


def run_rave_preprocess(input_path: Path, output_path: Path, lazy: bool = True):
    """Run RAVE preprocessing."""
    cmd = [
        'rave', 'preprocess',
        '--input_path', str(input_path),
        '--output_path', str(output_path),
    ]
    
    if lazy:
        cmd.append('--lazy')
    
    print(f"\n    Running: {' '.join(cmd)}")
    
    try:
        result = subprocess.run(cmd)
        return result.returncode == 0
    except FileNotFoundError:
        print("❌ RAVE not found. Install it with: pip install acids-rave")
        print("   Or run: ./scripts/setup_rave.sh")
        return False


def main():
    parser = argparse.ArgumentParser(
        description='Prepare training data for RAVE neural audio synthesis',
        epilog='Uses lazy preprocessing to train directly on MP3/OGG files.'
    )
    parser.add_argument(
        '--input', '-i', type=Path,
        help='Input directory containing audio files (MP3, OGG, WAV, etc.)'
    )
    parser.add_argument(
        '--output', '-o', type=Path, default=PREPROCESSED_DIR,
        help=f'Output directory for preprocessed data (default: {PREPROCESSED_DIR})'
    )
    parser.add_argument(
        '--use-segments', action='store_true',
        help='Use MusicMill analyzed segments instead of raw files'
    )
    parser.add_argument(
        '--no-lazy', action='store_true',
        help='Disable lazy loading (converts files first, uses less CPU during training)'
    )
    args = parser.parse_args()
    
    print("🎵 Preparing training data for RAVE")
    print("=" * 50)
    
    lazy_mode = not args.no_lazy
    if lazy_mode:
        print("\n📦 Using LAZY mode - training directly on MP3/OGG files")
        print("   (Higher CPU usage during training, but no conversion needed)")
    else:
        print("\n📦 Using EAGER mode - converting files first")
        print("   (Lower CPU usage during training)")
    
    # Determine input source
    if args.use_segments:
        print("\n[1] Finding MusicMill analyzed segments...")
        audio_files = find_musicmill_segments()
        if not audio_files:
            print("❌ No segments found. Run analysis in MusicMill first.")
            sys.exit(1)
        
        # Create a temp directory with symlinks to segments
        input_dir = args.output.parent / "rave_input_segments"
        input_dir.mkdir(parents=True, exist_ok=True)
        
        print(f"    Creating symlinks in {input_dir}...")
        for f in audio_files:
            link = input_dir / f.name
            if not link.exists():
                link.symlink_to(f)
        
    elif args.input:
        input_dir = args.input
        print(f"\n[1] Scanning audio files in {input_dir}...")
        audio_files = find_audio_files(input_dir)
        
        if not audio_files:
            print(f"❌ No audio files found in {input_dir}")
            sys.exit(1)
    else:
        # Default: look for common music directories
        possible_dirs = [
            Path.home() / "Music",
            Path.home() / "Music" / "PioneerDJ" / "Imported from Device" / "Contents",
            ANALYSIS_DIR,
        ]
        
        for d in possible_dirs:
            if d.exists():
                audio_files = find_audio_files(d)
                if audio_files:
                    input_dir = d
                    print(f"\n[1] Found audio files in {input_dir}")
                    break
        else:
            print("❌ No audio files found. Specify input with --input /path/to/music")
            sys.exit(1)
    
    print(f"    Found {len(audio_files)} audio files")
    
    # Show file type breakdown
    extensions = {}
    for f in audio_files:
        ext = f.suffix.lower()
        extensions[ext] = extensions.get(ext, 0) + 1
    
    print("\n    File types:")
    for ext, count in sorted(extensions.items(), key=lambda x: -x[1]):
        print(f"      {ext}: {count}")
    
    # Calculate duration
    print("\n[2] Calculating total duration...")
    duration = get_total_duration(audio_files[:100])  # Sample first 100 for speed
    if len(audio_files) > 100:
        # Estimate total from sample
        duration = duration * len(audio_files) / 100
        print(f"    Estimated: {duration/3600:.1f} hours ({duration/60:.0f} minutes)")
    else:
        print(f"    Total: {duration/3600:.1f} hours ({duration/60:.0f} minutes)")
    
    if duration / 3600 < 1:
        print("\n⚠️  Warning: RAVE works best with 2+ hours of audio.")
        print("    Consider adding more music to your collection.")
    elif duration / 3600 > 10:
        print(f"\n✓ Great! {duration/3600:.0f} hours is plenty for training.")
    
    # Run RAVE preprocessing
    print(f"\n[3] Running RAVE preprocessing...")
    args.output.mkdir(parents=True, exist_ok=True)
    
    success = run_rave_preprocess(input_dir, args.output, lazy=lazy_mode)
    
    if success:
        print("\n" + "=" * 50)
        print("✓ Preprocessing complete!")
        print(f"  Output: {args.output}")
        print("\nNext step:")
        print(f"  python scripts/train_rave.py --db_path {args.output}")
    else:
        print("\n❌ Preprocessing failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
