#!/usr/bin/env python3
"""
Export RAVE model to Core ML format for use in MusicMill iOS/macOS app.
"""

import os
import sys
from pathlib import Path
import argparse

try:
    import torch
    import coremltools as ct
except ImportError:
    print("❌ Required packages not installed.")
    print("   Run: pip install torch coremltools")
    sys.exit(1)

# Paths
MUSICMILL_DIR = Path.home() / "Documents" / "MusicMill"
MODELS_DIR = MUSICMILL_DIR / "RAVE" / "models"
COREML_DIR = MUSICMILL_DIR / "RAVE" / "coreml"
APP_MODELS_DIR = Path(__file__).parent.parent / "MusicMill" / "ML" / "Models"


def find_rave_model(name):
    """Find RAVE model checkpoint."""
    # Look for exported TorchScript model
    candidates = list(MODELS_DIR.glob(f"{name}*/exported/model.ts"))
    if candidates:
        return candidates[0]
    
    # Look for checkpoint
    candidates = list(MODELS_DIR.glob(f"{name}*/*.ckpt"))
    if candidates:
        return candidates[-1]  # Latest checkpoint
    
    return None


class RAVEWrapper(torch.nn.Module):
    """Wrapper for RAVE model to make it Core ML compatible."""
    
    def __init__(self, rave_model):
        super().__init__()
        self.rave = rave_model
        
    def encode(self, audio):
        """Encode audio to latent space."""
        return self.rave.encode(audio)
    
    def decode(self, latent):
        """Decode latent to audio."""
        return self.rave.decode(latent)
    
    def forward(self, audio):
        """Full encode-decode pass."""
        z = self.encode(audio)
        return self.decode(z)


def export_to_coreml(model_path, output_dir, model_name="RAVESynthesizer"):
    """Export RAVE model to Core ML format."""
    print(f"\n[1] Loading RAVE model from: {model_path}")
    
    try:
        # Load TorchScript model
        rave = torch.jit.load(str(model_path), map_location='cpu')
        rave.eval()
    except Exception as e:
        print(f"❌ Failed to load model: {e}")
        return None
    
    print("✓ Model loaded")
    
    # Wrap model
    wrapper = RAVEWrapper(rave)
    wrapper.eval()
    
    # Create sample inputs
    # RAVE typically works with 2048-sample chunks at 44.1kHz
    batch_size = 1
    audio_length = 2048
    latent_dim = 16  # Typical RAVE latent dimension
    
    sample_audio = torch.randn(batch_size, 1, audio_length)
    sample_latent = torch.randn(batch_size, latent_dim, audio_length // 2048)
    
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Export encoder
    print("\n[2] Exporting encoder to Core ML...")
    try:
        encoder_traced = torch.jit.trace(wrapper.encode, sample_audio)
        
        encoder_mlmodel = ct.convert(
            encoder_traced,
            inputs=[
                ct.TensorType(
                    name="audio",
                    shape=(1, 1, ct.RangeDim(lower_bound=2048, upper_bound=44100, default=2048)),
                    dtype=float
                )
            ],
            outputs=[
                ct.TensorType(name="latent")
            ],
            minimum_deployment_target=ct.target.macOS13
        )
        
        encoder_path = output_dir / f"{model_name}Encoder.mlpackage"
        encoder_mlmodel.save(str(encoder_path))
        print(f"✓ Encoder saved: {encoder_path}")
    except Exception as e:
        print(f"⚠️  Encoder export failed: {e}")
        print("   Continuing with decoder only...")
        encoder_path = None
    
    # Export decoder
    print("\n[3] Exporting decoder to Core ML...")
    try:
        decoder_traced = torch.jit.trace(wrapper.decode, sample_latent)
        
        decoder_mlmodel = ct.convert(
            decoder_traced,
            inputs=[
                ct.TensorType(
                    name="latent",
                    shape=(1, latent_dim, ct.RangeDim(lower_bound=1, upper_bound=100, default=1)),
                    dtype=float
                )
            ],
            outputs=[
                ct.TensorType(name="audio")
            ],
            minimum_deployment_target=ct.target.macOS13
        )
        
        decoder_path = output_dir / f"{model_name}Decoder.mlpackage"
        decoder_mlmodel.save(str(decoder_path))
        print(f"✓ Decoder saved: {decoder_path}")
    except Exception as e:
        print(f"❌ Decoder export failed: {e}")
        return None
    
    return output_dir


def copy_to_app(coreml_dir):
    """Copy Core ML models to the app's ML/Models directory."""
    print("\n[4] Copying models to app...")
    
    APP_MODELS_DIR.mkdir(parents=True, exist_ok=True)
    
    import shutil
    for model_file in coreml_dir.glob("*.mlpackage"):
        dest = APP_MODELS_DIR / model_file.name
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(model_file, dest)
        print(f"    Copied: {model_file.name}")
    
    print(f"✓ Models copied to: {APP_MODELS_DIR}")


def main():
    parser = argparse.ArgumentParser(description='Export RAVE to Core ML')
    parser.add_argument('--name', default='musicmill_rave', help='Model name')
    parser.add_argument('--output', type=Path, default=COREML_DIR,
                       help='Output directory for Core ML models')
    parser.add_argument('--no-copy', action='store_true',
                       help="Don't copy to app directory")
    args = parser.parse_args()
    
    print("🎵 Exporting RAVE to Core ML")
    print("=" * 50)
    
    # Find model
    model_path = find_rave_model(args.name)
    if not model_path:
        print(f"❌ Model not found: {args.name}")
        print(f"   Looking in: {MODELS_DIR}")
        print(f"   Available: {list(MODELS_DIR.iterdir()) if MODELS_DIR.exists() else 'none'}")
        sys.exit(1)
    
    print(f"Found model: {model_path}")
    
    # Export
    result = export_to_coreml(model_path, args.output)
    
    if result and not args.no_copy:
        copy_to_app(result)
    
    if result:
        print("\n" + "=" * 50)
        print("✓ Core ML export complete!")
        print("\nThe models are ready to use in MusicMill.")
        print("Rebuild the app in Xcode to include the new models.")


if __name__ == "__main__":
    main()

