#!/usr/bin/env python3
"""
Prepare training data for RAVE from MusicMill analysis results.

Reads analyzed segments from ~/Documents/MusicMill/Analysis/
and converts them to WAV format at 48kHz for RAVE training.

Usage:
    python prepare_training_data.py [--output-dir DIR] [--sample-rate RATE]
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

# Default paths
ANALYSIS_DIR = os.path.expanduser("~/Documents/MusicMill/Analysis")
OUTPUT_DIR = os.path.expanduser("~/Documents/MusicMill/RAVE/training_data")
SAMPLE_RATE = 48000  # RAVE requirement


def find_analysis_directories():
    """Find all analysis directories with segments."""
    analysis_path = Path(ANALYSIS_DIR)
    if not analysis_path.exists():
        print(f"Analysis directory not found: {ANALYSIS_DIR}")
        print("Run MusicMill analysis first to generate segments.")
        return []
    
    directories = []
    for item in analysis_path.iterdir():
        if item.is_dir() and not item.name.startswith('.'):
            analysis_json = item / "analysis.json"
            segments_dir = item / "Segments"
            if analysis_json.exists() and segments_dir.exists():
                directories.append(item)
    
    return directories


def load_analysis(analysis_dir: Path) -> dict:
    """Load analysis.json from a directory."""
    analysis_json = analysis_dir / "analysis.json"
    with open(analysis_json, 'r') as f:
        return json.load(f)


def get_segments(analysis_dir: Path) -> list:
    """Get all segment files from an analysis directory."""
    segments_dir = analysis_dir / "Segments"
    if not segments_dir.exists():
        return []
    
    segments = []
    for f in segments_dir.iterdir():
        if f.suffix.lower() in ['.m4a', '.mp3', '.wav', '.aiff', '.aif']:
            segments.append(f)
    
    return sorted(segments)


def convert_to_wav(input_path: Path, output_path: Path, sample_rate: int = SAMPLE_RATE) -> bool:
    """Convert audio file to WAV format at specified sample rate using ffmpeg."""
    try:
        # Ensure output directory exists
        output_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Use ffmpeg for conversion
        cmd = [
            'ffmpeg', '-y',  # Overwrite output
            '-i', str(input_path),
            '-ar', str(sample_rate),  # Sample rate
            '-ac', '1',  # Mono (RAVE uses mono)
            '-c:a', 'pcm_f32le',  # 32-bit float WAV
            str(output_path)
        ]
        
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            print(f"  Error converting {input_path.name}: {result.stderr[:200]}")
            return False
        
        return True
        
    except Exception as e:
        print(f"  Exception converting {input_path.name}: {e}")
        return False


def get_style_from_segment(segment_path: Path, analysis: dict) -> str:
    """Extract style label from segment filename or analysis data."""
    # Segment names are like: BLVCKCEILING_-_BALANCE_BALANCE_seg0.m4a
    # Format: ARTIST_-_TITLE_STYLE_segN.ext
    
    name = segment_path.stem
    parts = name.rsplit('_seg', 1)
    if len(parts) == 2:
        # Get the style part (last underscore-separated word before _segN)
        prefix = parts[0]
        # Try to find style in organized styles
        for style in analysis.get('organizedStyles', {}).keys():
            # Normalize for comparison
            normalized_style = style.replace(' ', '_').replace('/', '_')
            if normalized_style in prefix:
                return style
    
    return "unknown"


def main():
    parser = argparse.ArgumentParser(description="Prepare RAVE training data from MusicMill analysis")
    parser.add_argument('--output-dir', '-o', default=OUTPUT_DIR,
                        help=f'Output directory for WAV files (default: {OUTPUT_DIR})')
    parser.add_argument('--sample-rate', '-r', type=int, default=SAMPLE_RATE,
                        help=f'Target sample rate (default: {SAMPLE_RATE})')
    parser.add_argument('--organize-by-style', '-s', action='store_true',
                        help='Organize output by style folders')
    parser.add_argument('--max-workers', '-w', type=int, default=4,
                        help='Number of parallel conversion workers')
    parser.add_argument('--dry-run', '-n', action='store_true',
                        help='Show what would be done without converting')
    
    args = parser.parse_args()
    
    output_dir = Path(args.output_dir)
    
    print("=" * 60)
    print("MusicMill RAVE Training Data Preparation")
    print("=" * 60)
    print(f"Analysis directory: {ANALYSIS_DIR}")
    print(f"Output directory: {output_dir}")
    print(f"Sample rate: {args.sample_rate} Hz")
    print()
    
    # Find all analysis directories
    analysis_dirs = find_analysis_directories()
    if not analysis_dirs:
        print("No analysis results found. Run MusicMill analysis first.")
        sys.exit(1)
    
    print(f"Found {len(analysis_dirs)} analyzed collection(s):")
    for d in analysis_dirs:
        print(f"  - {d.name}")
    print()
    
    # Collect all segments to convert
    all_segments = []
    for analysis_dir in analysis_dirs:
        analysis = load_analysis(analysis_dir)
        segments = get_segments(analysis_dir)
        
        collection_name = analysis.get('collectionPath', '').split('/')[-1] or analysis_dir.name
        
        for segment in segments:
            style = get_style_from_segment(segment, analysis)
            all_segments.append({
                'input': segment,
                'collection': collection_name,
                'style': style,
                'analysis': analysis
            })
    
    print(f"Total segments to process: {len(all_segments)}")
    
    if not all_segments:
        print("No segments found to convert.")
        sys.exit(1)
    
    # Calculate output paths
    conversions = []
    style_counts = {}
    
    for seg_info in all_segments:
        segment = seg_info['input']
        style = seg_info['style']
        
        # Track style distribution
        style_counts[style] = style_counts.get(style, 0) + 1
        
        # Determine output path
        if args.organize_by_style:
            # Normalize style name for directory
            style_dir = style.replace(' ', '_').replace('/', '_')
            out_path = output_dir / style_dir / f"{segment.stem}.wav"
        else:
            out_path = output_dir / f"{segment.stem}.wav"
        
        conversions.append({
            'input': segment,
            'output': out_path,
            'style': style
        })
    
    print("\nStyle distribution:")
    for style, count in sorted(style_counts.items()):
        print(f"  {style}: {count} segments")
    
    # Calculate total duration estimate
    # Each segment is about 30 seconds
    total_duration_estimate = len(all_segments) * 30 / 60
    print(f"\nEstimated total audio: ~{total_duration_estimate:.1f} minutes")
    
    if args.dry_run:
        print("\n[Dry run - no files converted]")
        print(f"\nWould convert {len(conversions)} segments to: {output_dir}")
        return
    
    # Create output directory
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Convert files in parallel
    print(f"\nConverting {len(conversions)} segments...")
    
    successful = 0
    failed = 0
    
    with ThreadPoolExecutor(max_workers=args.max_workers) as executor:
        futures = {}
        for conv in conversions:
            future = executor.submit(
                convert_to_wav,
                conv['input'],
                conv['output'],
                args.sample_rate
            )
            futures[future] = conv
        
        for i, future in enumerate(as_completed(futures)):
            conv = futures[future]
            try:
                if future.result():
                    successful += 1
                else:
                    failed += 1
            except Exception as e:
                print(f"  Error: {e}")
                failed += 1
            
            # Progress indicator
            if (i + 1) % 10 == 0 or (i + 1) == len(conversions):
                print(f"  Progress: {i + 1}/{len(conversions)} ({successful} ok, {failed} failed)")
    
    print()
    print("=" * 60)
    print(f"Conversion complete!")
    print(f"  Successful: {successful}")
    print(f"  Failed: {failed}")
    print(f"  Output: {output_dir}")
    print()
    
    # Show total size
    total_size = sum(f.stat().st_size for f in output_dir.rglob("*.wav"))
    print(f"Total size: {total_size / 1024 / 1024:.1f} MB")
    
    # Show RAVE training command
    print()
    print("Next steps:")
    print("-" * 40)
    print(f"1. Run RAVE preprocessing:")
    print(f"   rave preprocess --input_path {output_dir} --output_path ~/Documents/MusicMill/RAVE/preprocessed --lazy")
    print()
    print(f"2. Train RAVE model:")
    print(f"   rave train --config v2 --db_path ~/Documents/MusicMill/RAVE/preprocessed --name musicmill_v2")


if __name__ == "__main__":
    main()
