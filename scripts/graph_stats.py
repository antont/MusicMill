#!/usr/bin/env python3
"""Print summary statistics for a HyperMusic phrase graph (v2.0 JSON)."""

import argparse
import json
import statistics
from collections import Counter
from pathlib import Path

DEFAULT_GRAPH = Path.home() / "Documents/MusicMill/PhraseGraph/phrase_graph.json"


def graph_stats(graph: dict) -> dict:
    nodes = graph.get("nodes", [])
    track_of = {n["id"]: n["sourceTrack"] for n in nodes}
    links = [(n, l) for n in nodes for l in n.get("links", [])]

    # A node is "zero-cross" when none of its links leads to another track.
    zero_cross = sum(
        1 for n in nodes
        if not any(track_of.get(l["targetId"], n["sourceTrack"]) != n["sourceTrack"]
                   for l in n.get("links", [])))
    same = sum(1 for n, l in links
               if track_of.get(l["targetId"]) == n["sourceTrack"])
    weights = [l["weight"] for _, l in links]
    energies = [n["energy"] for n in nodes]

    return {
        "nodes": len(nodes),
        "tracks": len(set(track_of.values())),
        "zero_cross_nodes": zero_cross,
        "same_track_link_ratio": same / len(links) if links else 0.0,
        "transition_counts": dict(Counter(l["suggestedTransition"] for _, l in links)),
        "weight_min": min(weights) if weights else 0.0,
        "weight_median": statistics.median(weights) if weights else 0.0,
        "weight_max": max(weights) if weights else 0.0,
        "energy_min": min(energies) if energies else 0.0,
        "energy_max": max(energies) if energies else 0.0,
    }


def main():
    parser = argparse.ArgumentParser(description="Phrase graph statistics")
    parser.add_argument("graph", nargs="?", default=str(DEFAULT_GRAPH))
    args = parser.parse_args()
    with open(Path(args.graph).expanduser()) as f:
        graph = json.load(f)
    for key, value in graph_stats(graph).items():
        print(f"{key}: {value:.3f}" if isinstance(value, float) else f"{key}: {value}")


if __name__ == "__main__":
    main()
