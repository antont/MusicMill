#!/usr/bin/env python3
"""
Prepare training data for RAVE from MusicMill analysis segments.
Converts audio segments to WAV format suitable for RAVE training.
"""

import os
import sys
import json
import subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

# Configuration
ANALYSIS_DIR = Path.home() / "Documents" / "MusicMill" / "Analysis"
OUTPUT_DIR = Path.home() / ".musicmill" / "rave_training_data"
SAMPLE_RATE = 44100
CHANNELS = 1  # RAVE works best with mono


def find_segments():
    """Find all analyzed segments from MusicMill."""
    segments = []
    
    if not ANALYSIS_DIR.exists():
        print(f"❌ Analysis directory not found: {ANALYSIS_DIR}")
        print("   Run analysis in MusicMill first.")
        return segments
    
    for collection_dir in ANALYSIS_DIR.iterdir():
        if not collection_dir.is_dir():
            continue
            
        segments_dir = collection_dir / "Segments"
        if not segments_dir.exists():
            continue
            
        # Load analysis metadata
        analysis_file = collection_dir / "analysis.json"
        style = None
        if analysis_file.exists():
            try:
                with open(analysis_file) as f:
                    metadata = json.load(f)
                    # Extract style from first category if available
                    styles = metadata.get("organizedStyles", {})
                    if styles:
                        style = list(styles.keys())[0]
            except Exception as e:
                print(f"Warning: Could not load metadata from {analysis_file}: {e}")
        
        # Find all audio segments
        for segment_file in segments_dir.iterdir():
            if segment_file.suffix.lower() in ['.m4a', '.mp3', '.wav', '.aiff', '.aac']:
                segments.append({
                    'path': segment_file,
                    'style': style or collection_dir.name,
                    'collection': collection_dir.name
                })
    
    return segments


def convert_to_wav(segment, output_dir):
    """Convert a segment to WAV format using ffmpeg."""
    input_path = segment['path']
    style = segment['style'].replace('/', '_').replace(' ', '_')
    
    # Create style subdirectory
    style_dir = output_dir / style
    style_dir.mkdir(parents=True, exist_ok=True)
    
    # Output path
    output_name = input_path.stem + '.wav'
    output_path = style_dir / output_name
    
    if output_path.exists():
        return output_path, "skipped"
    
    try:
        # Use ffmpeg to convert
        cmd = [
            'ffmpeg', '-y', '-i', str(input_path),
            '-ar', str(SAMPLE_RATE),
            '-ac', str(CHANNELS),
            '-acodec', 'pcm_s16le',
            str(output_path)
        ]
        
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            return None, f"ffmpeg error: {result.stderr[:200]}"
            
        return output_path, "converted"
        
    except Exception as e:
        return None, str(e)


def main():
    print("🎵 Preparing training data for RAVE")
    print("=" * 50)
    
    # Find segments
    print("\n[1] Finding analyzed segments...")
    segments = find_segments()
    
    if not segments:
        print("No segments found. Please run analysis in MusicMill first.")
        sys.exit(1)
    
    print(f"    Found {len(segments)} segments")
    
    # Show style breakdown
    styles = {}
    for seg in segments:
        style = seg['style']
        styles[style] = styles.get(style, 0) + 1
    
    print("\n    Breakdown by style:")
    for style, count in sorted(styles.items()):
        print(f"      {style}: {count} segments")
    
    # Create output directory
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"\n[2] Converting to WAV format...")
    print(f"    Output: {OUTPUT_DIR}")
    
    # Convert in parallel
    converted = 0
    skipped = 0
    failed = 0
    
    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {
            executor.submit(convert_to_wav, seg, OUTPUT_DIR): seg
            for seg in segments
        }
        
        for future in as_completed(futures):
            result, status = future.result()
            if status == "converted":
                converted += 1
            elif status == "skipped":
                skipped += 1
            else:
                failed += 1
                seg = futures[future]
                print(f"    ❌ Failed: {seg['path'].name} - {status}")
            
            # Progress
            done = converted + skipped + failed
            if done % 10 == 0:
                print(f"    Progress: {done}/{len(segments)}")
    
    print(f"\n[3] Summary:")
    print(f"    Converted: {converted}")
    print(f"    Skipped (already exists): {skipped}")
    print(f"    Failed: {failed}")
    
    # Calculate total duration
    total_duration = 0
    for wav_file in OUTPUT_DIR.rglob("*.wav"):
        try:
            # Get duration using ffprobe
            result = subprocess.run(
                ['ffprobe', '-v', 'error', '-show_entries', 
                 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1',
                 str(wav_file)],
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                total_duration += float(result.stdout.strip())
        except:
            pass
    
    hours = total_duration / 3600
    print(f"\n    Total audio: {hours:.1f} hours ({total_duration/60:.0f} minutes)")
    
    if hours < 1:
        print("\n⚠️  Warning: RAVE works best with 2+ hours of audio.")
        print("    Consider adding more music to your collection.")
    
    print(f"\n✓ Training data prepared at: {OUTPUT_DIR}")
    print("\nNext step: python scripts/train_rave.py")


if __name__ == "__main__":
    main()

