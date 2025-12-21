#!/usr/bin/env python3
"""
Train RAVE model on MusicMill audio collection.
RAVE (Realtime Audio Variational autoEncoder) by IRCAM.
"""

import os
import sys
import subprocess
from pathlib import Path
import argparse

# Paths
TRAINING_DATA = Path.home() / ".musicmill" / "rave_training_data"
PREPROCESSED = Path.home() / ".musicmill" / "rave_preprocessed"
MODELS_DIR = Path.home() / ".musicmill" / "rave_models"


def check_rave_installed():
    """Check if RAVE is installed."""
    try:
        result = subprocess.run(
            ['rave', '--help'],
            capture_output=True,
            text=True
        )
        return result.returncode == 0
    except FileNotFoundError:
        return False


def preprocess(input_dir, output_dir):
    """Preprocess audio for RAVE training."""
    print(f"\n[1] Preprocessing audio...")
    print(f"    Input: {input_dir}")
    print(f"    Output: {output_dir}")
    
    output_dir.mkdir(parents=True, exist_ok=True)
    
    cmd = [
        'rave', 'preprocess',
        '--input_path', str(input_dir),
        '--output_path', str(output_dir),
        '--channels', '1'  # Mono for efficiency
    ]
    
    result = subprocess.run(cmd)
    
    if result.returncode != 0:
        print("❌ Preprocessing failed")
        sys.exit(1)
    
    print("✓ Preprocessing complete")


def train(db_path, name, config='v2', epochs=None):
    """Train RAVE model."""
    print(f"\n[2] Training RAVE model '{name}'...")
    print(f"    Config: {config}")
    print(f"    Data: {db_path}")
    
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    
    cmd = [
        'rave', 'train',
        '--config', config,
        '--db_path', str(db_path),
        '--name', name,
        '--out_path', str(MODELS_DIR)
    ]
    
    if epochs:
        cmd.extend(['--epochs', str(epochs)])
    
    print(f"\n    Running: {' '.join(cmd)}")
    print("\n    This will take a while (1-2 hours for small datasets)...")
    print("    Press Ctrl+C to stop training early (model will be saved).\n")
    
    try:
        result = subprocess.run(cmd)
    except KeyboardInterrupt:
        print("\n\n⚠️  Training interrupted. Partial model may be saved.")
        return False
    
    if result.returncode != 0:
        print("❌ Training failed")
        return False
    
    print("✓ Training complete")
    return True


def export_model(name):
    """Export trained model for inference."""
    print(f"\n[3] Exporting model '{name}'...")
    
    model_path = MODELS_DIR / name
    if not model_path.exists():
        # Try with version suffix
        candidates = list(MODELS_DIR.glob(f"{name}*"))
        if candidates:
            model_path = candidates[0]
        else:
            print(f"❌ Model not found: {name}")
            print(f"   Available models: {list(MODELS_DIR.iterdir())}")
            return None
    
    export_path = model_path / "exported"
    export_path.mkdir(exist_ok=True)
    
    cmd = [
        'rave', 'export',
        '--run', str(model_path),
        '--output', str(export_path / 'model.ts')
    ]
    
    result = subprocess.run(cmd)
    
    if result.returncode != 0:
        print("❌ Export failed")
        return None
    
    print(f"✓ Model exported to: {export_path}")
    return export_path / 'model.ts'


def main():
    parser = argparse.ArgumentParser(description='Train RAVE model for MusicMill')
    parser.add_argument('--name', default='musicmill_rave', help='Model name')
    parser.add_argument('--config', default='v2', 
                       choices=['v1', 'v2', 'discrete', 'onnx'],
                       help='RAVE configuration')
    parser.add_argument('--epochs', type=int, help='Number of training epochs')
    parser.add_argument('--skip-preprocess', action='store_true',
                       help='Skip preprocessing step')
    parser.add_argument('--export-only', action='store_true',
                       help='Only export existing model')
    args = parser.parse_args()
    
    print("🎵 RAVE Training for MusicMill")
    print("=" * 50)
    
    # Check RAVE installation
    if not check_rave_installed():
        print("❌ RAVE not installed. Run: ./scripts/setup_rave.sh")
        sys.exit(1)
    
    # Check training data
    if not args.export_only and not TRAINING_DATA.exists():
        print(f"❌ Training data not found: {TRAINING_DATA}")
        print("   Run: python scripts/prepare_training_data.py")
        sys.exit(1)
    
    if args.export_only:
        export_model(args.name)
        return
    
    # Preprocess
    if not args.skip_preprocess:
        preprocess(TRAINING_DATA, PREPROCESSED)
    
    # Train
    success = train(PREPROCESSED, args.name, args.config, args.epochs)
    
    if success:
        # Export
        exported = export_model(args.name)
        
        if exported:
            print("\n" + "=" * 50)
            print("✓ RAVE model ready!")
            print(f"  Model: {exported}")
            print("\nNext step: python scripts/export_coreml.py")


if __name__ == "__main__":
    main()

