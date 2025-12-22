#!/usr/bin/env python3
"""
RAVE Training Script for MusicMill

This script trains a custom RAVE model on your music collection.
The resulting model will generate audio in YOUR style.

HARDWARE REQUIREMENTS:
    - OS: Linux (Ubuntu 22.04 recommended) - macOS is NOT supported for training!
    - GPU: NVIDIA with CUDA, or AMD with ROCm (see below)
    - RAM: At least 16 GB
    - Storage: SSD with ~50GB free space for datasets/checkpoints
    
    Training takes 12-48+ hours depending on dataset size and GPU.

NVIDIA GPU SETUP (recommended):
    # Any RTX 3080+ or datacenter GPU (V100, A100, etc.)
    # Install CUDA drivers, then:
    pip install acids-rave
    
AMD GPU SETUP (RX 7900 XTX, etc.):
    # Requires ROCm 5.7+ on Linux (Ubuntu 22.04 recommended)
    # 
    # Step 1: Install ROCm
    wget https://repo.radeon.com/amdgpu-install/latest/ubuntu/jammy/amdgpu-install_6.0.60002-1_all.deb
    sudo apt install ./amdgpu-install_6.0.60002-1_all.deb
    sudo amdgpu-install --usecase=rocm
    sudo usermod -aG video,render $USER
    sudo reboot
    
    # Step 2: Verify GPU detection
    rocm-smi
    
    # Step 3: Install PyTorch with ROCm (BEFORE installing acids-rave)
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.0
    
    # Step 4: Verify PyTorch sees GPU
    python -c "import torch; print(f'GPU available: {torch.cuda.is_available()}')"
    
    # Step 5: Install RAVE
    pip install acids-rave
    
    # For multi-GPU (e.g., 2x RX 7900 XTX):
    export HIP_VISIBLE_DEVICES=0,1

Usage:
    # Step 1: Prepare training data (can run on any OS)
    python train_rave.py prepare --input /path/to/your/music --output ~/Documents/MusicMill/RAVE/training_data
    
    # Step 2: Train (requires Linux with NVIDIA/CUDA or AMD/ROCm)
    python train_rave.py train --data ~/Documents/MusicMill/RAVE/training_data --name my_style
    
    # Step 3: Export for inference (can run on any OS)
    python train_rave.py export --checkpoint ~/Documents/MusicMill/RAVE/runs/my_style --output ~/Documents/MusicMill/RAVE/pretrained/my_style.ts
    
    # The exported .ts model can then be used on macOS with rave_server.py
"""

import argparse
import subprocess
import os
from pathlib import Path
import shutil

def check_gpu():
    """Check for available GPU (NVIDIA or AMD)"""
    result = {'available': False, 'type': None, 'name': 'Unknown', 'count': 0}
    
    try:
        import torch
        if torch.cuda.is_available():
            result['available'] = True
            result['count'] = torch.cuda.device_count()
            result['name'] = torch.cuda.get_device_name(0)
            
            # Detect if it's AMD (ROCm) or NVIDIA
            # ROCm presents as CUDA to PyTorch but device names differ
            name_lower = result['name'].lower()
            if 'radeon' in name_lower or 'amd' in name_lower or 'rx' in name_lower:
                result['type'] = 'amd'
            else:
                result['type'] = 'nvidia'
            
            if result['count'] > 1:
                result['name'] += f" (x{result['count']})"
    except ImportError:
        print("PyTorch not installed. Install with:")
        print("  NVIDIA: pip install torch")
        print("  AMD:    pip install torch --index-url https://download.pytorch.org/whl/rocm6.0")
    except Exception as e:
        print(f"GPU check failed: {e}")
    
    return result

