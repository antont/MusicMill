#!/usr/bin/env python3
"""
Build Phrase Graph - HyperMusic System

This script takes librosa analysis output and builds a navigable phrase graph
with weighted links between phrases based on musical compatibility.

Link compatibility scoring:
- Tempo: Same BPM (+/-5%), half-time, double-time
- Key: Same key, relative major/minor, circle of fifths neighbors
- Energy: Similar energy, building, dropping
- Spectral similarity: Timbral match via spectral centroid
- Beat alignment: Similar beat grid patterns

Output: phrase_graph.json compatible with MusicMill's PhraseDatabase
"""

import argparse
import json
import os
import subprocess
import sys
import uuid
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional, Tuple
import math

# ============================================================================
# CONFIGURATION
# ============================================================================

# Link thresholds
MIN_LINK_WEIGHT = 0.3  # Minimum compatibility to create a link
MAX_LINKS_PER_PHRASE = 20  # Maximum outgoing links per phrase
SEGMENT_DURATION_MIN = 4.0  # Minimum segment duration in seconds
SEGMENT_DURATION_MAX = 60.0  # Maximum segment duration

# Tempo compatibility
TEMPO_EXACT_THRESHOLD = 0.05  # 5% tolerance for "same tempo"
TEMPO_HALF_DOUBLE_THRESHOLD = 0.1  # 10% tolerance for half/double time

# Key compatibility (circle of fifths)
KEY_CIRCLE = ['C', 'G', 'D', 'A', 'E', 'B', 'F#', 'Db', 'Ab', 'Eb', 'Bb', 'F']
KEY_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']

# ============================================================================
# DATA CLASSES
# ============================================================================

@dataclass
class PhraseLink:
    targetId: str
    weight: float
    isOriginalSequence: bool
    suggestedTransition: str
    tempoScore: float
    keyScore: float
    energyScore: float
    spectralScore: float


@dataclass
class PhraseNode:
    id: str
    sourceTrack: str
    sourceTrackName: str
    trackIndex: int
    audioFile: str
    tempo: float
    key: Optional[str]
    energy: float
    spectralCentroid: float
    segmentType: str
    duration: float
    beats: List[float]
    downbeats: List[float]
    links: List[PhraseLink]

# ============================================================================
# KEY COMPATIBILITY
# ============================================================================

def normalize_key(key: Optional[str]) -> Optional[str]:
    """Normalize key name to standard format."""
    if not key:
        return None
    
    # Handle enharmonic equivalents
    key = key.strip().upper()
    equivalents = {
        'DB': 'C#', 'EB': 'D#', 'GB': 'F#', 'AB': 'G#', 'BB': 'A#'
    }
    
    for old, new in equivalents.items():
        if key == old:
            return new
    
    if key in KEY_NAMES:
        return key
    
    return key


def key_distance(key1: Optional[str], key2: Optional[str]) -> int:
    """
    Get distance between keys on circle of fifths.
    Returns 0-6 (0 = same key, 6 = tritone apart)
    """
    if not key1 or not key2:
        return 3  # Unknown = moderate distance
    
    k1 = normalize_key(key1)
    k2 = normalize_key(key2)
    
    if k1 == k2:
        return 0
    
    # Find positions on circle of fifths
    try:
        # Try direct lookup
        i1 = KEY_CIRCLE.index(k1) if k1 in KEY_CIRCLE else KEY_NAMES.index(k1)
        i2 = KEY_CIRCLE.index(k2) if k2 in KEY_CIRCLE else KEY_NAMES.index(k2)
    except ValueError:
        return 3  # Unknown key
    
    # Distance on circle (0-6, wrapping around)
    dist = abs(i1 - i2)
    return min(dist, 12 - dist)


