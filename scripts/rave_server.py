#!/usr/bin/env python3
"""
RAVE inference server for MusicMill.
Uses PyTorch MPS for fast GPU inference on Apple Silicon.

Supports controllable generation via style anchors, energy, and tempo.

Usage:
    # Start server for Swift IPC:
    python rave_server.py --model percussion --server
    
    # Generate with controls:
    python rave_server.py --model percussion --generate output.wav --style "darkwave" --energy 0.8
    
    # Benchmark performance:
    python rave_server.py --model percussion --benchmark
"""

import argparse
import json
import os
import sys
import struct
import socket
import time
from pathlib import Path
from threading import Thread, Lock
from collections import deque

import numpy as np

try:
    import torch
    import torch.nn.functional as F
except ImportError:
    print("Error: PyTorch required. Install with: pip install torch")
    sys.exit(1)

# Default paths
MODELS_DIR = os.path.expanduser("~/Documents/MusicMill/RAVE")
PRETRAINED_DIR = os.path.expanduser("~/Documents/MusicMill/RAVE/pretrained")
ANCHORS_FILE = os.path.expanduser("~/Documents/MusicMill/RAVE/anchors.json")
SOCKET_PATH = "/tmp/rave_server.sock"


class RAVEController:
    """Manages RAVE model and controllable generation."""
    
    def __init__(self, model_path: str, anchors_path: str = None):
        self.model = None
        self.device = "cpu"
        self.anchors = {}
        self.latent_dim = 128  # Default, updated when model loads
        self.sample_rate = 48000
        self.samples_per_frame = 2048
        
        # Current control state
        self.current_latent = None
        self.target_latent = None
        self.interpolation_rate = 0.1
        
        # Temporal state for continuous generation
        self.time_phase = 0.0  # Accumulated time for continuity
        self.variation_amount = 0.5  # How much random variation to add
        
        # Lock for thread-safe access
        self.lock = Lock()
        
        # Load model and anchors
        self._load_model(model_path)
        if anchors_path:
            self._load_anchors(anchors_path)
    
    def _load_model(self, model_path: str):
        """Load RAVE model for inference."""
        # Resolve model path
        if not model_path.endswith('.ts'):
            pretrained = Path(PRETRAINED_DIR) / f"{model_path}.ts"
            if pretrained.exists():
                model_path = str(pretrained)
            else:
                models_dir = Path(MODELS_DIR) / "models" / model_path
                if models_dir.exists():
                    ts_files = list(models_dir.glob("*.ts"))
                    if ts_files:
                        model_path = str(ts_files[0])
        
        if not os.path.exists(model_path):
            raise FileNotFoundError(f"Model not found: {model_path}")
        
        print(f"Loading model: {model_path}")
        self.model = torch.jit.load(model_path, map_location="cpu")
        
        # Use MPS if available
        if torch.backends.mps.is_available():
            self.device = "mps"
            self.model = self.model.to("mps")
            print("  ✓ Using MPS (Apple Silicon GPU)")
        else:
            print("  ! MPS not available, using CPU")
        
        self.model.eval()
        
        # Detect latent dimension
        test_z = torch.randn(1, 128, 10, device=self.device)
        try:
            with torch.no_grad():
                _ = self.model.decode(test_z)
            self.latent_dim = 128
        except:
            # Try different dimensions
            for dim in [16, 32, 64, 256]:
                try:
                    test_z = torch.randn(1, dim, 10, device=self.device)
                    with torch.no_grad():
                        _ = self.model.decode(test_z)
                    self.latent_dim = dim
                    break
                except:
                    continue
        
        print(f"  Latent dimension: {self.latent_dim}")
        
        # Initialize latent vectors
        self.current_latent = torch.zeros(self.latent_dim, device=self.device)
        self.target_latent = torch.zeros(self.latent_dim, device=self.device)
    
    def _load_anchors(self, anchors_path: str):
        """Load style anchors from JSON file."""
        if not os.path.exists(anchors_path):
            print(f"  Anchors file not found: {anchors_path}")
            return
        
        with open(anchors_path) as f:
            data = json.load(f)
        
        self.anchors = {}
        for style, info in data.get('styles', {}).items():
            mean = torch.tensor(info['mean'], device=self.device, dtype=torch.float32)
            std = torch.tensor(info['std'], device=self.device, dtype=torch.float32)
            self.anchors[style] = {'mean': mean, 'std': std}
        
        print(f"  Loaded {len(self.anchors)} style anchors")
    
    def set_controls(self, style_blend: dict = None, energy: float = 0.5, 
                     tempo_factor: float = 1.0, variation: float = 0.5):
        """
        Set target latent based on control parameters.
        
        Args:
            style_blend: Dict of {style_name: weight}, weights should sum to 1.0
            energy: 0.0-1.0, controls latent magnitude
            tempo_factor: 0.5-2.0, affects generation speed
            variation: 0.0-1.0, adds random variation to latent
        """
        with self.lock:
            # Store variation amount for temporal evolution
            self.variation_amount = max(0.1, min(1.0, variation))
            
            # Start with zero latent
            new_latent = torch.zeros(self.latent_dim, device=self.device)
            
            # Blend style anchors if provided
            if style_blend and self.anchors:
                total_weight = sum(style_blend.values())
                for style, weight in style_blend.items():
                    if style in self.anchors:
                        normalized_weight = weight / total_weight if total_weight > 0 else 0
                        anchor = self.anchors[style]
                        # Use mean + some variation from std
                        style_latent = anchor['mean'] + variation * anchor['std'] * torch.randn_like(anchor['std'])
                        new_latent = new_latent + normalized_weight * style_latent
            else:
                # Random latent if no style specified
                new_latent = torch.randn(self.latent_dim, device=self.device) * variation
            
            # Apply energy scaling (0.3 to 2.0 range)
            energy_scale = 0.3 + energy * 1.7
            new_latent = new_latent * energy_scale
            
            self.target_latent = new_latent
    
    def generate_chunk(self, num_frames: int = 50, tempo_factor: float = 1.0) -> np.ndarray:
        """
        Generate audio chunk with current controls.
        
        Uses temporal evolution to create varied, continuous audio across chunks.
        
        Args:
            num_frames: Number of latent frames to generate
            tempo_factor: Time-stretch factor (>1 = faster, <1 = slower)
        
        Returns:
            Audio samples as numpy array
        """
        with self.lock:
            # Interpolate current toward target (for style transitions)
            self.current_latent = (
                self.current_latent + 
                (self.target_latent - self.current_latent) * self.interpolation_rate
            )
            base_latent = self.current_latent.clone()
            variation = self.variation_amount
            start_phase = self.time_phase
        
        # Generate latent sequence - similar to direct generation but with style control
        # The key insight: direct generation uses random z for each frame, which creates variety
        
        # Start with random latent for full variety (like direct generation)
        z = torch.randn(1, self.latent_dim, num_frames, device=self.device)
        
        # Blend toward the target style (base_latent) based on variation setting
        # variation=0 -> pure style, variation=1 -> pure random
        style_weight = 1.0 - variation
        if style_weight > 0:
            style_expanded = base_latent.unsqueeze(0).unsqueeze(-1).expand(-1, -1, num_frames)
            z = z * variation + style_expanded * style_weight
        
        # Scale by energy-based magnitude
        z = z * (0.5 + variation * 0.5)
        
        # Update phase for next chunk (ensures continuity)
        with self.lock:
            self.time_phase = start_phase + num_frames
        
        # Apply tempo by interpolating along time axis
        if tempo_factor != 1.0:
            target_frames = int(num_frames / tempo_factor)
            z = F.interpolate(z, size=target_frames, mode='linear', align_corners=False)
        
        # Decode
        with torch.no_grad():
            audio = self.model.decode(z)
        
        # Convert to numpy
        audio_np = audio.cpu().numpy().squeeze()
        
        # Handle mono/stereo
        if len(audio_np.shape) == 2:
            audio_np = audio_np.mean(axis=0)  # Mix to mono
        
        return audio_np
    
    def get_styles(self) -> list:
        """Get list of available style names."""
        return list(self.anchors.keys())


