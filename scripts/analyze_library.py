#!/usr/bin/env python3
"""
Music library analysis using librosa for professional-grade beat/phrase detection.

This script analyzes audio files and produces beat grids, phrase boundaries,
and segment classifications that can be used by the Swift PhrasePlayer.

Uses librosa 0.11+ for:
- Beat tracking (librosa.beat.beat_track)
- Onset detection (librosa.onset.onset_detect)
- Tempo estimation (librosa.beat.tempo)
- Structural segmentation via novelty detection

Output is saved to JSON format compatible with MusicMill's AnalysisStorage.
"""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional
import warnings

import librosa
import numpy as np

# Suppress librosa warnings about audioread
warnings.filterwarnings('ignore', category=FutureWarning)
warnings.filterwarnings('ignore', category=UserWarning)

# Analysis parameters
SAMPLE_RATE = 22050  # librosa default, good balance of quality/speed
HOP_LENGTH = 512  # ~23ms at 22050 Hz


def analyze_track(audio_path: Path, verbose: bool = False) -> dict:
    """
    Analyze a single audio track for beats, phrases, and structure.
    
    Returns dict with:
        - tempo: float (BPM)
        - beats: list of beat times in seconds
        - downbeats: list of bar start times (every 4 beats typically)
        - onsets: list of onset times
        - phrases: list of phrase boundary times
        - segments: list of {start, end, type, energy} dicts
        - energy_contour: list of energy values over time
    """
    if verbose:
        print(f"  Loading audio...")
    
    try:
        # Load audio (mono, resampled to SAMPLE_RATE)
        y, sr = librosa.load(str(audio_path), sr=SAMPLE_RATE, mono=True)
    except Exception as e:
        print(f"  Error loading {audio_path}: {e}")
        return None
    
    duration = len(y) / sr
    if verbose:
        print(f"  Duration: {duration:.1f}s")
    
    # === Beat Tracking ===
    if verbose:
        print(f"  Detecting beats...")
    
    tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr, hop_length=HOP_LENGTH)
    beat_times = librosa.frames_to_time(beat_frames, sr=sr, hop_length=HOP_LENGTH)
    
    # Handle tempo as array or scalar
    if hasattr(tempo, '__len__'):
        tempo = float(tempo[0]) if len(tempo) > 0 else 120.0
    else:
        tempo = float(tempo)
    
    if verbose:
        print(f"  Tempo: {tempo:.1f} BPM, {len(beat_times)} beats")
    
    # === Downbeats (bar boundaries) ===
    # Assume 4/4 time signature - every 4th beat is a downbeat
    downbeat_times = beat_times[::4].tolist() if len(beat_times) >= 4 else beat_times.tolist()
    
    # === Onset Detection ===
    if verbose:
        print(f"  Detecting onsets...")
    
    onset_frames = librosa.onset.onset_detect(
        y=y, sr=sr, hop_length=HOP_LENGTH,
        backtrack=True,  # Find true onset start
        units='frames'
    )
    onset_times = librosa.frames_to_time(onset_frames, sr=sr, hop_length=HOP_LENGTH)
    
    if verbose:
        print(f"  Found {len(onset_times)} onsets")
    
    # === Energy Contour ===
    if verbose:
        print(f"  Computing energy contour...")
    
    # RMS energy over time
    rms = librosa.feature.rms(y=y, hop_length=HOP_LENGTH)[0]
    rms_times = librosa.frames_to_time(np.arange(len(rms)), sr=sr, hop_length=HOP_LENGTH)
    
    # Normalize energy to 0-1
    rms_normalized = rms / (rms.max() + 1e-6)
    
    # Downsample energy for storage (every ~0.5 seconds)
    energy_step = int(0.5 * sr / HOP_LENGTH)
    energy_contour = [
        {"time": float(rms_times[i]), "energy": float(rms_normalized[i])}
        for i in range(0, len(rms), max(1, energy_step))
    ]
    
    # === Phrase/Segment Detection ===
    if verbose:
        print(f"  Detecting phrases and segments...")
    
    phrases, segments = detect_phrases_and_segments(y, sr, beat_times, rms, rms_times)
    
    if verbose:
        print(f"  Found {len(phrases)} phrase boundaries, {len(segments)} segments")
    
    # === Spectral Features for Matching ===
    if verbose:
        print(f"  Computing spectral features...")
    
    # Chromagram for harmonic content
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=HOP_LENGTH)
    
    # Spectral centroid (brightness)
    spectral_centroid = librosa.feature.spectral_centroid(y=y, sr=sr, hop_length=HOP_LENGTH)[0]
    avg_centroid = float(np.mean(spectral_centroid))
    
    # Key estimation (simplified - most prominent pitch class)
    chroma_mean = np.mean(chroma, axis=1)
    key_index = int(np.argmax(chroma_mean))
    key_names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
    estimated_key = key_names[key_index]
    
    return {
        "path": str(audio_path),
        "duration": float(duration),
        "tempo": tempo,
        "key": estimated_key,
        "spectralCentroid": avg_centroid,
        "beats": beat_times.tolist(),
        "downbeats": downbeat_times,
        "onsets": onset_times.tolist(),
        "phrases": phrases,
        "segments": segments,
        "energyContour": energy_contour,
    }


