#!/bin/bash

# Script to check analysis results in Documents directory

ANALYSIS_DIR="$HOME/Documents/MusicMill/Analysis"

echo "Checking for analysis results..."
echo "=================================="
echo ""

if [ ! -d "$ANALYSIS_DIR" ]; then
    echo "✗ Analysis directory not found: $ANALYSIS_DIR"
    echo ""
    echo "Run the analysis from the MusicMill app first:"
    echo "  1. Open MusicMill app"
    echo "  2. Go to Training tab"
    echo "  3. Select your music collection directory"
    echo "  4. Click 'Analyze Collection'"
    exit 1
fi

echo "✓ Analysis directory exists: $ANALYSIS_DIR"
echo ""

# List all collections
collections=$(find "$ANALYSIS_DIR" -mindepth 1 -maxdepth 1 -type d)

if [ -z "$collections" ]; then
    echo "✗ No collections found in analysis directory"
    exit 1
fi

for collection_dir in $collections; do
    collection_name=$(basename "$collection_dir")
    echo "Collection: $collection_name"
    echo "  Path: $collection_dir"
    
    # Check for analysis.json
    analysis_json="$collection_dir/analysis.json"
    if [ -f "$analysis_json" ]; then
        echo "  ✓ analysis.json exists"
        
        # Try to extract some info using Python or jq if available
        if command -v python3 &> /dev/null; then
            echo ""
            echo "  Analysis Details:"
            python3 << PYTHON
import json
import sys
from datetime import datetime

try:
    with open("$analysis_json", 'r') as f:
        data = json.load(f)
    
    print(f"    • Collection Path: {data.get('collectionPath', 'N/A')}")
    if 'analyzedDate' in data:
        date_str = data['analyzedDate']
        print(f"    • Analyzed Date: {date_str}")
    print(f"    • Total Files: {data.get('totalFiles', 0)}")
    print(f"    • Total Samples: {data.get('totalSamples', 0)}")
    
    if 'organizedStyles' in data:
        styles = data['organizedStyles']
        print(f"    • Styles ({len(styles)}): {', '.join(styles.keys())}")
        for style, files in styles.items():
            print(f"      - {style}: {len(files)} files")
    
    if 'audioFiles' in data:
        print(f"    • Audio Files: {len(data['audioFiles'])}")
        if len(data['audioFiles']) > 0:
            first_file = data['audioFiles'][0]
            print(f"      Example: {first_file.get('path', 'N/A').split('/')[-1]}")
            if 'features' in first_file and first_file['features']:
                feat = first_file['features']
                print(f"        Tempo: {feat.get('tempo', 'N/A')} BPM")
                print(f"        Key: {feat.get('key', 'N/A')}")
                print(f"        Energy: {feat.get('energy', 'N/A')}")
except Exception as e:
    print(f"    Error reading JSON: {e}")
PYTHON
        fi
    else
        echo "  ✗ analysis.json not found"
    fi
    
    # Check for segments
    segments_dir="$collection_dir/Segments"
    if [ -d "$segments_dir" ]; then
        segment_count=$(find "$segments_dir" -type f -name "*.m4a" | wc -l | tr -d ' ')
        if [ "$segment_count" -gt 0 ]; then
            total_size=$(du -sh "$segments_dir" 2>/dev/null | cut -f1)
            echo ""
            echo "  ✓ Segments directory exists"
            echo "    • Segment files: $segment_count"
            echo "    • Total size: $total_size"
        else
            echo "  ⚠ Segments directory exists but is empty"
        fi
    else
        echo "  ⚠ No segments directory found"
    fi
    
    echo ""
done

echo "=================================="
echo "Analysis check complete!"