def compute_key_score(key1: Optional[str], key2: Optional[str]) -> float:
    """
    Compute key compatibility score (0-1).
    
    1.0 = Same key
    0.9 = Perfect fifth apart (e.g., C to G)
    0.8 = Two steps on circle (e.g., C to D)
    0.6 = Three steps
    0.4 = Four steps
    0.2 = Five steps
    0.1 = Tritone (6 steps)
    """
    dist = key_distance(key1, key2)
    scores = [1.0, 0.9, 0.8, 0.6, 0.4, 0.2, 0.1]
    return scores[min(dist, 6)]

# ============================================================================
# TEMPO COMPATIBILITY
# ============================================================================

def compute_tempo_score(tempo1: float, tempo2: float) -> float:
    """
    Compute tempo compatibility score (0-1).
    
    Considers exact match, half-time, and double-time relationships.
    """
    if tempo1 <= 0 or tempo2 <= 0:
        return 0.5  # Unknown
    
    # Exact match (within 5%)
    ratio = tempo1 / tempo2
    if abs(ratio - 1.0) <= TEMPO_EXACT_THRESHOLD:
        return 1.0
    
    # Half-time (tempo2 is ~half of tempo1)
    if abs(ratio - 2.0) <= TEMPO_HALF_DOUBLE_THRESHOLD:
        return 0.85
    
    # Double-time (tempo2 is ~double of tempo1)
    if abs(ratio - 0.5) <= TEMPO_HALF_DOUBLE_THRESHOLD:
        return 0.85
    
    # Close tempos (within 10%)
    if abs(ratio - 1.0) <= 0.10:
        return 0.8
    
    # Moderate difference (within 20%)
    if abs(ratio - 1.0) <= 0.20:
        return 0.5
    
    # Large difference
    return 0.2

# ============================================================================
# ENERGY COMPATIBILITY
# ============================================================================

def compute_energy_score(energy1: float, energy2: float) -> float:
    """
    Compute energy flow compatibility (0-1).
    
    Good transitions:
    - Similar energy (0.8)
    - Building (increasing by 0.1-0.3: 0.9)
    - Dropping (decreasing: 0.7)
    
    Bad transitions:
    - Large jump (> 0.4 difference: 0.3)
    """
    diff = energy2 - energy1
    
    # Similar energy (within 0.1)
    if abs(diff) <= 0.1:
        return 0.85
    
    # Building energy (gradual increase)
    if 0.1 < diff <= 0.3:
        return 0.9  # Energy build is exciting
    
    # Large build (too abrupt)
    if diff > 0.3:
        return 0.5
    
    # Dropping energy (gradual decrease)
    if -0.3 <= diff < -0.1:
        return 0.75
    
    # Large drop (too abrupt, but can work)
    if diff < -0.3:
        return 0.4
    
    return 0.6

# ============================================================================
# SPECTRAL COMPATIBILITY
# ============================================================================

def compute_spectral_score(centroid1: float, centroid2: float) -> float:
    """
    Compute spectral similarity score (0-1).
    
    Based on spectral centroid (brightness) similarity.
    Similar brightness = smoother transition.
    """
    if centroid1 <= 0 or centroid2 <= 0:
        return 0.5
    
    # Ratio of centroids
    ratio = max(centroid1, centroid2) / min(centroid1, centroid2)
    
    # Very similar (ratio < 1.2)
    if ratio < 1.2:
        return 1.0
    
    # Similar (ratio < 1.5)
    if ratio < 1.5:
        return 0.8
    
    # Moderate difference
    if ratio < 2.0:
        return 0.6
    
    # Large difference
    return 0.4

# ============================================================================
# OVERALL COMPATIBILITY
# ============================================================================

def compute_link_weight(phrase1: PhraseNode, phrase2: PhraseNode) -> Tuple[float, Dict]:
    """
    Compute overall link weight and component scores.
    
    Returns (weight, scores_dict)
    """
    tempo_score = compute_tempo_score(phrase1.tempo, phrase2.tempo)
    key_score = compute_key_score(phrase1.key, phrase2.key)
    energy_score = compute_energy_score(phrase1.energy, phrase2.energy)
    spectral_score = compute_spectral_score(phrase1.spectralCentroid, phrase2.spectralCentroid)
    
    # Weighted average (tempo most important for DJing)
    weight = (
        tempo_score * 0.35 +
        key_score * 0.25 +
        energy_score * 0.25 +
        spectral_score * 0.15
    )
    
    scores = {
        'tempo': tempo_score,
        'key': key_score,
        'energy': energy_score,
        'spectral': spectral_score
    }
    
    return weight, scores