def detect_phrases_and_segments(y, sr, beat_times, rms, rms_times) -> tuple:
    """
    Detect phrase boundaries and classify segments.
    
    Uses bar-based segmentation (8 bars = typical phrase) combined with
    novelty detection to snap to structural boundaries.
    
    Target: 8-30 second phrases for DJ-style navigation.
    """
    duration = len(y) / sr
    
    # === Bar-based phrase boundaries ===
    # Use downbeats (every 4 beats) and group into 8-bar phrases
    # 8 bars at 130 BPM = ~14.8 seconds (good phrase length)
    
    if len(beat_times) >= 4:
        downbeats = beat_times[::4]  # Every 4th beat = bar start
    else:
        downbeats = beat_times if len(beat_times) > 0 else np.array([0.0])
    
    # Choose phrase grouping based on tempo
    # Faster tempo = more bars per phrase to maintain ~10-20s segments
    if len(beat_times) >= 8:
        avg_beat_interval = np.mean(np.diff(beat_times))
        tempo_estimate = 60.0 / avg_beat_interval if avg_beat_interval > 0 else 120.0
        
        if tempo_estimate > 150:
            bars_per_phrase = 16  # Fast tempo: 16 bars
        elif tempo_estimate > 120:
            bars_per_phrase = 8   # Medium tempo: 8 bars
        else:
            bars_per_phrase = 8   # Slow tempo: 8 bars (still want variety)
    else:
        bars_per_phrase = 8
    
    # Create phrase boundaries at every N bars
    phrase_downbeats = downbeats[::bars_per_phrase]
    
    # === Novelty detection for refinement ===
    # Use spectral flux to detect structural changes
    onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=HOP_LENGTH)
    
    # Smooth for structure detection
    struct_window = int(2.0 * sr / HOP_LENGTH)  # 2 second window
    if struct_window > 1 and len(onset_env) > struct_window:
        onset_smooth = np.convolve(onset_env, np.ones(struct_window)/struct_window, mode='same')
    else:
        onset_smooth = onset_env
    
    # Find peaks in novelty (major structural transitions)
    novelty_peaks = []
    peak_threshold = np.mean(onset_smooth) + 1.5 * np.std(onset_smooth)
    min_peak_distance = int(4.0 * sr / HOP_LENGTH)  # At least 4 seconds apart
    
    last_peak = -min_peak_distance
    for i in range(min_peak_distance, len(onset_smooth) - min_peak_distance):
        if onset_smooth[i] > peak_threshold:
            if i - last_peak >= min_peak_distance:
                # Check if local maximum
                window = onset_smooth[max(0, i-10):min(len(onset_smooth), i+10)]
                if len(window) > 0 and onset_smooth[i] >= np.max(window) * 0.95:
                    novelty_peaks.append(librosa.frames_to_time(i, sr=sr, hop_length=HOP_LENGTH))
                    last_peak = i
    
    # === Merge bar boundaries with novelty peaks ===
    all_boundaries = set(phrase_downbeats.tolist())
    
    # Add novelty peaks that aren't too close to existing boundaries
    for peak_time in novelty_peaks:
        if all(abs(peak_time - b) > 2.0 for b in all_boundaries):  # At least 2s apart
            # Snap to nearest downbeat if close
            if len(downbeats) > 0:
                nearest_idx = np.argmin(np.abs(downbeats - peak_time))
                nearest_downbeat = downbeats[nearest_idx]
                if abs(nearest_downbeat - peak_time) < 1.0:
                    all_boundaries.add(nearest_downbeat)
                else:
                    all_boundaries.add(peak_time)
            else:
                all_boundaries.add(peak_time)
    
    # Sort and ensure start/end
    phrase_times = sorted(all_boundaries)
    
    # Add start if needed
    if len(phrase_times) == 0 or phrase_times[0] > 2.0:
        phrase_times = [0.0] + phrase_times
    
    # Add end if needed
    if phrase_times[-1] < duration - 2.0:
        phrase_times.append(duration)
    
    # === Post-process: split any segments > 30s ===
    final_phrase_times = []
    for i in range(len(phrase_times)):
        final_phrase_times.append(phrase_times[i])
        
        if i < len(phrase_times) - 1:
            gap = phrase_times[i + 1] - phrase_times[i]
            if gap > 30.0:
                # Insert intermediate boundaries
                num_splits = int(gap / 15.0)  # Target ~15s segments
                for j in range(1, num_splits):
                    split_time = phrase_times[i] + gap * j / num_splits
                    # Snap to nearest downbeat
                    if len(downbeats) > 0:
                        nearest_idx = np.argmin(np.abs(downbeats - split_time))
                        if abs(downbeats[nearest_idx] - split_time) < 2.0:
                            split_time = downbeats[nearest_idx]
                    final_phrase_times.append(split_time)
    
    phrase_times = sorted(set(final_phrase_times))
    
    # === Segment Classification ===
    segments = []
    
    for i in range(len(phrase_times) - 1):
        start = phrase_times[i]
        end = phrase_times[i + 1]
        
        # Get energy for this segment
        start_frame = int(start * sr / HOP_LENGTH)
        end_frame = int(end * sr / HOP_LENGTH)
        segment_rms = rms[start_frame:end_frame] if end_frame <= len(rms) else rms[start_frame:]
        
        if len(segment_rms) > 0:
            avg_energy = float(np.mean(segment_rms))
            energy_variance = float(np.var(segment_rms))
        else:
            avg_energy = 0.5
            energy_variance = 0.0
        
        # Classify segment type based on energy and position
        segment_type = classify_segment(
            start=start,
            end=end,
            duration=duration,
            energy=avg_energy,
            energy_variance=energy_variance,
            total_energy_mean=float(np.mean(rms))
        )
        
        segments.append({
            "start": start,
            "end": end,
            "type": segment_type,
            "energy": avg_energy,
            "energyVariance": energy_variance,
        })
    
    return phrase_times, segments


