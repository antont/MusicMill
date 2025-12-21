#!/bin/bash
# Setup RAVE (Realtime Audio Variational autoEncoder) environment
# RAVE by IRCAM - designed for real-time audio generation

set -e

echo "🎵 Setting up RAVE for MusicMill"
echo "================================"

# Check Python version
PYTHON_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2 | cut -d'.' -f1,2)
echo "Python version: $PYTHON_VERSION"

# Create virtual environment
VENV_PATH="$HOME/.musicmill/rave_env"
if [ ! -d "$VENV_PATH" ]; then
    echo "Creating virtual environment at $VENV_PATH..."
    python3 -m venv "$VENV_PATH"
fi

# Activate virtual environment
source "$VENV_PATH/bin/activate"

# Upgrade pip
pip install --upgrade pip

# Install RAVE
echo "Installing RAVE (acids-rave)..."
pip install acids-rave

# Install additional dependencies for export
echo "Installing Core ML tools..."
pip install coremltools torch

echo ""
echo "✓ RAVE environment setup complete!"
echo ""
echo "To activate the environment:"
echo "  source $VENV_PATH/bin/activate"
echo ""
echo "Next steps:"
echo "  1. Prepare training data: ./scripts/prepare_training_data.py"
echo "  2. Train RAVE model: ./scripts/train_rave.py"
echo "  3. Export to Core ML: ./scripts/export_coreml.py"