def suggest_transition(weight: float, energy_diff: float) -> str:
    """Suggest best transition type based on compatibility."""
    if weight > 0.8:
        return "crossfade"  # Clean transition
    elif weight > 0.6:
        return "eqSwap"  # Use EQ for smoother blend
    elif weight > 0.4 and abs(energy_diff) > 0.3:
        return "filter"  # Use filter sweep for energy changes
    else:
        return "cut"  # Hard cut on beat for incompatible phrases

# ============================================================================
# PHRASE EXTRACTION
# ============================================================================

def extract_phrases_from_analysis(analysis: dict, output_dir: Path) -> List[PhraseNode]:
    """
    Extract phrase nodes from librosa analysis.
    
    Uses segment boundaries from analysis, extracts audio segments.
    """
    phrases = []
    tracks = analysis.get("tracks", [])
    
    print(f"Extracting phrases from {len(tracks)} tracks...")
    
    for track in tracks:
        track_path = track.get("path", "")
        track_name = Path(track_path).name
        tempo = track.get("tempo", 120.0)
        key = track.get("key")
        spectral_centroid = track.get("spectralCentroid", 1000.0)
        segments = track.get("segments", [])
        beats = track.get("beats", [])
        downbeats = track.get("downbeats", [])
        
        if not segments:
            print(f"  Skipping {track_name}: no segments")
            continue
        
        print(f"  Processing {track_name}: {len(segments)} segments")
        
        for idx, segment in enumerate(segments):
            start = segment.get("start", 0)
            end = segment.get("end", 0)
            duration = end - start
            
            # Filter by duration
            if duration < SEGMENT_DURATION_MIN or duration > SEGMENT_DURATION_MAX:
                continue
            
            # Generate unique ID
            phrase_id = str(uuid.uuid4())
            
            # Create audio filename
            safe_name = "".join(c if c.isalnum() else "_" for c in track_name)[:30]
            audio_filename = f"{safe_name}_seg{idx}.wav"
            audio_path = output_dir / audio_filename
            
            # Extract segment beats (relative to segment start)
            seg_beats = [b - start for b in beats if start <= b < end]
            seg_downbeats = [b - start for b in downbeats if start <= b < end]
            
            phrase = PhraseNode(
                id=phrase_id,
                sourceTrack=track_path,
                sourceTrackName=track_name,
                trackIndex=idx,
                audioFile=str(audio_path),
                tempo=tempo,
                key=key,
                energy=segment.get("energy", 0.5),
                spectralCentroid=spectral_centroid,
                segmentType=segment.get("type", "verse"),
                duration=duration,
                beats=seg_beats,
                downbeats=seg_downbeats,
                links=[]
            )
            
            phrases.append(phrase)
    
    print(f"Extracted {len(phrases)} phrases")
    return phrases