def classify_segment(start: float, end: float, duration: float, 
                     energy: float, energy_variance: float,
                     total_energy_mean: float) -> str:
    """
    Classify a segment as intro, verse, chorus, breakdown, drop, or outro.
    
    This is a heuristic approach based on:
    - Position in track
    - Energy level relative to track average
    - Energy variance (stable vs dynamic)
    """
    position_ratio = start / duration
    energy_ratio = energy / (total_energy_mean + 1e-6)
    segment_length = end - start
    
    # Intro: First 10% of track, often lower energy
    if position_ratio < 0.1:
        return "intro"
    
    # Outro: Last 10% of track
    if position_ratio > 0.9:
        return "outro"
    
    # Breakdown: Low energy, low variance (quiet section)
    if energy_ratio < 0.6 and energy_variance < 0.01:
        return "breakdown"
    
    # Drop: High energy, often after breakdown
    if energy_ratio > 1.3:
        return "drop"
    
    # Chorus: Higher than average energy, moderate variance
    if energy_ratio > 1.0:
        return "chorus"
    
    # Default: verse
    return "verse"


def analyze_directory(input_dir: Path, output_file: Path, 
                      extensions: set = {'.mp3', '.wav', '.flac', '.m4a', '.aiff'},
                      verbose: bool = False) -> dict:
    """
    Analyze all audio files in a directory.
    """
    audio_files = []
    for ext in extensions:
        audio_files.extend(input_dir.rglob(f'*{ext}'))
    
    print(f"Found {len(audio_files)} audio files in {input_dir}")
    
    results = {
        "version": "2.0",  # Version with beat/phrase analysis
        "collectionPath": str(input_dir),
        "analyzedAt": None,  # Will be set by caller
        "tracks": []
    }
    
    for i, audio_path in enumerate(audio_files):
        print(f"[{i+1}/{len(audio_files)}] Analyzing: {audio_path.name}")
        
        track_analysis = analyze_track(audio_path, verbose=verbose)
        if track_analysis:
            results["tracks"].append(track_analysis)
    
    # Save results
    print(f"\nSaving analysis to {output_file}")
    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2)
    
    print(f"Done! Analyzed {len(results['tracks'])} tracks")
    return results


