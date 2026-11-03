import librosa
import pytest

from analyze_library import estimate_key
from build_phrase_graph import key_distance, normalize_key
from tests.conftest import chord_tone


@pytest.mark.parametrize("root,mode,expected", [("C", "major", "C"), ("A", "minor", "Am"),
                                                ("F#", "minor", "F#m"), ("E", "major", "E")])
def test_estimate_key_on_triads(root, mode, expected):
    y = chord_tone(root, mode, 6.0)
    chroma = librosa.feature.chroma_cqt(y=y, sr=22050)
    assert estimate_key(chroma.mean(axis=1)) == expected


def test_normalize_key():
    assert normalize_key("Db") == "C#" and normalize_key("bbm") == "A#m" and normalize_key("G#") == "G#"
    assert normalize_key("H") is None and normalize_key(None) is None


@pytest.mark.parametrize("a,b,d", [("C", "C", 0), ("Db", "C#", 0), ("C", "G", 1), ("C", "Am", 1), ("C#", "G#", 1),
                                    ("C", "F#", 6), ("C#", "G", 6), ("C", "Em", 2), (None, "C", 3)])
def test_key_distance(a, b, d):
    assert key_distance(a, b) == d and key_distance(b, a) == d
