#!/usr/bin/env python3
"""
RAVE inference server for MusicMill.
Uses PyTorch MPS for fast GPU inference on Apple Silicon.

Usage:
    python rave_server.py --model pretrained/percussion.ts --port 9999
    
Or for batch generation:
    python rave_server.py --model pretrained/percussion.ts --generate output.wav --duration 10
"""

import argparse
import torch
import numpy as np
import os
import sys

# Model path
MODELS_DIR = os.path.expanduser("~/Documents/MusicMill/RAVE/pretrained")


def load_model(model_name="percussion"):
    """Load RAVE model for MPS inference."""
    model_path = os.path.join(MODELS_DIR, f"{model_name}.ts")
    if not os.path.exists(model_path):
        print(f"Model not found: {model_path}")
        print("Available models:")
        for f in os.listdir(MODELS_DIR):
            if f.endswith(".ts"):
                print(f"  - {f[:-3]}")
        sys.exit(1)
    
    print(f"Loading {model_path}...")
    model = torch.jit.load(model_path, map_location="cpu")
    
    # Move to MPS if available
    if torch.backends.mps.is_available():
        model = model.to("mps")
        print("  ✓ Using MPS (Apple Silicon GPU)")
    else:
        print("  ! MPS not available, using CPU")
    
    model.eval()
    return model


def generate_audio(model, duration_seconds=10, sample_rate=48000):
    """Generate audio using RAVE model."""
    device = next(model.parameters()).device
    
    # RAVE uses ~2048 samples per latent frame
    samples_per_frame = 2048
    num_frames = int(duration_seconds * sample_rate / samples_per_frame)
    
    print(f"Generating {duration_seconds}s of audio ({num_frames} frames)...")
    
    # Generate random latent codes
    # RAVE uses 128-dimensional latent space
    z = torch.randn(1, 128, num_frames, device=device)
    
    with torch.no_grad():
        audio = model.decode(z)
    
    # Move to CPU and convert to numpy
    audio = audio.cpu().numpy().squeeze()
    
    # Handle stereo/mono
    if len(audio.shape) == 2:
        audio = audio.T  # (channels, samples) -> (samples, channels)
    
    return audio, sample_rate


def save_wav(audio, sample_rate, output_path):
    """Save audio to WAV file."""
    import scipy.io.wavfile as wav
    
    # Normalize to prevent clipping
    max_val = np.abs(audio).max()
    if max_val > 0:
        audio = audio / max_val * 0.9
    
    # Convert to int16
    audio_int = (audio * 32767).astype(np.int16)
    
    wav.write(output_path, sample_rate, audio_int)
    print(f"  ✓ Saved: {output_path}")


def run_server(model, port=9999):
    """Run a simple inference server using Unix sockets."""
    import socket
    import struct
    
    sock_path = f"/tmp/rave_server_{port}.sock"
    
    # Remove old socket
    if os.path.exists(sock_path):
        os.remove(sock_path)
    
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(sock_path)
    server.listen(1)
    
    print(f"RAVE server listening on {sock_path}")
    print("Send latent codes, receive audio samples")
    
    device = next(model.parameters()).device
    
    try:
        while True:
            conn, _ = server.accept()
            try:
                # Read request size (4 bytes)
                size_data = conn.recv(4)
                if not size_data:
                    continue
                
                num_frames = struct.unpack('I', size_data)[0]
                
                # Generate audio
                z = torch.randn(1, 128, num_frames, device=device)
                with torch.no_grad():
                    audio = model.decode(z)
                
                # Send back
                audio_bytes = audio.cpu().numpy().tobytes()
                conn.sendall(struct.pack('I', len(audio_bytes)))
                conn.sendall(audio_bytes)
                
            finally:
                conn.close()
    finally:
        server.close()
        os.remove(sock_path)


def main():
    parser = argparse.ArgumentParser(description="RAVE inference for MusicMill")
    parser.add_argument("--model", default="percussion", help="Model name")
    parser.add_argument("--generate", help="Generate audio to this file")
    parser.add_argument("--duration", type=float, default=10, help="Duration in seconds")
    parser.add_argument("--server", action="store_true", help="Run as server")
    parser.add_argument("--port", type=int, default=9999, help="Server port")
    parser.add_argument("--benchmark", action="store_true", help="Run benchmark")
    
    args = parser.parse_args()
    
    model = load_model(args.model)
    
    if args.benchmark:
        import time
        device = next(model.parameters()).device
        
        print("\nBenchmarking...")
        for frames in [10, 50, 100, 200]:
            z = torch.randn(1, 128, frames, device=device)
            
            # Warmup
            with torch.no_grad():
                _ = model.decode(z)
            torch.mps.synchronize()
            
            # Time it
            start = time.time()
            for _ in range(10):
                with torch.no_grad():
                    audio = model.decode(z)
            torch.mps.synchronize()
            elapsed = time.time() - start
            
            audio_seconds = frames * 2048 / 48000
            realtime_factor = audio_seconds * 10 / elapsed
            print(f"  {frames} frames ({audio_seconds:.1f}s audio): "
                  f"{elapsed*100:.0f}ms/iter, {realtime_factor:.1f}x realtime")
    
    elif args.generate:
        audio, sr = generate_audio(model, args.duration)
        save_wav(audio, sr, args.generate)
    
    elif args.server:
        run_server(model, args.port)
    
    else:
        # Default: quick test
        print("\nQuick test generation...")
        audio, sr = generate_audio(model, 2)
        output = os.path.expanduser("~/Documents/MusicMill/RAVE/test_output.wav")
        save_wav(audio, sr, output)
        print(f"\nTo play: afplay {output}")


if __name__ == "__main__":
    main()

