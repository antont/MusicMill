#!/usr/bin/env python3
"""
Train RAVE model on MusicMill audio collection.
RAVE (Realtime Audio Variational autoEncoder) by IRCAM.

Reference: https://github.com/acids-ircam/RAVE

Available configurations:
- v2: Improved continuous model (recommended, 16GB GPU)
- v2_small: Smaller model for timbre transfer (8GB GPU)
- v1: Original continuous model (8GB GPU)
- discrete: Discrete model like SoundStream/EnCodec (18GB GPU)
- raspberry: Lightweight for Raspberry Pi (5GB GPU)
"""

import os
import sys
import subprocess
from pathlib import Path
import argparse

# Paths
PREPROCESSED_DIR = Path.home() / ".musicmill" / "rave_preprocessed"
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


def train(db_path, name, config='v2', epochs=None, augment=None):
    """Train RAVE model."""
    print(f"\n[1] Training RAVE model '{name}'...")
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
    
    # Add augmentations
    if augment:
        for aug in augment:
            cmd.extend(['--augment', aug])
    
    print(f"\n    Running: {' '.join(cmd)}")
    print("\n    This will take a while (1-2 hours for small datasets)...")
    print("    Monitor training with tensorboard:")
    print(f"      tensorboard --logdir {MODELS_DIR}")
    print("\n    Press Ctrl+C to stop training early (model will be saved).\n")
    
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


def export_model(name, streaming=True):
    """Export trained model for inference."""
    print(f"\n[2] Exporting model '{name}'...")
    
    model_path = MODELS_DIR / name
    if not model_path.exists():
        # Try with version suffix
        candidates = list(MODELS_DIR.glob(f"{name}*"))
        if candidates:
            model_path = candidates[0]
        else:
            print(f"❌ Model not found: {name}")
            if MODELS_DIR.exists():
                print(f"   Available models: {[p.name for p in MODELS_DIR.iterdir() if p.is_dir()]}")
            return None
    
    export_path = model_path / "exported"
    export_path.mkdir(exist_ok=True)
    
    cmd = [
        'rave', 'export',
        '--run', str(model_path),
        '--output', str(export_path / 'model.ts')
    ]
    
    if streaming:
        cmd.append('--streaming')
        print("    Using streaming mode (required for realtime use)")
    
    print(f"    Running: {' '.join(cmd)}")
    
    result = subprocess.run(cmd)
    
    if result.returncode != 0:
        print("❌ Export failed")
        return None
    
    print(f"✓ Model exported to: {export_path}")
    return export_path / 'model.ts'


def main():
    parser = argparse.ArgumentParser(
        description='Train RAVE model for MusicMill',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Train with default settings (v2 config)
  python train_rave.py --db_path ~/.musicmill/rave_preprocessed

  # Train smaller model (less GPU memory)
  python train_rave.py --config v2_small --db_path ~/.musicmill/rave_preprocessed

  # Train with augmentations (recommended for small datasets)
  python train_rave.py --augment mute --augment compress --db_path ~/.musicmill/rave_preprocessed

  # Export existing model only
  python train_rave.py --export-only --name musicmill_rave
        """
    )
    parser.add_argument('--name', default='musicmill_rave', help='Model name')
    parser.add_argument('--db_path', type=Path, default=PREPROCESSED_DIR,
                       help='Path to preprocessed data')
    parser.add_argument('--config', default='v2', 
                       choices=['v1', 'v2', 'v2_small', 'v2_nopqmf', 'v3', 
                               'discrete', 'onnx', 'raspberry'],
                       help='RAVE configuration (default: v2)')
    parser.add_argument('--epochs', type=int, help='Number of training epochs')
    parser.add_argument('--augment', action='append',
                       choices=['mute', 'compress', 'gain'],
                       help='Augmentations to apply (can use multiple)')
    parser.add_argument('--export-only', action='store_true',
                       help='Only export existing model')
    parser.add_argument('--no-streaming', action='store_true',
                       help='Disable streaming mode in export')
    args = parser.parse_args()
    
    print("🎵 RAVE Training for MusicMill")
    print("=" * 50)
    
    # Check RAVE installation
    if not check_rave_installed():
        print("❌ RAVE not installed.")
        print("   Run: ./scripts/setup_rave.sh")
        print("   Or:  pip install acids-rave")
        sys.exit(1)
    
    print("✓ RAVE installed")
    
    if args.export_only:
        export_model(args.name, streaming=not args.no_streaming)
        return
    
    # Check preprocessed data
    if not args.db_path.exists():
        print(f"❌ Preprocessed data not found: {args.db_path}")
        print("   Run: python scripts/prepare_training_data.py --input /path/to/music")
        sys.exit(1)
    
    print(f"✓ Found preprocessed data: {args.db_path}")
    
    # Train
    success = train(
        args.db_path, 
        args.name, 
        args.config, 
        args.epochs,
        args.augment
    )
    
    if success:
        # Export
        exported = export_model(args.name, streaming=not args.no_streaming)
        
        if exported:
            print("\n" + "=" * 50)
            print("✓ RAVE model ready!")
            print(f"  Model: {exported}")
            print("\nNext step: python scripts/export_coreml.py")


if __name__ == "__main__":
    main()
