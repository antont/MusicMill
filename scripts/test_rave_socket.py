#!/usr/bin/env python3
"""
Test RAVE socket communication vs direct generation.

This test:
1. Generates audio directly with RAVE (known good)
2. Generates audio via socket protocol (what Swift uses)
3. Compares the two outputs

Run with:
    python scripts/test_rave_socket.py
"""

import os
import sys
import json
import socket
import struct
import time
import subprocess
import numpy as np
from pathlib import Path

# Add scripts directory to path
sys.path.insert(0, str(Path(__file__).parent))

SOCKET_PATH = "/tmp/rave_server.sock"
MODEL_PATH = os.path.expanduser("~/Documents/MusicMill/RAVE/pretrained/percussion.ts")
VENV_PYTHON = os.path.expanduser("~/Documents/MusicMill/RAVE/venv/bin/python3")

def generate_direct(duration: float = 5.0) -> np.ndarray:
    """Generate audio directly using RAVE (no socket)."""
    print("\n=== DIRECT GENERATION ===")
    
    # Import here to use the same environment
    import torch
    
    print(f"Loading model: {MODEL_PATH}")
    model = torch.jit.load(MODEL_PATH, map_location="cpu")
    
    if torch.backends.mps.is_available():
        model = model.to("mps")
        device = "mps"
        print("  Using MPS")
    else:
        device = "cpu"
        print("  Using CPU")
    
    model.eval()
    
    # Generate
    sample_rate = 48000
    samples_per_frame = 2048
    total_samples = int(duration * sample_rate)
    frames_needed = total_samples // samples_per_frame + 1
    
    print(f"Generating {duration}s ({frames_needed} frames)...")
    
    # Generate in one chunk (like CLI does)
    z = torch.randn(1, 128, frames_needed, device=device)
    
    with torch.no_grad():
        audio = model.decode(z)
    
    audio_np = audio.cpu().numpy().squeeze()
    if len(audio_np.shape) == 2:
        audio_np = audio_np.mean(axis=0)
    
    # Trim to exact duration
    audio_np = audio_np[:total_samples]
    
    print(f"  Generated {len(audio_np)} samples")
    print(f"  Range: [{audio_np.min():.3f}, {audio_np.max():.3f}]")
    print(f"  RMS: {np.sqrt(np.mean(audio_np**2)):.4f}")
    
    return audio_np


def start_server():
    """Start the RAVE server in background."""
    print("\n=== STARTING SERVER ===")
    
    # Kill any existing server
    os.system("pkill -f rave_server 2>/dev/null")
    if os.path.exists(SOCKET_PATH):
        os.remove(SOCKET_PATH)
    
    # Start server
    script_path = Path(__file__).parent / "rave_server.py"
    cmd = [VENV_PYTHON, str(script_path), "--model", MODEL_PATH, "--server"]
    
    print(f"Starting: {' '.join(cmd)}")
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    )
    
    # Wait for server to be ready
    for i in range(50):
        time.sleep(0.1)
        if os.path.exists(SOCKET_PATH):
            print(f"  Server ready after {(i+1)*0.1:.1f}s")
            return process
    
    # Print any output
    try:
        output = process.stdout.read()
        print(f"  Server output: {output}")
    except:
        pass
    
    raise RuntimeError("Server failed to start")


def generate_via_socket(duration: float = 5.0, chunk_frames: int = 100) -> np.ndarray:
    """Generate audio via socket protocol (like Swift does)."""
    print("\n=== SOCKET GENERATION ===")
    
    sample_rate = 48000
    samples_per_frame = 2048
    total_samples = int(duration * sample_rate)
    
    # Connect to server
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    print(f"  Connected to {SOCKET_PATH}")
    
    all_audio = []
    generated_samples = 0
    request_count = 0
    
    while generated_samples < total_samples:
        # Send generate request (same format as Swift)
        request = {
            "command": "generate",
            "frames": chunk_frames,
            "energy": 0.5,
            "tempo_factor": 1.0,
            "variation": 0.5
        }
        
        request_bytes = json.dumps(request).encode('utf-8') + b'\0'
        sock.sendall(request_bytes)
        request_count += 1
        
        # Receive response (4-byte length + float32 data)
        length_bytes = b""
        while len(length_bytes) < 4:
            chunk = sock.recv(4 - len(length_bytes))
            if not chunk:
                raise RuntimeError("Connection closed while reading length")
            length_bytes += chunk
        
        length = struct.unpack('I', length_bytes)[0]
        
        # Read audio data
        audio_bytes = b""
        while len(audio_bytes) < length:
            chunk = sock.recv(min(4096, length - len(audio_bytes)))
            if not chunk:
                raise RuntimeError("Connection closed while reading audio")
            audio_bytes += chunk
        
        # Convert to float array
        audio_chunk = np.frombuffer(audio_bytes, dtype=np.float32)
        all_audio.append(audio_chunk)
        generated_samples += len(audio_chunk)
        
        if request_count <= 3 or request_count % 5 == 0:
            print(f"  Request #{request_count}: got {len(audio_chunk)} samples, total: {generated_samples}")
    
    sock.close()
    
    # Concatenate all chunks
    audio_np = np.concatenate(all_audio)[:total_samples]
    
    print(f"  Total requests: {request_count}")
    print(f"  Generated {len(audio_np)} samples")
    print(f"  Range: [{audio_np.min():.3f}, {audio_np.max():.3f}]")
    print(f"  RMS: {np.sqrt(np.mean(audio_np**2)):.4f}")
    
    return audio_np