def run_server(controller: RAVEController, socket_path: str = SOCKET_PATH):
    """
    Run Unix socket server for Swift IPC.
    
    Protocol:
        Client sends: JSON control message + null terminator
        Server sends: 4-byte length + float32 audio data
    
    Control message format:
        {
            "command": "generate" | "set_controls" | "get_styles",
            "frames": 50,
            "style_blend": {"darkwave": 0.7, "synthwave": 0.3},
            "energy": 0.8,
            "tempo_factor": 1.0,
            "variation": 0.3
        }
    """
    # Remove old socket
    if os.path.exists(socket_path):
        os.remove(socket_path)
    
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(1)
    
    print(f"\nRAVE server listening on: {socket_path}")
    print("Available styles:", controller.get_styles())
    print("\nWaiting for connections...")
    
    try:
        while True:
            conn, _ = server.accept()
            print("  Client connected")
            
            try:
                handle_connection(conn, controller)
            except Exception as e:
                print(f"  Connection error: {e}")
            finally:
                conn.close()
                print("  Client disconnected")
    
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        server.close()
        if os.path.exists(socket_path):
            os.remove(socket_path)


def handle_connection(conn: socket.socket, controller: RAVEController):
    """Handle a client connection with streaming audio."""
    buffer = b""
    request_count = 0
    
    while True:
        # Read until we get a null-terminated JSON message
        try:
            data = conn.recv(4096)
        except Exception as e:
            print(f"    Recv error: {e}")
            break
            
        if not data:
            print(f"    Connection closed by client after {request_count} requests")
            break
        
        buffer += data
        
        # Check for complete message (null-terminated)
        if b'\0' in buffer:
            message, buffer = buffer.split(b'\0', 1)
            
            try:
                request = json.loads(message.decode('utf-8'))
                request_count += 1
                
                response = process_request(request, controller)
                
                if response is not None:
                    # Send response
                    if isinstance(response, np.ndarray):
                        # Audio data
                        audio_bytes = response.astype(np.float32).tobytes()
                        conn.sendall(struct.pack('I', len(audio_bytes)))
                        conn.sendall(audio_bytes)
                        if request_count <= 5 or request_count % 10 == 0:
                            print(f"    Request #{request_count}: sent {len(audio_bytes)} bytes")
                    else:
                        # JSON response
                        json_bytes = json.dumps(response).encode('utf-8') + b'\0'
                        conn.sendall(json_bytes)
            
            except json.JSONDecodeError as e:
                print(f"    Invalid JSON: {e}")
            except Exception as e:
                print(f"    Request error #{request_count}: {e}")
                import traceback
                traceback.print_exc()


