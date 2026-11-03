import json
from pathlib import Path

import pytest

from build_phrase_graph import (compute_all_links, extract_phrases_from_analysis,
                                normalize_phrase_energies, phrase_id, save_phrase_graph,
                                suggest_transition)

FIXTURE = Path(__file__).parent / "fixtures" / "analysis_small.json"


@pytest.fixture
def small_phrases():
    # Waveform generation is a separate step (generate_phrase_waveforms), so it is skipped here.
    return extract_phrases_from_analysis(json.load(open(FIXTURE)), Path("."))


@pytest.fixture
def small_graph(small_phrases):
    normalize_phrase_energies(small_phrases)
    return compute_all_links(small_phrases)


def test_phrase_ids_are_stable():
    assert phrase_id("/a.mp3", 3) == phrase_id("/a.mp3", 3) != phrase_id("/a.mp3", 4)
    assert len(phrase_id("/a.mp3", 0)) == 16


def test_extracted_ids_are_deterministic(small_phrases):
    again = extract_phrases_from_analysis(json.load(open(FIXTURE)), Path("."))
    assert [p.id for p in small_phrases] == [p.id for p in again]
    assert len({p.id for p in small_phrases}) == len(small_phrases) == 24


def test_energy_normalized_to_unit_range(small_phrases):
    normalize_phrase_energies(small_phrases)
    e = [p.energy for p in small_phrases]
    assert min(e) >= 0 and max(e) <= 1 and max(e) > 0.9 and min(e) < 0.1


def test_constant_energy_maps_to_half(small_phrases):
    for p in small_phrases:
        p.energy = 0.07
    normalize_phrase_energies(small_phrases)
    assert all(p.energy == 0.5 for p in small_phrases)


def test_every_phrase_with_compatible_cross_tracks_gets_cross_links(small_graph):
    nodes = {p.id: p for p in small_graph}
    for p in small_graph:
        cross = [l for l in p.links if nodes[l.targetId].sourceTrack != p.sourceTrack]
        assert len(cross) >= 1
        assert len(cross) <= 12
        assert all(l.weight >= 0.5 for l in cross)
        same = [l for l in p.links if not l.isOriginalSequence and nodes[l.targetId].sourceTrack == p.sourceTrack]
        assert len(same) <= 2


def test_original_sequence_link_present(small_graph):
    nodes = {p.id: p for p in small_graph}
    for p in small_graph:
        seq = [l for l in p.links if l.isOriginalSequence]
        if p.trackIndex < 3:
            assert len(seq) == 1
            t = nodes[seq[0].targetId]
            assert t.sourceTrack == p.sourceTrack and t.trackIndex == p.trackIndex + 1
        else:
            assert seq == []


def test_transition_types_follow_component_scores():
    assert suggest_transition({"tempo": .3, "key": 1, "energy": 1, "spectral": 1}, 0) == "cut"
    assert suggest_transition({"tempo": 1, "key": .2, "energy": 1, "spectral": 1}, 0) == "filter"
    assert suggest_transition({"tempo": 1, "key": 1, "energy": .5, "spectral": 1}, .4) == "eqSwap"
    assert suggest_transition({"tempo": 1, "key": 1, "energy": 1, "spectral": 1}, .1) == "crossfade"


def test_saved_graph_schema(tmp_path, small_graph):
    out = tmp_path / "g.json"
    save_phrase_graph(small_graph, "/lib", out)
    g = json.load(open(out))
    assert g["version"] == "2.0" and all(len(n["id"]) == 16 for n in g["nodes"])
    for n in g["nodes"]:
        assert all(0 <= b <= n["duration"] + 0.01 for b in n["downbeats"])  # phrase-relative
        assert all(0 <= b <= n["duration"] + 0.01 for b in n["beats"])


def test_fixture_graph_exercises_several_transition_types(small_graph):
    types = {l.suggestedTransition for p in small_graph for l in p.links if not l.isOriginalSequence}
    # The spec asks that the non-crossfade transitions actually occur, not just exist in code.
    assert {"eqSwap", "filter", "cut"} <= types, types