def save_wav(audio: np.ndarray, filename: str, sample_rate: int = 48000):
    """Save audio to WAV file."""
    import scipy.io.wavfile as wav
    
    # Normalize to prevent clipping
    max_val = np.abs(audio).max()
    if max_val > 0:
        audio = audio / max_val * 0.9
    
    # Convert to int16
    audio_int = (audio * 32767).astype(np.int16)
    wav.write(filename, sample_rate, audio_int)
    print(f"  Saved: {filename}")


def analyze_audio(audio: np.ndarray, name: str):
    """Analyze audio for artifacts."""
    print(f"\n=== ANALYSIS: {name} ===")
    
    # Check for silence
    rms = np.sqrt(np.mean(audio**2))
    print(f"  RMS energy: {rms:.4f}")
    
    # Check for clipping
    clipped = np.sum(np.abs(audio) > 0.99) / len(audio) * 100
    print(f"  Clipped samples: {clipped:.2f}%")
    
    # Check for repetition (autocorrelation at various lags)
    print("  Checking for repetition...")
    chunk_size = 2048  # One RAVE frame
    
    for lag_frames in [1, 2, 5, 10]:
        lag = lag_frames * chunk_size
        if lag < len(audio) - chunk_size:
            correlation = np.corrcoef(
                audio[lag:lag+chunk_size*10],
                audio[:chunk_size*10]
            )[0, 1]
            print(f"    Correlation at {lag_frames} frames lag: {correlation:.3f}")
    
    # Check for sudden jumps (clicks)
    diff = np.abs(np.diff(audio))
    large_jumps = np.sum(diff > 0.5) 
    print(f"  Large amplitude jumps (>0.5): {large_jumps}")
    
    return rms


def main():
    print("=" * 60)
    print("RAVE SOCKET TEST")
    print("=" * 60)
    
    duration = 5.0
    output_dir = "/tmp"
    
    # Test 1: Direct generation
    try:
        direct_audio = generate_direct(duration)
        save_wav(direct_audio, f"{output_dir}/rave_direct.wav")
        direct_rms = analyze_audio(direct_audio, "DIRECT")
    except Exception as e:
        print(f"Direct generation failed: {e}")
        import traceback
        traceback.print_exc()
        return
    
    # Test 2: Socket generation
    server_process = None
    try:
        server_process = start_server()
        time.sleep(1)  # Extra time for model loading
        
        # Test with same chunk size as Swift
        socket_audio = generate_via_socket(duration, chunk_frames=100)
        save_wav(socket_audio, f"{output_dir}/rave_socket.wav")
        socket_rms = analyze_audio(socket_audio, "SOCKET")
        
        # Test with smaller chunks (like original Swift code)
        socket_audio_small = generate_via_socket(duration, chunk_frames=50)
        save_wav(socket_audio_small, f"{output_dir}/rave_socket_small.wav")
        analyze_audio(socket_audio_small, "SOCKET (50 frames)")
        
    except Exception as e:
        print(f"Socket generation failed: {e}")
        import traceback
        traceback.print_exc()
    finally:
        if server_process:
            server_process.terminate()
            server_process.wait()
            print("\nServer stopped")
    
    print("\n" + "=" * 60)
    print("TEST COMPLETE")
    print("=" * 60)
    print(f"\nOutput files:")
    print(f"  {output_dir}/rave_direct.wav     - Direct generation (reference)")
    print(f"  {output_dir}/rave_socket.wav     - Via socket (100 frames)")
    print(f"  {output_dir}/rave_socket_small.wav - Via socket (50 frames)")
    print(f"\nCompare these files to identify where the problem is!")


if __name__ == "__main__":
    main()

