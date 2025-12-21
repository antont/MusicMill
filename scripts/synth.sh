#!/bin/bash
# Quick synthesis test script
# Rebuilds if needed, runs synthesis, plays output

cd "$(dirname "$0")/.."

echo "🔨 Building and running synthesis test..."

xcodebuild test \
  -project MusicMill.xcodeproj \
  -scheme MusicMill \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ./DerivedData \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "(Compiling|Linking|passed|failed|error:)"

echo ""
echo "📊 Quality Report:"
echo "=================="
REPORT=$(find /private/var/folders -name "musicmill_quality_report.txt" 2>/dev/null | head -1)
if [ -n "$REPORT" ]; then
  cat "$REPORT" | grep -A 20 "QUALITY SCORES"
else
  echo "No report found"
fi

echo ""
echo "🔊 Playing output..."
OUTPUT=~/Documents/MusicMill/granular_output.wav
if [ -f "$OUTPUT" ]; then
  afplay "$OUTPUT"
else
  echo "No output file found at $OUTPUT"
fi