def process_request(request: dict, controller: RAVEController):
    """Process a control request and return response."""
    command = request.get('command', 'generate')
    
    if command == 'get_styles':
        return {'styles': controller.get_styles()}
    
    elif command == 'set_controls':
        controller.set_controls(
            style_blend=request.get('style_blend'),
            energy=request.get('energy', 0.5),
            tempo_factor=request.get('tempo_factor', 1.0),
            variation=request.get('variation', 0.5)
        )
        return {'status': 'ok'}
    
    elif command == 'generate':
        # Set controls if provided
        if any(k in request for k in ['style_blend', 'energy', 'tempo_factor', 'variation']):
            controller.set_controls(
                style_blend=request.get('style_blend'),
                energy=request.get('energy', 0.5),
                tempo_factor=request.get('tempo_factor', 1.0),
                variation=request.get('variation', 0.5)
            )
        
        # Generate audio
        frames = request.get('frames', 50)
        tempo = request.get('tempo_factor', 1.0)
        
        audio = controller.generate_chunk(frames, tempo)
        return audio
    
    else:
        return {'error': f'Unknown command: {command}'}


def generate_file(controller: RAVEController, output_path: str, 
                  duration: float, style_blend: dict = None,
                  energy: float = 0.5, tempo_factor: float = 1.0):
    """Generate audio file with controls."""
    import scipy.io.wavfile as wav
    
    # Set controls
    controller.set_controls(
        style_blend=style_blend,
        energy=energy,
        tempo_factor=tempo_factor
    )
    
    # Calculate frames needed
    samples_per_frame = controller.samples_per_frame
    total_samples = int(duration * controller.sample_rate)
    
    print(f"Generating {duration}s of audio...")
    
    # Generate in chunks
    chunks = []
    generated_samples = 0
    chunk_frames = 100  # ~2 seconds per chunk
    
    while generated_samples < total_samples:
        audio = controller.generate_chunk(chunk_frames, tempo_factor)
        chunks.append(audio)
        generated_samples += len(audio)
        
        # Progress
        progress = min(100, int(100 * generated_samples / total_samples))
        print(f"\r  Progress: {progress}%", end="", flush=True)
    
    print()
    
    # Concatenate and trim
    full_audio = np.concatenate(chunks)[:total_samples]
    
    # Normalize
    max_val = np.abs(full_audio).max()
    if max_val > 0:
        full_audio = full_audio / max_val * 0.9
    
    # Save
    audio_int = (full_audio * 32767).astype(np.int16)
    wav.write(output_path, controller.sample_rate, audio_int)
    print(f"  ✓ Saved: {output_path}")