def update_existing_analysis(existing_file: Path, verbose: bool = False) -> dict:
    """
    Update an existing analysis.json with beat/phrase data.
    
    Reads the existing file, adds beat/phrase analysis for each track,
    and saves the updated version.
    """
    print(f"Loading existing analysis from {existing_file}")
    
    with open(existing_file, 'r') as f:
        analysis = json.load(f)
    
    # Check if already has beat data
    if analysis.get("version") == "2.0":
        print("Analysis already has beat/phrase data (version 2.0)")
        return analysis
    
    collection_path = Path(analysis.get("collectionPath", ""))
    audio_files = analysis.get("audioFiles", [])
    
    print(f"Updating {len(audio_files)} tracks with beat/phrase analysis")
    
    updated_files = []
    for i, audio_info in enumerate(audio_files):
        path = audio_info.get("path", "")
        print(f"[{i+1}/{len(audio_files)}] {Path(path).name}")
        
        if not os.path.exists(path):
            print(f"  Warning: File not found, skipping")
            updated_files.append(audio_info)
            continue
        
        track_analysis = analyze_track(Path(path), verbose=verbose)
        
        if track_analysis:
            # Merge new analysis with existing
            if "features" not in audio_info:
                audio_info["features"] = {}
            
            audio_info["features"]["tempo"] = track_analysis["tempo"]
            audio_info["features"]["key"] = track_analysis["key"]
            audio_info["features"]["spectralCentroid"] = track_analysis["spectralCentroid"]
            audio_info["beats"] = track_analysis["beats"]
            audio_info["downbeats"] = track_analysis["downbeats"]
            audio_info["onsets"] = track_analysis["onsets"]
            audio_info["phrases"] = track_analysis["phrases"]
            audio_info["segments"] = track_analysis["segments"]
        
        updated_files.append(audio_info)
    
    analysis["audioFiles"] = updated_files
    analysis["version"] = "2.0"
    
    # Save updated analysis
    backup_file = existing_file.with_suffix('.json.bak')
    print(f"Backing up original to {backup_file}")
    os.rename(existing_file, backup_file)
    
    print(f"Saving updated analysis to {existing_file}")
    with open(existing_file, 'w') as f:
        json.dump(analysis, f, indent=2)
    
    return analysis


def main():
    parser = argparse.ArgumentParser(
        description='Analyze music library for beats, phrases, and structure using librosa'
    )
    parser.add_argument('input', type=str,
                        help='Input directory or existing analysis.json file')
    parser.add_argument('-o', '--output', type=str, default=None,
                        help='Output JSON file (default: input_dir/librosa_analysis.json)')
    parser.add_argument('-u', '--update', action='store_true',
                        help='Update existing analysis.json with beat/phrase data')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Verbose output')
    
    args = parser.parse_args()
    
    input_path = Path(args.input)
    
    if args.update or input_path.suffix == '.json':
        # Update existing analysis
        if not input_path.exists():
            print(f"Error: File not found: {input_path}")
            sys.exit(1)
        update_existing_analysis(input_path, verbose=args.verbose)
    elif input_path.is_file():
        # Single file analysis
        print(f"Analyzing single file: {input_path}")
        result = analyze_track(input_path, verbose=args.verbose)
        if result:
            output_file = Path(args.output) if args.output else Path('/tmp/single_track_analysis.json')
            with open(output_file, 'w') as f:
                json.dump(result, f, indent=2)
            print(f"\nSaved to {output_file}")
            
            # Print summary
            print(f"\n=== Analysis Summary ===")
            print(f"Tempo: {result['tempo']:.1f} BPM")
            print(f"Key: {result['key']}")
            print(f"Beats: {len(result['beats'])}")
            print(f"Phrases: {len(result['phrases'])} boundaries")
            print(f"Segments: {len(result['segments'])}")
            for seg in result['segments'][:5]:
                print(f"  {seg['start']:.1f}s - {seg['end']:.1f}s: {seg['type']} (energy: {seg['energy']:.2f})")
        else:
            print("Analysis failed")
            sys.exit(1)
    else:
        # Analyze directory
        if not input_path.is_dir():
            print(f"Error: Not a directory: {input_path}")
            sys.exit(1)
        
        output_file = Path(args.output) if args.output else input_path / 'librosa_analysis.json'
        analyze_directory(input_path, output_file, verbose=args.verbose)


if __name__ == '__main__':
    main()

