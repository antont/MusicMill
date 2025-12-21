#!/bin/bash
#
# Train RAVE model on MusicMill analyzed collection
#
# This script:
# 1. Prepares training data from analysis results
# 2. Runs RAVE preprocessing
# 3. Trains the model
#
# Usage:
#   ./train_collection.sh [config]
#
# Configs: v2 (default), v2_small (faster training), rave_v1
#

set -e

# Configuration
VENV_DIR="$HOME/Documents/MusicMill/RAVE/venv"
TRAINING_DATA="$HOME/Documents/MusicMill/RAVE/training_data"
PREPROCESSED="$HOME/Documents/MusicMill/RAVE/preprocessed"
MODELS_DIR="$HOME/Documents/MusicMill/RAVE/models"
CONFIG="${1:-v2}"
MODEL_NAME="musicmill_${CONFIG}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================================"
echo "MusicMill RAVE Training Pipeline"
echo "============================================================"
echo "Config: $CONFIG"
echo "Model name: $MODEL_NAME"
echo ""

# Check for venv
if [ ! -d "$VENV_DIR" ]; then
    echo "Error: RAVE venv not found at $VENV_DIR"
    echo "Run setup_rave.sh first to set up the environment."
    exit 1
fi

# Activate venv
echo "Activating RAVE environment..."
source "$VENV_DIR/bin/activate"

# Check rave is installed
if ! command -v rave &> /dev/null; then
    echo "Error: 'rave' command not found. Check RAVE installation."
    exit 1
fi

echo ""
echo "Step 1: Prepare training data"
echo "------------------------------------------------------------"

# Prepare training data from analysis
python "$SCRIPT_DIR/prepare_training_data.py" --output-dir "$TRAINING_DATA" --organize-by-style

# Check we have training data
WAV_COUNT=$(find "$TRAINING_DATA" -name "*.wav" 2>/dev/null | wc -l)
if [ "$WAV_COUNT" -eq 0 ]; then
    echo "Error: No WAV files found in $TRAINING_DATA"
    echo "Make sure MusicMill analysis has been run first."
    exit 1
fi
echo "Found $WAV_COUNT WAV files for training."

echo ""
echo "Step 2: RAVE preprocessing"
echo "------------------------------------------------------------"

# Create preprocessed directory
mkdir -p "$PREPROCESSED"

# Run preprocessing with lazy mode
echo "Running RAVE preprocessing (lazy mode)..."
rave preprocess \
    --input_path "$TRAINING_DATA" \
    --output_path "$PREPROCESSED" \
    --lazy

echo ""
echo "Step 3: Train RAVE model"
echo "------------------------------------------------------------"

# Create models directory
mkdir -p "$MODELS_DIR"

# Show training info
echo "Starting training with config: $CONFIG"
echo "This will take 1-2+ hours depending on data size."
echo ""
echo "Monitor training with:"
echo "  tensorboard --logdir $MODELS_DIR"
echo ""
echo "Training will save checkpoints to: $MODELS_DIR/$MODEL_NAME"
echo ""

# Run training
# Note: Use GPU if available, checkpoints every 10k steps
rave train \
    --config "$CONFIG" \
    --db_path "$PREPROCESSED" \
    --out_path "$MODELS_DIR" \
    --name "$MODEL_NAME" \
    --val_every 5000 \
    --ckpt_every 10000

echo ""
echo "============================================================"
echo "Training complete!"
echo "============================================================"
echo ""
echo "Model saved to: $MODELS_DIR/$MODEL_NAME"
echo ""
echo "To export for inference:"
echo "  rave export --run $MODELS_DIR/$MODEL_NAME --streaming"
echo ""
echo "The exported .ts file can be used with rave_server.py"

