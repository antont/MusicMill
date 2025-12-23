#!/usr/bin/env python3
"""
Test PhrasePlayer by generating a test audio file with crossfades.

This demonstrates how phrase playback would work with beat-aligned crossfades.
"""

import json
import subprocess
import sys
from pathlib import Path
import random

# Paths
SEGMENTS_FILE = Path.home() / "Documents/MusicMill/PhraseSegments/segments.json"
OUTPUT_FILE = Path.home() / "Documents/MusicMill/phrase_test_output.wav"

def load_segments():
    """Load segment metadata"""
    if not SEGMENTS_FILE.exists():
        print(f"Error: {SEGMENTS_FILE} not found")
        print("Run test_phrase_player.py first to create segments")
        return None
    
    with open(SEGMENTS_FILE) as f:
        data = json.load(f)
    return data.get("segments", [])

def create_test_playback(segments, num_segments=4, crossfade_seconds=2.0):
    """Create a test playback by concatenating segments with crossfades"""
    
    if len(segments) < num_segments:
        num_segments = len(segments)
    
    # Select random segments
    selected = random.sample(segments, num_segments)
    
    print(f"Creating test with {num_segments} segments:")
    for i, seg in enumerate(selected):
        name = Path(seg["file"]).stem[:40]
        print(f"  {i+1}. {name} ({seg['tempo']:.1f} BPM, {seg['type']})")
    
    # Use ffmpeg to concatenate with crossfades
    # Build filter complex for crossfading
    inputs = []
    filter_parts = []
    
    for i, seg in enumerate(selected):
        inputs.extend(["-i", seg["file"]])
    
    # Create crossfade filter
    if num_segments == 1:
        filter_complex = "[0:a]volume=1.0[out]"
    else:
        # Chain crossfades
        current = "[0:a]"
        for i in range(1, num_segments):
            next_input = f"[{i}:a]"
            output = f"[cf{i}]" if i < num_segments - 1 else "[out]"
            filter_parts.append(
                f"{current}{next_input}acrossfade=d={crossfade_seconds}:c1=tri:c2=tri{output}"
            )
            current = output if i < num_segments - 1 else ""
        filter_complex = ";".join(filter_parts)
    
    cmd = [
        "ffmpeg", "-y"
    ] + inputs + [
        "-filter_complex", filter_complex,
        "-map", "[out]",
        "-ar", "44100",
        "-ac", "2",
        str(OUTPUT_FILE)
    ]
    
    print(f"\nRunning ffmpeg...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        print(f"Error: {result.stderr}")
        return False
    
    return True

def main():
    print("=== PhrasePlayer Test Playback ===\n")
    
    segments = load_segments()
    if not segments:
        return 1
    
    print(f"Found {len(segments)} segments\n")
    
    # Create test with 4 segments and 2-second crossfades
    if create_test_playback(segments, num_segments=4, crossfade_seconds=2.0):
        print(f"\n✓ Created: {OUTPUT_FILE}")
        
        # Get duration
        duration_cmd = [
            "ffprobe", "-v", "quiet", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", str(OUTPUT_FILE)
        ]
        result = subprocess.run(duration_cmd, capture_output=True, text=True)
        if result.returncode == 0:
            duration = float(result.stdout.strip())
            print(f"  Duration: {duration:.1f}s")
        
        print(f"\nPlay with: afplay '{OUTPUT_FILE}'")
    else:
        print("Failed to create test playback")
        return 1
    
    return 0

if __name__ == "__main__":
    sys.exit(main())