def prepare_data(input_dir: str, output_dir: str, sample_rate: int = 48000):
    """Convert all audio files to training format"""
    input_path = Path(input_dir).expanduser()
    output_path = Path(output_dir).expanduser()
    output_path.mkdir(parents=True, exist_ok=True)
    
    # Find all audio files
    audio_extensions = {'.mp3', '.m4a', '.wav', '.flac', '.aiff', '.ogg'}
    audio_files = []
    for ext in audio_extensions:
        audio_files.extend(input_path.rglob(f'*{ext}'))
    
    print(f"Found {len(audio_files)} audio files")
    
    if len(audio_files) < 10:
        print("WARNING: Very few files! RAVE needs at least 1-2 hours of audio.")
        print("Recommend: 50+ tracks of 3-5 minutes each")
    
    # Calculate total duration we'll have
    converted = 0
    failed = 0
    
    for i, audio_file in enumerate(audio_files):
        output_file = output_path / f"{i:04d}_{audio_file.stem}.wav"
        
        if output_file.exists():
            print(f"Skipping (exists): {audio_file.name}")
            converted += 1
            continue
            
        print(f"[{i+1}/{len(audio_files)}] Converting: {audio_file.name}")
        
        try:
            result = subprocess.run([
                'ffmpeg', '-y', '-i', str(audio_file),
                '-ar', str(sample_rate),
                '-ac', '1',  # Mono
                '-acodec', 'pcm_f32le',
                str(output_file)
            ], capture_output=True, timeout=120)
            
            if result.returncode == 0:
                converted += 1
            else:
                print(f"  Error: {result.stderr.decode()[:100]}")
                failed += 1
        except Exception as e:
            print(f"  Failed: {e}")
            failed += 1
    
    print(f"\n=== Preparation Complete ===")
    print(f"Converted: {converted}")
    print(f"Failed: {failed}")
    print(f"Output: {output_path}")
    
    # Estimate training time
    total_wav = list(output_path.glob('*.wav'))
    if total_wav:
        import wave
        total_duration = 0
        for f in total_wav[:10]:  # Sample first 10
            try:
                with wave.open(str(f)) as w:
                    total_duration += w.getnframes() / w.getframerate()
            except:
                pass
        avg_duration = total_duration / min(10, len(total_wav))
        estimated_hours = (avg_duration * len(total_wav)) / 3600
        print(f"\nEstimated total audio: {estimated_hours:.1f} hours")
        print(f"Recommended training: {max(12, int(estimated_hours * 10))} hours minimum")

def train_model(data_dir: str, name: str, epochs: int = 1000):
    """Train RAVE model"""
    data_path = Path(data_dir).expanduser()
    runs_path = Path.home() / "Documents/MusicMill/RAVE/runs"
    runs_path.mkdir(parents=True, exist_ok=True)
    
    # Check if data exists
    wav_files = list(data_path.glob('*.wav'))
    if not wav_files:
        print(f"ERROR: No .wav files found in {data_path}")
        print("Run 'prepare' command first!")
        return
    
    print(f"Training on {len(wav_files)} files")
    print(f"Output: {runs_path / name}")
    
    # Check platform and GPU availability
    import platform
    if platform.system() == 'Darwin':
        print("\n⚠️  WARNING: RAVE training is NOT supported on macOS!")
        print("   You need Linux with NVIDIA (CUDA) or AMD (ROCm) GPU.")
        print("   You can prepare data here, then train on a Linux machine.")
        return
    
    # Check for GPU
    gpu_info = check_gpu()
    if not gpu_info['available']:
        print("\n⚠️  WARNING: No GPU detected!")
        print("   RAVE training requires a GPU (NVIDIA with CUDA or AMD with ROCm).")
        print("   See the docstring at the top of this file for setup instructions.")
        return
    
    print(f"\n✓ GPU detected: {gpu_info['name']}")
    if gpu_info['type'] == 'amd':
        print("  Using AMD ROCm (community supported)")
    print("\nThis will take 12-48+ hours depending on GPU...")
    print("Press Ctrl+C to stop (checkpoints are saved)")
    
    # RAVE training command
    cmd = [
        'rave', 'train',
        '--config', 'v2',  # Latest RAVE architecture
        '--db_path', str(data_path),
        '--name', name,
        '--out_path', str(runs_path),
        '--val_every', '10',  # Validate every 10 epochs
        '--n_signal', '131072',  # ~2.7 seconds at 48kHz
        '--max_steps', str(epochs * 1000),  # Convert epochs to steps
    ]
    
    print(f"\nCommand: {' '.join(cmd)}\n")
    
    try:
        subprocess.run(cmd)
    except KeyboardInterrupt:
        print("\n\nTraining interrupted. Checkpoints saved.")
        print(f"Resume with same command, RAVE will continue from checkpoint.")

