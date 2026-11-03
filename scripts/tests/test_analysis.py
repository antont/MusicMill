import numpy as np

import analyze_library
from analyze_library import analyze_track, estimate_downbeats, main
from tests.conftest import click_track, write_wav


def test_estimate_downbeats_finds_accent_phase():
    beats = np.arange(32) * 0.5
    strength = np.ones(32)
    strength[2::4] = 5.0
    assert np.allclose(estimate_downbeats(beats, strength), beats[2::4])


def test_analyze_track_downbeats_follow_accents(tmp_path):
    path = write_wav(tmp_path, "c.wav", click_track(120, 40.0, accent_offset=1))
    t = analyze_track(path)
    assert abs(t["downbeats"][0] - 0.5) < 0.05  # beat index 1 at 120 BPM
    assert len(t["downbeats"]) >= 15 and "beats" in t


def test_first_phrase_starts_at_zero_when_downbeat_near_zero(tmp_path):
    path = write_wav(tmp_path, "c.wav", click_track(120, 40.0, accent_offset=0))
    assert analyze_track(path)["segments"][0]["start"] == 0.0


def test_json_argument_without_u_is_not_update_mode(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(analyze_library, "analyze_directory",
                        lambda *a, **k: calls.append("analyze"))
    monkeypatch.setattr(analyze_library, "update_existing_analysis",
                        lambda *a, **k: calls.append("update"))
    # A directory whose name ends in .json: the suffix must not select update mode.
    target = tmp_path / "x.json"
    target.mkdir()

    main([str(target)])
    assert calls == ["analyze"]

    # -u is the only switch into update mode.
    calls.clear()
    (tmp_path / "y.json").write_text("{}")
    main([str(tmp_path / "y.json"), "-u"])
    assert calls == ["update"]


def test_first_phrase_is_not_a_sliver_when_downbeat_slightly_after_zero(tmp_path):
    path = write_wav(tmp_path, "c.wav", click_track(120, 40.0, accent_offset=0, first_beat=0.3))
    seg = analyze_track(path)["segments"][0]
    assert seg["start"] == 0.0
    assert seg["end"] >= 2.0  # at least one bar at 120 BPM
