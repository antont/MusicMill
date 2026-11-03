import numpy as np

from tests.conftest import chord_tone, click_track, write_wav


def test_click_track_length_and_accents():
    y = click_track(120, 10.0, accent_offset=2)
    assert len(y) == 10 * 22050
    beat = int(0.5 * 22050)
    peaks = [np.abs(y[i*beat:i*beat+200]).max() for i in range(8)]
    assert peaks[2] > 3 * peaks[1] and peaks[6] > 3 * peaks[5]


def test_chord_tone_is_tonal():
    y = chord_tone("A", "minor", 4.0)
    assert np.abs(y).max() <= 1.0 and np.abs(y).max() > 0.1