def export_model(checkpoint_dir: str, output_path: str):
    """Export trained model to TorchScript"""
    checkpoint_path = Path(checkpoint_dir).expanduser()
    output_file = Path(output_path).expanduser()
    output_file.parent.mkdir(parents=True, exist_ok=True)
    
    # Find latest checkpoint
    checkpoints = list(checkpoint_path.glob('*.ckpt'))
    if not checkpoints:
        # Check subdirectories
        checkpoints = list(checkpoint_path.rglob('*.ckpt'))
    
    if not checkpoints:
        print(f"ERROR: No checkpoints found in {checkpoint_path}")
        return
    
    latest_ckpt = max(checkpoints, key=lambda p: p.stat().st_mtime)
    print(f"Exporting: {latest_ckpt}")
    
    cmd = [
        'rave', 'export',
        '--run', str(latest_ckpt.parent),
        '--streaming',  # Enable streaming mode for real-time
        '--output', str(output_file)
    ]
    
    print(f"Command: {' '.join(cmd)}")
    subprocess.run(cmd)
    
    if output_file.exists():
        print(f"\n✓ Model exported: {output_file}")
        print(f"  Size: {output_file.stat().st_size / 1024 / 1024:.1f} MB")
    else:
        print("Export may have failed - check output above")

def check_system():
    """Check system readiness for RAVE training"""
    import platform
    
    print("=== RAVE Training System Check ===\n")
    
    # OS
    os_name = platform.system()
    print(f"OS: {os_name}")
    if os_name == 'Darwin':
        print("   ❌ macOS - training not supported")
        print("   → Use Linux with NVIDIA or AMD GPU")
    elif os_name == 'Linux':
        print("   ✓ Linux - supported")
    else:
        print("   ⚠️  Windows - may work with NVIDIA")
    
    # GPU
    print()
    gpu = check_gpu()
    if gpu['available']:
        print(f"GPU: {gpu['name']}")
        print(f"   ✓ {gpu['type'].upper()} GPU detected")
        if gpu['type'] == 'amd':
            print("   ℹ️  AMD/ROCm is community supported")
    else:
        print("GPU: None detected")
        print("   ❌ No GPU found - training requires GPU")
    
    # RAVE
    print()
    try:
        result = subprocess.run(['rave', '--help'], capture_output=True, timeout=5)
        if result.returncode == 0:
            print("RAVE: ✓ Installed")
        else:
            print("RAVE: ❌ Not working")
    except FileNotFoundError:
        print("RAVE: ❌ Not installed")
        print("   → pip install acids-rave")
    except Exception as e:
        print(f"RAVE: ❌ Error checking: {e}")
    
    # Summary
    print("\n" + "=" * 35)
    if gpu['available'] and os_name == 'Linux':
        print("✓ System ready for RAVE training!")
    else:
        print("✗ System not ready - see issues above")

def main():
    parser = argparse.ArgumentParser(description='RAVE Training for MusicMill')
    subparsers = parser.add_subparsers(dest='command', required=True)
    
    # Check command
    subparsers.add_parser('check', help='Check system readiness for training')
    
    # Prepare command
    prep = subparsers.add_parser('prepare', help='Prepare training data')
    prep.add_argument('--input', '-i', required=True, help='Input music directory')
    prep.add_argument('--output', '-o', default='~/Documents/MusicMill/RAVE/training_data',
                      help='Output directory for training data')
    prep.add_argument('--sample-rate', type=int, default=48000, help='Sample rate')
    
    # Train command
    train = subparsers.add_parser('train', help='Train RAVE model')
    train.add_argument('--data', '-d', required=True, help='Training data directory')
    train.add_argument('--name', '-n', default='custom', help='Model name')
    train.add_argument('--epochs', type=int, default=1000, help='Training epochs')
    
    # Export command
    export = subparsers.add_parser('export', help='Export model to TorchScript')
    export.add_argument('--checkpoint', '-c', required=True, help='Checkpoint directory')
    export.add_argument('--output', '-o', required=True, help='Output .ts file path')
    
    args = parser.parse_args()
    
    if args.command == 'check':
        check_system()
    elif args.command == 'prepare':
        prepare_data(args.input, args.output, args.sample_rate)
    elif args.command == 'train':
        train_model(args.data, args.name, args.epochs)
    elif args.command == 'export':
        export_model(args.checkpoint, args.output)

if __name__ == '__main__':
    main()