def extract_audio_segments(phrases: List[PhraseNode], analysis: dict, output_dir: Path):
    """
    Extract audio segments using ffmpeg.
    """
    print(f"\nExtracting audio segments to {output_dir}...")
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Group phrases by track
    by_track = {}
    for phrase in phrases:
        if phrase.sourceTrack not in by_track:
            by_track[phrase.sourceTrack] = []
        by_track[phrase.sourceTrack].append(phrase)
    
    # Find segment info from analysis
    track_segments = {}
    for track in analysis.get("tracks", []):
        track_segments[track["path"]] = track.get("segments", [])
    
    extracted = 0
    for track_path, track_phrases in by_track.items():
        if not os.path.exists(track_path):
            print(f"  Warning: Track not found: {track_path}")
            continue
        
        segments = track_segments.get(track_path, [])
        
        for phrase in track_phrases:
            idx = phrase.trackIndex
            if idx >= len(segments):
                continue
            
            segment = segments[idx]
            start = segment.get("start", 0)
            end = segment.get("end", 0)
            duration = end - start
            
            output_file = Path(phrase.audioFile)
            
            if output_file.exists():
                extracted += 1
                continue
            
            # Extract with ffmpeg
            cmd = [
                'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
                '-i', track_path,
                '-ss', str(start),
                '-t', str(duration),
                '-ar', '44100',
                '-ac', '2',
                str(output_file)
            ]
            
            result = subprocess.run(cmd, capture_output=True)
            if result.returncode == 0:
                extracted += 1
            else:
                print(f"  Error extracting {output_file.name}")
    
    print(f"Extracted {extracted} audio segments")

# ============================================================================
# LINK COMPUTATION
# ============================================================================

def compute_all_links(phrases: List[PhraseNode]) -> List[PhraseNode]:
    """
    Compute compatibility links between all phrase pairs.
    
    This is O(n²) but with early termination for obvious mismatches.
    """
    print(f"\nComputing links between {len(phrases)} phrases...")
    
    # Index by track for original sequence links
    by_track = {}
    for phrase in phrases:
        if phrase.sourceTrack not in by_track:
            by_track[phrase.sourceTrack] = []
        by_track[phrase.sourceTrack].append(phrase)
    
    # Sort each track's phrases by index
    for track_phrases in by_track.values():
        track_phrases.sort(key=lambda p: p.trackIndex)
    
    total_links = 0
    
    for i, phrase1 in enumerate(phrases):
        if i % 50 == 0:
            print(f"  Processing phrase {i+1}/{len(phrases)}...")
        
        candidate_links = []
        
        for phrase2 in phrases:
            # Skip self-links
            if phrase1.id == phrase2.id:
                continue
            
            # Check if this is the original sequence (next phrase in same track)
            is_original_seq = False
            track_phrases = by_track.get(phrase1.sourceTrack, [])
            for j, tp in enumerate(track_phrases):
                if tp.id == phrase1.id and j + 1 < len(track_phrases):
                    if track_phrases[j + 1].id == phrase2.id:
                        is_original_seq = True
                    break
            
            # Compute compatibility
            weight, scores = compute_link_weight(phrase1, phrase2)
            
            # Always include original sequence, otherwise filter by weight
            if is_original_seq or weight >= MIN_LINK_WEIGHT:
                energy_diff = phrase2.energy - phrase1.energy
                transition = suggest_transition(weight, energy_diff)
                
                link = PhraseLink(
                    targetId=phrase2.id,
                    weight=weight,
                    isOriginalSequence=is_original_seq,
                    suggestedTransition=transition,
                    tempoScore=scores['tempo'],
                    keyScore=scores['key'],
                    energyScore=scores['energy'],
                    spectralScore=scores['spectral']
                )
                
                candidate_links.append(link)
        
        # Sort by weight (descending) and keep top N
        candidate_links.sort(key=lambda l: (-l.isOriginalSequence, -l.weight))
        phrase1.links = candidate_links[:MAX_LINKS_PER_PHRASE]
        total_links += len(phrase1.links)
    
    print(f"Created {total_links} links total")
    return phrases

# ============================================================================
# GRAPH OUTPUT
# ============================================================================

