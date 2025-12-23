#!/usr/bin/env python3
"""
Test script to verify librosa analysis and prepare audio for PhrasePlayer.

This script:
1. Loads the librosa analysis JSON
2. Picks tracks with good beat detection
3. Creates a test playlist with beat-aligned info
4. Outputs audio segments ready for PhrasePlayer
"""

import json
import os
import subprocess
from pathlib import Path

# Paths
ANALYSIS_FILE = Path.home() / "Documents/MusicMill/Analysis/librosa_analysis.json"
OUTPUT_DIR = Path.home() / "Documents/MusicMill/PhraseSegments"

def load_analysis():
    """Load the librosa analysis results"""
    if not ANALYSIS_FILE.exists():
        print(f"Error: Analysis file not found at {ANALYSIS_FILE}")
        print("Run: python scripts/analyze_library.py ~/Music/PioneerDJ/... first")
        return None
    
    with open(ANALYSIS_FILE) as f:
        return json.load(f)

def find_best_tracks(analysis, count=10):
    """Find tracks with good beat detection (lots of beats, reasonable tempo)"""
    tracks = analysis.get("tracks", [])
    
    # Score tracks by beat detection quality
    scored = []
    for track in tracks:
        beats = len(track.get("beats", []))
        tempo = track.get("tempo", 0)
        segments = len(track.get("segments", []))
        
        # Prefer tracks with:
        # - Many beats (good detection)
        # - Reasonable tempo (80-180 BPM)
        # - Multiple segments
        score = beats
        if 80 <= tempo <= 180:
            score *= 1.5
        score += segments * 10
        
        scored.append((score, track))
    
    scored.sort(reverse=True, key=lambda x: x[0])
    return [t for _, t in scored[:count]]

def extract_segment(track, start_time, end_time, output_path):
    """Extract a segment from a track using ffmpeg"""
    duration = end_time - start_time
    
    cmd = [
        'ffmpeg', '-y',
        '-i', track["path"],
        '-ss', str(start_time),
        '-t', str(duration),
        '-ar', '44100',
        '-ac', '2',
        str(output_path)
    ]
    
    result = subprocess.run(cmd, capture_output=True)
    return result.returncode == 0

def create_phrase_segments(tracks, output_dir):
    """Create phrase segments from tracks"""
    output_dir.mkdir(parents=True, exist_ok=True)
    
    segments_info = []
    
    for i, track in enumerate(tracks):
        name = Path(track["path"]).stem[:30]
        tempo = track["tempo"]
        beats = track["beats"]
        downbeats = track.get("downbeats", beats[::4])
        segments = track.get("segments", [])
        
        print(f"\n[{i+1}/{len(tracks)}] {name}")
        print(f"  Tempo: {tempo:.1f} BPM, {len(beats)} beats")
        
        # Create segments based on phrase boundaries or every 16 bars
        if len(downbeats) >= 4:
            # Use 16-bar segments (4 downbeats)
            segment_starts = downbeats[::4]
            
            for j, start in enumerate(segment_starts[:-1]):
                end = segment_starts[j + 1] if j + 1 < len(segment_starts) else downbeats[-1]
                duration = end - start
                
                # Skip if too short or too long
                if duration < 8 or duration > 60:
                    continue
                
                seg_name = f"{name}_seg{j}.wav"
                output_path = output_dir / seg_name
                
                # Get segment type
                seg_type = "verse"
                for s in segments:
                    if s["start"] <= start < s["end"]:
                        seg_type = s["type"]
                        break
                
                print(f"  Segment {j}: {start:.1f}s - {end:.1f}s ({seg_type})")
                
                if extract_segment(track, start, end, output_path):
                    # Find beats within this segment (relative times)
                    seg_beats = [b - start for b in beats if start <= b < end]
                    seg_downbeats = [b - start for b in downbeats if start <= b < end]
                    
                    segments_info.append({
                        "file": str(output_path),
                        "source": track["path"],
                        "tempo": tempo,
                        "type": seg_type,
                        "duration": duration,
                        "beats": seg_beats,
                        "downbeats": seg_downbeats,
                        "energy": next((s["energy"] for s in segments if s["start"] <= start < s["end"]), 0.5)
                    })
                else:
                    print(f"    Failed to extract segment")
    
    return segments_info

def save_segments_info(segments_info, output_dir):
    """Save segment metadata for Swift to load"""
    output_file = output_dir / "segments.json"
    
    with open(output_file, 'w') as f:
        json.dump({
            "version": "1.0",
            "segments": segments_info
        }, f, indent=2)
    
    print(f"\nSaved {len(segments_info)} segments info to {output_file}")

def main():
    print("=== PhrasePlayer Test Setup ===\n")
    
    # Load analysis
    analysis = load_analysis()
    if not analysis:
        return
    
    print(f"Loaded analysis with {len(analysis.get('tracks', []))} tracks")
    
    # Find best tracks
    best_tracks = find_best_tracks(analysis, count=10)
    print(f"Selected {len(best_tracks)} best tracks for phrase segments")
    
    # Create output directory
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    
    # Create phrase segments
    segments_info = create_phrase_segments(best_tracks, OUTPUT_DIR)
    
    # Save metadata
    save_segments_info(segments_info, OUTPUT_DIR)
    
    print(f"\n=== Done! ===")
    print(f"Created {len(segments_info)} phrase segments in {OUTPUT_DIR}")
    print(f"\nTo use in MusicMill:")
    print(f"  1. The app should load segments from: {OUTPUT_DIR}")
    print(f"  2. Each segment has beat grid for aligned crossfades")

if __name__ == "__main__":
    main()

