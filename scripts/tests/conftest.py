"""Synthetic audio fixtures for the phrase-graph pipeline tests.

Each helper is a plain function (import via ``from tests.conftest import ...``)
and is also exposed as a same-named pytest fixture returning the function.
"""
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

SR = 22050
_PITCH_CLASSES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def _pitch_class(root: str) -> int:
    pc = _PITCH_CLASSES[root[0].upper()]
    for ch in root[1:]:
        pc += 1 if ch in "#♯" else -1 if ch in "b♭" else 0
    return pc % 12


def _midi_hz(midi: float) -> float:
    return 440.0 * 2.0 ** ((midi - 69) / 12.0)


def click_track(bpm: float, seconds: float, sr: int = SR, accent_every: int = 4,
                accent_offset: int = 0, first_beat: float = 0.0) -> np.ndarray:
    """Click on every beat; beat index accent_offset + k*accent_every is 4x
    louder and carries a 60 Hz thump."""
    n = int(round(seconds * sr))
    y = np.zeros(n, dtype=np.float32)
    period = 60.0 / bpm
    click_len = int(0.03 * sr)
    t = np.arange(click_len) / sr
    click = np.sin(2 * np.pi * 1500 * t) * np.exp(-t * 150)
    thump_len = int(0.12 * sr)
    tt = np.arange(thump_len) / sr
    thump = np.sin(2 * np.pi * 60 * tt) * np.exp(-tt * 25)
    i = 0
    while True:
        start = int(round((first_beat + i * period) * sr))
        if start >= n:
            break
        if start >= 0:
            accented = (i - accent_offset) % accent_every == 0 and i >= accent_offset
            if accented:
                seg = 0.8 * click
                seg_full = np.zeros(thump_len)
                seg_full[:click_len] += seg
                seg_full += 0.8 * thump
            else:
                seg_full = np.zeros(click_len)
                seg_full += 0.2 * click
            end = min(n, start + len(seg_full))
            y[start:end] += seg_full[:end - start].astype(np.float32)
        i += 1
    return np.clip(y, -1.0, 1.0)


def chord_tone(root: str, mode: str, seconds: float, sr: int = SR) -> np.ndarray:
    """Sustained harmonic-rich triad (major or minor) plus a low-root drone."""
    if mode not in ("major", "minor"):
        raise ValueError(f"mode must be 'major' or 'minor', got {mode!r}")
    pc = _pitch_class(root)
    third = 4 if mode == "major" else 3
    base = 60 + pc  # root in the octave starting at C4
    if base > 66:
        base -= 12
    n = int(round(seconds * sr))
    t = np.arange(n) / sr
    y = np.zeros(n)

    def add(midi: float, gain: float, harmonics: int = 6):
        f = _midi_hz(midi)
        for h in range(1, harmonics + 1):
            if f * h < sr / 2:
                y[:] += gain / h * np.sin(2 * np.pi * f * h * t)

    for interval in (0, third, 7):
        add(base + interval, 1.0)
    add(base - 12, 1.0)   # root doubled an octave down
    add(base - 24, 1.5)   # low-root drone
    peak = np.abs(y).max()
    if peak > 0:
        y = y / peak * 0.8
    return y.astype(np.float32)


def write_wav(tmp_path, name: str, y: np.ndarray, sr: int = SR) -> Path:
    path = Path(tmp_path) / name
    sf.write(str(path), y, sr)
    return path


@pytest.fixture(name="click_track")
def click_track_fixture():
    return click_track


@pytest.fixture(name="chord_tone")
def chord_tone_fixture():
    return chord_tone


@pytest.fixture(name="write_wav")
def write_wav_fixture():
    return write_wav
