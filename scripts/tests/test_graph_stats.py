from graph_stats import graph_stats


def link(target, weight, transition="crossfade", seq=False):
    return {"targetId": target, "weight": weight, "suggestedTransition": transition,
            "isOriginalSequence": seq}


def toy_graph():
    return {"version": "2.0", "nodes": [
        {"id": "a0", "sourceTrack": "A", "energy": 0.0,
         "links": [link("a1", 1.0, "cut", True), link("b0", 0.6)]},
        {"id": "a1", "sourceTrack": "A", "energy": 0.5,
         "links": [link("a0", 0.8, "fade")]},          # same-track only: zero-cross
        {"id": "b0", "sourceTrack": "B", "energy": 1.0,
         "links": [link("a0", 0.7), link("a1", 0.9, "cut")]},
    ]}


def test_graph_stats_counts():
    s = graph_stats(toy_graph())
    assert s["nodes"] == 3
    assert s["tracks"] == 2
    assert s["zero_cross_nodes"] == 1
    assert s["same_track_link_ratio"] == 0.4
    assert s["transition_counts"] == {"crossfade": 2, "cut": 2, "fade": 1}
    assert (s["weight_min"], s["weight_median"], s["weight_max"]) == (0.6, 0.8, 1.0)
    assert (s["energy_min"], s["energy_max"]) == (0.0, 1.0)


def test_empty_graph():
    s = graph_stats({"nodes": []})
    assert s["nodes"] == 0 and s["tracks"] == 0 and s["transition_counts"] == {}