def benchmark(controller: RAVEController):
    """Benchmark generation performance."""
    print("\nBenchmarking RAVE generation...")
    
    # Warmup
    _ = controller.generate_chunk(10)
    if controller.device == "mps":
        torch.mps.synchronize()
    
    results = []
    for frames in [10, 50, 100, 200]:
        times = []
        
        for _ in range(5):
            start = time.time()
            audio = controller.generate_chunk(frames)
            if controller.device == "mps":
                torch.mps.synchronize()
            elapsed = time.time() - start
            times.append(elapsed)
        
        avg_time = np.mean(times)
        audio_seconds = frames * controller.samples_per_frame / controller.sample_rate
        realtime_factor = audio_seconds / avg_time
        
        results.append({
            'frames': frames,
            'audio_seconds': audio_seconds,
            'time_ms': avg_time * 1000,
            'realtime_factor': realtime_factor
        })
        
        print(f"  {frames} frames ({audio_seconds:.1f}s audio): "
              f"{avg_time*1000:.1f}ms, {realtime_factor:.1f}x realtime")
    
    return results


def main():
    parser = argparse.ArgumentParser(description="RAVE inference server for MusicMill")
    parser.add_argument('--model', '-m', default="percussion",
                        help='Model path or name')
    parser.add_argument('--anchors', '-a', default=ANCHORS_FILE,
                        help='Style anchors JSON file')
    parser.add_argument('--generate', '-g', 
                        help='Generate audio to this file')
    parser.add_argument('--duration', '-d', type=float, default=10,
                        help='Duration in seconds for generation')
    parser.add_argument('--style', '-s', 
                        help='Style name for generation (comma-separated for blend)')
    parser.add_argument('--energy', '-e', type=float, default=0.5,
                        help='Energy level 0.0-1.0')
    parser.add_argument('--tempo', '-t', type=float, default=1.0,
                        help='Tempo factor (0.5-2.0)')
    parser.add_argument('--server', action='store_true',
                        help='Run as Unix socket server')
    parser.add_argument('--socket', default=SOCKET_PATH,
                        help=f'Socket path (default: {SOCKET_PATH})')
    parser.add_argument('--benchmark', action='store_true',
                        help='Run performance benchmark')
    
    args = parser.parse_args()
    
    # Load anchors if they exist
    anchors_path = args.anchors if os.path.exists(args.anchors) else None
    
    # Create controller
    controller = RAVEController(args.model, anchors_path)
    
    if args.benchmark:
        benchmark(controller)
    
    elif args.server:
        run_server(controller, args.socket)
    
    elif args.generate:
        # Parse style blend
        style_blend = None
        if args.style:
            styles = [s.strip() for s in args.style.split(',')]
            weight = 1.0 / len(styles)
            style_blend = {s: weight for s in styles}
        
        generate_file(
            controller, args.generate, args.duration,
            style_blend=style_blend,
            energy=args.energy,
            tempo_factor=args.tempo
        )
    
    else:
        # Default: quick test
        print("\nQuick test generation...")
        output = os.path.expanduser("~/Documents/MusicMill/RAVE/test_output.wav")
        generate_file(controller, output, 5)
        print(f"\nTo play: afplay {output}")


if __name__ == "__main__":
    main()