def save_phrase_graph(phrases: List[PhraseNode], collection_path: str, output_file: Path):
    """
    Save phrase graph to JSON.
    """
    # Convert dataclasses to dicts
    nodes = []
    for phrase in phrases:
        node_dict = {
            "id": phrase.id,
            "sourceTrack": phrase.sourceTrack,
            "sourceTrackName": phrase.sourceTrackName,
            "trackIndex": phrase.trackIndex,
            "audioFile": phrase.audioFile,
            "tempo": phrase.tempo,
            "key": phrase.key,
            "energy": phrase.energy,
            "spectralCentroid": phrase.spectralCentroid,
            "segmentType": phrase.segmentType,
            "duration": phrase.duration,
            "beats": phrase.beats,
            "downbeats": phrase.downbeats,
            "links": [
                {
                    "targetId": link.targetId,
                    "weight": link.weight,
                    "isOriginalSequence": link.isOriginalSequence,
                    "suggestedTransition": link.suggestedTransition,
                    "tempoScore": link.tempoScore,
                    "keyScore": link.keyScore,
                    "energyScore": link.energyScore,
                    "spectralScore": link.spectralScore
                }
                for link in phrase.links
            ]
        }
        nodes.append(node_dict)
    
    graph = {
        "version": "1.0",
        "createdAt": datetime.now().astimezone().isoformat(),  # Include timezone for ISO8601 compliance
        "collectionPath": collection_path,
        "nodes": nodes
    }
    
    output_file.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_file, 'w') as f:
        json.dump(graph, f, indent=2)
    
    print(f"\nSaved phrase graph to {output_file}")
    print(f"  Nodes: {len(nodes)}")
    print(f"  Total links: {sum(len(n['links']) for n in nodes)}")

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Build HyperMusic phrase graph from librosa analysis'
    )
    parser.add_argument('analysis_file', type=str,
                        help='Path to librosa_analysis.json')
    parser.add_argument('-o', '--output', type=str, default=None,
                        help='Output phrase_graph.json path')
    parser.add_argument('-s', '--segments-dir', type=str, default=None,
                        help='Directory for extracted audio segments')
    parser.add_argument('--skip-extraction', action='store_true',
                        help='Skip audio segment extraction')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Verbose output')
    
    args = parser.parse_args()
    
    # Load analysis
    analysis_path = Path(args.analysis_file)
    if not analysis_path.exists():
        print(f"Error: Analysis file not found: {analysis_path}")
        sys.exit(1)
    
    print(f"Loading analysis from {analysis_path}")
    with open(analysis_path) as f:
        analysis = json.load(f)
    
    collection_path = analysis.get("collectionPath", str(analysis_path.parent))
    
    # Set output paths
    docs_dir = Path.home() / "Documents/MusicMill"
    
    if args.output:
        output_file = Path(args.output)
    else:
        output_file = docs_dir / "PhraseGraph/phrase_graph.json"
    
    if args.segments_dir:
        segments_dir = Path(args.segments_dir)
    else:
        segments_dir = docs_dir / "PhraseGraph/Segments"
    
    # Extract phrases
    phrases = extract_phrases_from_analysis(analysis, segments_dir)
    
    if not phrases:
        print("No phrases extracted!")
        sys.exit(1)
    
    # Extract audio segments
    if not args.skip_extraction:
        extract_audio_segments(phrases, analysis, segments_dir)
    
    # Compute links
    phrases = compute_all_links(phrases)
    
    # Save graph
    save_phrase_graph(phrases, collection_path, output_file)
    
    # Print statistics
    print("\n=== Phrase Graph Statistics ===")
    print(f"Total phrases: {len(phrases)}")
    print(f"Tracks: {len(set(p.sourceTrack for p in phrases))}")
    
    # Segment type distribution
    types = {}
    for p in phrases:
        types[p.segmentType] = types.get(p.segmentType, 0) + 1
    print(f"Segment types: {types}")
    
    # Tempo distribution
    tempos = [p.tempo for p in phrases]
    if tempos:
        print(f"Tempo range: {min(tempos):.1f} - {max(tempos):.1f} BPM")
    
    # Link statistics
    link_counts = [len(p.links) for p in phrases]
    if link_counts:
        print(f"Links per phrase: {min(link_counts)} - {max(link_counts)} (avg: {sum(link_counts)/len(link_counts):.1f})")
    
    # Original sequence coverage
    orig_seq_count = sum(1 for p in phrases for l in p.links if l.isOriginalSequence)
    print(f"Original sequence links: {orig_seq_count}")


if __name__ == '__main__':
    main()

