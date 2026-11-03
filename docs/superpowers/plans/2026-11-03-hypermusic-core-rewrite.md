# HyperMusic Core Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MusicMill's HyperMusic playback with a test-driven, real-time-safe two-deck DJ core (`HyperCore` package) plus a corrected phrase-graph pipeline, keeping the legacy tabs compiling and untouched.

**Architecture:**
- A local Swift package `HyperCore` contains five layers:
  - pure graph model and navigation
  - pure DSP (deck, EQ, mixer) rendered offline in tests
  - a lock-free command/snapshot bridge
  - a single-`AVAudioEngine` I/O host that maps a 4-channel (master L/R, cue L/R) mix onto devices
  - a `@MainActor @Observable` `HyperSession` that owns the workflow and the "centre" display/logging rule
- The SwiftUI HyperMusic tab is a thin view over `HyperSession`.
- The Python pipeline is fixed under `pytest`.

**Tech Stack:**
- Swift 6.2 in Swift 6 language mode, Swift Testing, AVFoundation/CoreAudio, `Synchronization.Atomic`, SQLite3, macOS 15.6
- Python 3.12, librosa, numpy, pytest

**Spec:** `docs/superpowers/specs/2026-11-03-hypermusic-core-rewrite-design.md`. Read it first. Its "Known defects" section lists what this plan must eliminate.

## Global Constraints

- **Toolchain:** deployment target macOS 15.6. Xcode 26 / Swift 6.2. `HyperCore` uses `swift-tools-version: 6.0`, `platforms: [.macOS("15.6")]`, Swift 6 language mode.
- **Graph files stay** at `~/Documents/MusicMill/PhraseGraph/phrase_graph.json` and `~/Documents/MusicMill/relationships.db`. Graph JSON `version` becomes `"2.0"`. Any older major version must produce `GraphError.unsupportedVersion`, whose message says to rebuild with `scripts/build_phrase_graph.py`.
- **Render thread rules:**
  - no locks, allocation, `print`/logging, Objective-C messaging, or main-thread dispatch
  - no Swift class retain/release whose release could free memory
  - only `Unmanaged`, raw pointers, value types and `Atomic`
- **Audio thread is not the source of UI truth.** The audio thread never decides UI state. The "current phrase" is derived on the main actor from polled positions.
- **Hermetic tests.** Tests never touch `~/Music`, `~/Documents/MusicMill`, or the RAVE venv. Fixtures are synthesized in-test or live under `Tests/.../Fixtures` and `scripts/tests/fixtures`.
- **Mixer output** is 4 channels in order: master L, master R, cue L, cue R.
- **Time conventions:**
  - `PhraseNode.beats` and `.downbeats` are **phrase-relative** seconds, so song time = `startTime + beat`.
  - Deck positions are song-absolute frames at the engine sample rate.
- **Legacy left untouched:** Prep, Phrase, Granular, RAVE and Training tabs. They only get the import/move edits needed to compile.
- **Out of scope:** time-stretch, sync, a track browser, and MIDI/HID.

## Review Focus

1. **Cue device unplugged mid-session.** The engine must keep playing master and fall back to `.stereo(master)` routing without crashing or silently stopping. Test: Task 16 `configurationChangeWithMissingCueFallsBackToStereo`.
2. **Output sample rate changes**, for example plugging in a 48 kHz interface. Pitch and tempo must be unchanged. Loaded decks are re-decoded at the new rate and keep their position in seconds. Test: Task 18 `sampleRateChangeRedecodesAndKeepsPositionSeconds`.
3. **Missing, moved or DRM-protected audio file in the graph.** The deck shows a load error and the other deck keeps playing. Test: Task 18 `failedLoadSetsDeckErrorAndSendsNoCommand`.
4. **Loading a branch onto a deck that is audible on master** would cut live audio. It is refused with a message, like DJ hardware's deck lock. Test: Task 18 `loadBranchRefusedWhenTargetDeckIsAudible`.
5. **Phrase with no beat or downbeat data.** Quantized start falls back to the next phrase boundary, and then to an immediate start. Test: Task 18 `quantizedStartWithoutDownbeatsFallsBack`.

Also pinned:
- the track cache never evicts a track loaded on a deck (Task 11 `pinnedTracksAreNeverEvicted`)
- an old graph gives a clear error (Task 7)

---

## Part A — Cleanup

### Task 1: Remove dead code, isolate legacy, make the default test run hermetic

**Files:**
- Delete:
  - `MusicMill/Analysis/StructureAnalyzer.swift`, `SegmentExtractor.swift`, `RekordboxParser.swift`, `SpectralAnalyzer.swift`, `QualityAnalyzer.swift`, `RunAnalysis.swift`
  - `MusicMill/Generation/NeuralGenerator.swift`, `SampleGenerator.swift`, `SegmentMatcher.swift`, `ConcatenativeSynthesizer.swift`
  - `MusicMill/ML/GenerativeModelTrainer.swift`
  - `MusicMill/Performance/PerformanceView.swift`, `GenerationController.swift`, `MixingEngine.swift`, `PlaybackController.swift`, `StyleController.swift`, `TrackSelector.swift`, `DJMixerView.swift`, `WaveformPerformanceTest.swift`, `WaveformPerformanceBenchmark.swift`
  - `default.profraw` from git
- Move to `MusicMill/Legacy/` (git mv, no content changes): `MusicMill/Audio/Deck.swift`, `AudioRouter.swift`, `ThreeBandEQ.swift`
- Modify:
  - `MusicMillTests/MusicMillTests.swift`: delete the tests of deleted types. Replace every silent `return` on missing data with `throw XCTSkip("…")`.
  - `MusicMill/Analysis/PhraseDatabase.swift`: delete `getAdjustedLinks`, `getAdjustedAlternatives`, `getTopRatedTransitions`, `getRecentTransitions`.
  - `MusicMill/Analysis/AnalysisStorage.swift`: delete `loadLibrosaAnalysis`, `mergeLibrosaAnalysis`.
  - `MusicMill/Generation/SynthesisEngine.swift`: delete `loadPhrasesFromAnalysis` and the `.concatenative` case with its uses.
  - `.gitignore`: add `*.profraw`, `scripts/.venv/`, `Packages/*/.build/`.

The project uses Xcode 16+ synchronized folders (`PBXFileSystemSynchronizedRootGroup`), so file deletions and moves need no `project.pbxproj` edits. If a deleted file appears in a `membershipExceptions` list, remove that entry.

- [ ] **Step 1: Re-verify each deletion candidate is unreferenced.** For each type, run `grep -rnw '<TypeName>' MusicMill MusicMillTests` and confirm the only hits are its own file and tests being deleted. If a legacy tab still references one, keep it and note it in the commit message.
- [ ] **Step 2: Delete, move and edit as listed above.**
- [ ] **Step 3: Build.** Run `xcodebuild -project MusicMill.xcodeproj -scheme MusicMill -destination 'platform=macOS' build 2>&1 | tail -3`. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Run tests.** Run `xcodebuild -project MusicMill.xcodeproj -scheme MusicMill -destination 'platform=macOS' test 2>&1 | grep -E "Executed|skipped|TEST"`. Expected: `** TEST SUCCEEDED **`. Machine-specific tests are reported as skipped when their data is absent, not passed.
- [ ] **Step 5: Commit.**

```bash
git add -A MusicMill MusicMillTests .gitignore && git rm --cached -q default.profraw
git commit -m "Remove dead code, move legacy decks under Legacy/, skip machine-specific tests explicitly"
```

---

## Part B — Python graph pipeline

Part B is independent of Parts C–D and can run in parallel. Python commands use `scripts/.venv/bin/python` and `scripts/.venv/bin/pytest`.

### Task 2: Python test harness and synthetic audio fixtures

**Files:**
- Create: `scripts/requirements.txt` (`librosa>=0.10`, `numpy`, `soundfile`, `pytest`)
- Create: `scripts/tests/__init__.py`, `scripts/tests/conftest.py`, `scripts/tests/test_fixtures.py`
- Create: `scripts/pytest.ini` (`[pytest]` with `pythonpath = .` and `testpaths = tests`)

**Interfaces — Produces** (in `conftest.py`, as plain functions plus pytest fixtures with the same names):
- `click_track(bpm: float, seconds: float, sr: int = 22050, accent_every: int = 4, accent_offset: int = 0, first_beat: float = 0.0) -> np.ndarray`. Clicks on every beat; the beat with index `accent_offset + k*accent_every` is 4× louder and has a 60 Hz thump.
- `chord_tone(root: str, mode: str, seconds: float, sr: int = 22050) -> np.ndarray`. A sustained triad with mode `"major"` or `"minor"`, plus a low-root drone.
- `write_wav(tmp_path, name: str, y: np.ndarray, sr: int = 22050) -> Path`

- [ ] **Step 1: Create the venv.** Run `/opt/homebrew/bin/python3.12 -m venv scripts/.venv && scripts/.venv/bin/pip install -q -r scripts/requirements.txt`. Expected: exits 0.
- [ ] **Step 2: Write the failing tests** in `test_fixtures.py`:

```python
def test_click_track_length_and_accents():
    y = click_track(120, 10.0, accent_offset=2)
    assert len(y) == 10 * 22050
    beat = int(0.5 * 22050)
    peaks = [np.abs(y[i*beat:i*beat+200]).max() for i in range(8)]
    assert peaks[2] > 3 * peaks[1] and peaks[6] > 3 * peaks[5]

def test_chord_tone_is_tonal():
    y = chord_tone("A", "minor", 4.0)
    assert np.abs(y).max() <= 1.0 and np.abs(y).max() > 0.1
```

- [ ] **Step 3: Run to fail.** Run `cd scripts && .venv/bin/pytest tests/test_fixtures.py -q`. Expected: FAIL (NameError / ImportError).
- [ ] **Step 4: Implement** the `conftest.py` helpers.
- [ ] **Step 5: Run to pass.** Same command. Expected: `2 passed`.
- [ ] **Step 6: Commit.** Run `git add scripts/requirements.txt scripts/pytest.ini scripts/tests && git commit -m "Add pytest harness with synthetic audio fixtures"`.

### Task 3: Key detection (major/minor) and circle-of-fifths distance

**Files:**
- Modify:
  - `scripts/analyze_library.py:134-140`: replace the strongest-bin key with `estimate_key`
  - `scripts/build_phrase_graph.py:48-49, 160-222`: `normalize_key`, `key_distance`, `compute_key_score`
- Test: `scripts/tests/test_key.py`

**Key format** (decided): a sharp-only tonic plus `"m"` for minor, for example `"C"`, `"F#m"`. Legacy bare tonics such as `"G#"` from old analyses are read as major. Flats are normalized to sharps, so `"Db"` becomes `"C#"` and `"Bbm"` becomes `"A#m"`.

**Interfaces — Produces:**
- `analyze_library.estimate_key(chroma_mean: np.ndarray) -> str`. Uses Krumhansl–Kessler major/minor profiles, correlated across all 12 rotations, best of 24.
- `build_phrase_graph.normalize_key(key: Optional[str]) -> Optional[str]`. Returns the canonical format above; `None` for unparseable keys.
- `build_phrase_graph.key_distance(k1, k2) -> int`, in the range 0–7. Map each key to Camelot `(number 1–12, letter A=minor/B=major)`. The distance is the circular number difference (0–6), plus 1 if the letters differ and the numbers differ. Same number with a different letter (relative major/minor) counts as distance 1. Unknown → 3.
- `compute_key_score` keeps its table `[1.0, 0.9, 0.8, 0.6, 0.4, 0.2, 0.1]`, indexed by `min(dist, 6)`.

- [ ] **Step 1: Write the failing tests:**

```python
from analyze_library import estimate_key
from build_phrase_graph import normalize_key, key_distance
import librosa, numpy as np

@pytest.mark.parametrize("root,mode,expected", [("C","major","C"), ("A","minor","Am"), ("F#","minor","F#m"), ("E","major","E")])
def test_estimate_key_on_triads(root, mode, expected):
    y = chord_tone(root, mode, 6.0)
    chroma = librosa.feature.chroma_cqt(y=y, sr=22050)
    assert estimate_key(chroma.mean(axis=1)) == expected

def test_normalize_key():
    assert normalize_key("Db") == "C#" and normalize_key("bbm") == "A#m" and normalize_key("G#") == "G#"
    assert normalize_key("H") is None and normalize_key(None) is None

@pytest.mark.parametrize("a,b,d", [("C","C",0), ("Db","C#",0), ("C","G",1), ("C","Am",1), ("C#","G#",1),
                                    ("C","F#",6), ("C#","G",6), ("C","Em",2), (None,"C",3)])
def test_key_distance(a, b, d):
    assert key_distance(a, b) == d and key_distance(b, a) == d
```

- [ ] **Step 2: Run to fail.** Run `cd scripts && .venv/bin/pytest tests/test_key.py -q`. Expected: FAIL. `estimate_key` is missing, and `("C#","G")` currently returns 0.
- [ ] **Step 3: Implement** `estimate_key`, `normalize_key`, `key_distance`, and use `estimate_key` in `analyze_track`.
- [ ] **Step 4: Run to pass.** Run `.venv/bin/pytest -q`. Expected: all pass.
- [ ] **Step 5: Commit.** Run `git commit -am "Fix key detection (major/minor) and circle-of-fifths distance"`. Add the new test file first.

### Task 4: Downbeat phase, phrase start, and the analysis output format

**Files:**
- Modify: `scripts/analyze_library.py` (`detect_phrases_and_segments` at `:157-175`, `analyze_track`, `update_existing_analysis`, `main` at `:449+`)
- Test: `scripts/tests/test_analysis.py`

**Interfaces — Produces:**
- `estimate_downbeats(beat_times: np.ndarray, strength_at_beats: np.ndarray, beats_per_bar: int = 4) -> np.ndarray`. Picks the phase `p ∈ {0..3}` that maximizes the mean of `strength_at_beats[p::4]` and returns `beat_times[p::4]`. The strength is the onset strength plus the low-band (<150 Hz) RMS, sampled at each beat.
- `detect_phrases_and_segments(y, sr, beat_times, downbeats, rms, rms_times)` takes `downbeats` as a parameter. The first phrase starts at `downbeats[0]`, or at `0.0` if `downbeats[0] <= 0.5`.
- Output format, for both full and `-u` update mode:
  - each track entry carries `beats` and `downbeats` at the same level as `tempo`, the format `build_phrase_graph.extract_phrases_from_analysis` reads
  - `-u` is the *only* switch into update mode, so a `.json` positional argument no longer implies it
  - the `analysis_version` field becomes `"2"`

- [ ] **Step 1: Write the failing tests:**

```python
def test_estimate_downbeats_finds_accent_phase():
    beats = np.arange(32) * 0.5
    strength = np.ones(32); strength[2::4] = 5.0
    assert np.allclose(estimate_downbeats(beats, strength), beats[2::4])

def test_analyze_track_downbeats_follow_accents(tmp_path):
    path = write_wav(tmp_path, "c.wav", click_track(120, 40.0, accent_offset=1))
    t = analyze_track(path)
    assert abs(t["downbeats"][0] - 0.5) < 0.05   # beat index 1 at 120 BPM
    assert len(t["downbeats"]) >= 15 and "beats" in t

def test_first_phrase_starts_at_zero_when_downbeat_near_zero(tmp_path):
    path = write_wav(tmp_path, "c.wav", click_track(120, 40.0, accent_offset=0))
    assert analyze_track(path)["segments"][0]["start"] == 0.0

def test_json_argument_without_u_is_not_update_mode(tmp_path, monkeypatch):
    # main(["x.json"]) must call analyze_directory, not update_existing_analysis
    ...  # monkeypatch both functions with recorders and assert which ran
```

- [ ] **Step 2: Run to fail.** Run `.venv/bin/pytest tests/test_analysis.py -q`. Expected: FAIL.
- [ ] **Step 3: Implement.** Make `main` accept `argv: Optional[list[str]] = None` so it can be tested.
- [ ] **Step 4: Run to pass.** Run `.venv/bin/pytest -q`. Expected: all pass.
- [ ] **Step 5: Commit.** Run `git add scripts && git commit -m "Estimate downbeat phase, fix first phrase start and update-mode CLI"`.

### Task 5: Graph builder — stable IDs, normalized energy, link budget, transitions, schema 2.0

**Files:**
- Modify: `scripts/build_phrase_graph.py` (`:38-41` constants, `suggest_transition :366`, `extract_phrases_from_analysis :381`, `compute_all_links :585`, `save_phrase_graph :659`)
- Test: `scripts/tests/test_graph.py`, plus fixture `scripts/tests/fixtures/analysis_small.json` (6 tracks × 4 segments). Write it by hand with varied tempo, key and energy so that compatible cross-track pairs exist.

**Interfaces — Produces:**
- `phrase_id(track_path: str, index: int) -> str`: `sha1(f"{track_path}\x00{index}").hexdigest()[:16]`.
- `normalize_phrase_energies(phrases: list[PhraseNode]) -> None`. Maps raw RMS through the library's 5th–95th percentile, clipped to [0, 1]. Constant input gives 0.5 for all.
- `compute_all_links(phrases, n_cross: int = 12, n_same: int = 2) -> list[PhraseNode]`. Each phrase gets:
  - its original-sequence link (`isOriginalSequence: True`)
  - the top `n_same` other same-track links
  - the top `n_cross` cross-track links by weight, each with weight ≥ `MIN_LINK_WEIGHT`

  Selection is per category. Precompute a `track → phrases` dict once, outside the pair loop.
- `suggest_transition(scores: dict, energy_diff: float) -> str`, decided from component scores, not the blended weight:
  - `"cut"` if `scores["tempo"] < 0.5`
  - else `"filter"` if `scores["key"] < 0.5`
  - else `"eqSwap"` if `abs(energy_diff) > 0.25`
  - else `"crossfade"`
- `MIN_LINK_WEIGHT = 0.5`. Tune it in Task 6 against real stats if needed.
- `save_phrase_graph` writes `"version": "2.0"`.

- [ ] **Step 1: Write the failing tests:**

```python
def test_phrase_ids_are_stable():
    assert phrase_id("/a.mp3", 3) == phrase_id("/a.mp3", 3) != phrase_id("/a.mp3", 4)
    assert len(phrase_id("/a.mp3", 0)) == 16

def test_energy_normalized_to_unit_range(small_phrases):
    normalize_phrase_energies(small_phrases)
    e = [p.energy for p in small_phrases]
    assert min(e) >= 0 and max(e) <= 1 and max(e) > 0.9 and min(e) < 0.1

def test_every_phrase_with_compatible_cross_tracks_gets_cross_links(small_graph):
    for p in small_graph:
        cross = [l for l in p.links if node(l.targetId).sourceTrack != p.sourceTrack]
        assert len(cross) >= 1
        same = [l for l in p.links if not l.isOriginalSequence and node(l.targetId).sourceTrack == p.sourceTrack]
        assert len(same) <= 2

def test_transition_types_follow_component_scores():
    assert suggest_transition({"tempo": .3, "key": 1, "energy": 1, "spectral": 1}, 0) == "cut"
    assert suggest_transition({"tempo": 1, "key": .2, "energy": 1, "spectral": 1}, 0) == "filter"
    assert suggest_transition({"tempo": 1, "key": 1, "energy": .5, "spectral": 1}, .4) == "eqSwap"
    assert suggest_transition({"tempo": 1, "key": 1, "energy": 1, "spectral": 1}, .1) == "crossfade"

def test_saved_graph_schema(tmp_path, small_graph):
    out = tmp_path / "g.json"; save_phrase_graph(small_graph, "/lib", out)
    g = json.load(open(out))
    assert g["version"] == "2.0" and all(len(n["id"]) == 16 for n in g["nodes"])
    for n in g["nodes"]:
        assert all(0 <= b <= n["duration"] + 0.01 for b in n["downbeats"])  # phrase-relative
```

`small_phrases` and `small_graph` are fixtures that load `analysis_small.json` through `extract_phrases_from_analysis` with waveforms skipped. `small_graph` also runs `normalize_phrase_energies` and `compute_all_links`.

- [ ] **Step 2: Run to fail.** Run `.venv/bin/pytest tests/test_graph.py -q`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to pass.** Run `.venv/bin/pytest -q`. Expected: all pass.
- [ ] **Step 5: Commit.** Run `git add scripts && git commit -m "Graph builder: stable IDs, normalized energy, per-category link budget, score-based transitions, schema 2.0"`.

### Task 6: Graph stats tool and rebuild of the real graph

**Files:**
- Create: `scripts/graph_stats.py`
- Test: `scripts/tests/test_graph_stats.py`

**Interfaces — Produces:** `graph_stats(graph: dict) -> dict` with these keys:
- `nodes`, `tracks`
- `zero_cross_nodes`
- `same_track_link_ratio`
- `transition_counts: dict[str, int]`
- `weight_min`, `weight_median`, `weight_max`
- `energy_min`, `energy_max`

The CLI prints them for a graph path, defaulting to `~/Documents/MusicMill/PhraseGraph/phrase_graph.json`.

- [ ] **Step 1: Write the failing test.** Build a 2-track toy graph dict and assert the exact counts, for example `zero_cross_nodes == 1` when one node has only sequence links.
- [ ] **Step 2: Run to fail, implement, run to pass.** Run `.venv/bin/pytest tests/test_graph_stats.py -q`.
- [ ] **Step 3: Rebuild the real graph.** This is the user's data, so back it up first:

```bash
cp ~/Documents/MusicMill/PhraseGraph/phrase_graph.json ~/Documents/MusicMill/PhraseGraph/phrase_graph.v1.backup.json
scripts/.venv/bin/python scripts/analyze_library.py ~/Music/PioneerDJ -o ~/Documents/MusicMill/Analysis/librosa_analysis.json
scripts/.venv/bin/python scripts/build_phrase_graph.py ~/Documents/MusicMill/Analysis/librosa_analysis.json
scripts/.venv/bin/python scripts/graph_stats.py
```

Before running, confirm the collection root against `collectionPath` in the backup.

Expected:
- `zero_cross_nodes` ≪ 171, with a target of 0 for tracks whose tempo is compatible with at least one other track
- `same_track_link_ratio` < 0.3
- at least 3 transition types present
- energy spanning about 0–1

If not, tune `MIN_LINK_WEIGHT` and `n_cross`, then re-run Task 5's tests.
- [ ] **Step 4: Commit** the tool and any tuned constants. Paste the stats output into the commit message.

---

## Part C — HyperCore package

All commands run from `Packages/HyperCore`: `swift test --filter <Suite>`. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).

### Task 7: Package scaffold, graph model, versioned loading, app integration

**Files:**
- Create: `Packages/HyperCore/Package.swift`. It declares the library product `HyperCore` and a test target `HyperCoreTests` with resources `.copy("Fixtures")`.
- Create: `Packages/HyperCore/Sources/HyperCore/Graph/GraphModel.swift`. Move `PhraseLink`, `TransitionType`, `WaveformData`, `PhraseNode` and `PhraseGraph` out of `MusicMill/Analysis/PhraseDatabase.swift`, and make them `public` and `Sendable`.
- Create: `Packages/HyperCore/Tests/HyperCoreTests/GraphModelTests.swift`, plus `Fixtures/graph_v2.json` (2 tracks × 3 phrases, beats/downbeats filled) and `Fixtures/graph_v1.json` (version `"1.1"`)
- Modify:
  - `MusicMill.xcodeproj/project.pbxproj`: add an `XCLocalSwiftPackageReference` (`relativePath = Packages/HyperCore`), an `XCSwiftPackageProductDependency` (`productName = HyperCore`), and link the product into the MusicMill app target's `packageProductDependencies` and Frameworks build phase. Doing it through Xcode's "Add Package Dependencies… → Add Local" is equivalent.
  - `git mv MusicMill/Analysis/PhraseDatabase.swift MusicMill/Legacy/PhraseDatabase.swift`, then add `import HyperCore`.
  - Add `import HyperCore` to every app file that uses the moved types: `grep -rlw 'PhraseNode\|PhraseLink\|PhraseGraph' MusicMill`.

**Interfaces — Produces:**
- `public struct PhraseGraph: Codable, Sendable` with:
  - `version: String`, `createdAt: Date`, `collectionPath: String`, `nodes: [PhraseNode]`
  - `public static func load(from url: URL) throws -> PhraseGraph`
  - `public static let supportedMajorVersion = 2`
  - `public static let defaultURL: URL`, pointing to `~/Documents/MusicMill/PhraseGraph/phrase_graph.json`
- `public enum GraphError: Error, Equatable, LocalizedError` with:
  - `.fileNotFound(URL)`
  - `.unsupportedVersion(found: String)`, whose `errorDescription` contains `"build_phrase_graph.py"`
  - `.decodingFailed(String)`
- `PhraseNode` keeps every field and JSON key unchanged. It adds `public func startFrame(sampleRate: Double) -> Int` and `public func songTime(ofPhraseRelative t: TimeInterval) -> TimeInterval`, which returns `(startTime ?? 0) + t`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func loadsV2Graph() throws {
    let g = try PhraseGraph.load(from: fixture("graph_v2.json"))
    #expect(g.nodes.count == 6)
    #expect(g.nodes[0].songTime(ofPhraseRelative: 1.0) == (g.nodes[0].startTime ?? 0) + 1.0)
}
@Test func rejectsV1GraphWithRebuildMessage() {
    #expect(throws: GraphError.unsupportedVersion(found: "1.1")) { try PhraseGraph.load(from: fixture("graph_v1.json")) }
    #expect(GraphError.unsupportedVersion(found: "1.1").localizedDescription.contains("build_phrase_graph.py"))
}
@Test func parsesPythonIsoDatesWithMicroseconds() throws {
    // graph_v2.json createdAt = "2025-12-25T23:08:27.476161+02:00"
    let g = try PhraseGraph.load(from: fixture("graph_v2.json"))
    #expect(abs(g.createdAt.timeIntervalSince1970 - 1766696907.476) < 0.01)
}
@Test func missingFileThrowsFileNotFound() { /* URL in temp dir */ }
```

Use `fixture(_ name: String) -> URL` via `Bundle.module`. Put it in `Tests/HyperCoreTests/TestSupport.swift`.

The graph JSON stores `version` first, so read the version before full decoding: decode a `struct VersionProbe: Decodable { let version: String }` first.

- [ ] **Step 2: Run to fail.** Run `swift test --filter GraphModelTests`. Expected: compile failure, `PhraseGraph.load` missing.
- [ ] **Step 3: Implement** the model move and `load(from:)`, with flexible ISO-8601 parsing that handles microseconds via `Date.ISO8601FormatStyle` and falls back to a `DateFormatter` with `"yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"`.
- [ ] **Step 4: Run to pass.** Run `swift test --filter GraphModelTests`. Expected: 4 passed.
- [ ] **Step 5: Wire up the app.** Make the pbxproj and import edits. Run the `xcodebuild … build` from Task 1. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Commit.** Run `git add -A Packages MusicMill MusicMill.xcodeproj && git commit -m "Add HyperCore package with versioned phrase graph model"`.

### Task 8: GraphNavigator

**Files:**
- Create: `Sources/HyperCore/Graph/GraphNavigator.swift`
- Test: `Tests/HyperCoreTests/GraphNavigatorTests.swift`

**Interfaces:**
- Consumes: `PhraseGraph`, `PhraseNode`, `PhraseLink` (Task 7)
- Produces:
  - `public struct Branch: Sendable, Identifiable { public let from: PhraseNode; public let to: PhraseNode; public let link: PhraseLink; public let score: Double; public var id: String }`, where `id` is `"\(from.id)->\(to.id)"`
  - `public final class GraphNavigator: Sendable`, built with `init(graph: PhraseGraph)`. It precomputes the ID index, per-track ordered phrase arrays and per-track start-time arrays. Methods:
    - `phrase(id:) -> PhraseNode?`
    - `phrases(inTrack path: String) -> [PhraseNode]`, ordered by `trackIndex`
    - `phrase(atSongTime t: TimeInterval, inTrack path: String) -> PhraseNode?`: binary search. Before the first phrase → first; after the last → last.
    - `nextInSequence(after id: String) -> PhraseNode?`
    - `branches(from id: String, limit: Int, adjust: (PhraseLink, _ fromId: String) -> Double = { l, _ in l.weight }) -> [Branch]`: cross-track only, sorted by `score` descending
    - `energyNeighbours(of id: String, higher: Bool, limit: Int) -> [PhraseNode]`: cross-track link targets with energy higher (or lower) than the source, closest first
    - `randomStart() -> PhraseNode?`: a `trackIndex == 0` phrase, using an injectable `RandomNumberGenerator` overload

- [ ] **Step 1: Write the failing tests** against `graph_v2.json`:
  - `phraseAtSongTimeUsesBoundaries`: time exactly at phrase 1's `startTime` returns phrase 1, and `startTime - 0.001` returns phrase 0.
  - `branchesExcludeSameTrackAndSortByAdjustedScore`: with `adjust` returning `1 - weight`, the order reverses.
  - `nextInSequenceFollowsTrackIndex`
  - `energyNeighboursFilterDirection`
  - `unknownIdsReturnEmpty`
- [ ] **Step 2: Run to fail.** Run `swift test --filter GraphNavigatorTests`. Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to pass.**
- [ ] **Step 5: Commit.** Message: `"Add GraphNavigator"`.

### Task 9: RelationshipDatabase moves into HyperCore; manual ratings count

**Files:**
- Move: `git mv MusicMill/Data/RelationshipDatabase.swift Packages/HyperCore/Sources/HyperCore/Feedback/RelationshipDatabase.swift`. Make the API used by app files `public`. Add `import HyperCore` in `PreparationView.swift` and `HyperPhraseView.swift`; the latter is deleted later.
- Modify:
  - Add `public init(url: URL)`, keeping a convenience `init()` that uses `~/Documents/MusicMill/relationships.db`.
  - The `getFeedback` count query (`:606-609`) must count `action IN ('played','rated')` from any source. Check the `EventAction` raw value used by `logRating` and match it exactly.
- Test: `Tests/HyperCoreTests/RelationshipDatabaseTests.swift`, with each test using a fresh temp file.

**Interfaces — Produces** (public): `open()`, `close()`, `logPlayed(from:to:source:context:)`, `logRating(from:to:rating:source:)`, `adjustedWeight(baseWeight:from:to:) -> Double`, `startSession(type:)`, `endSession(notes:)`, plus whatever else the app uses.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func noEventsReturnsBaseWeight() throws { #expect(try db.adjustedWeight(baseWeight: 0.7, from: "a", to: "b") == 0.7) }
@Test func manualRatingChangesWeight() throws {
    try db.logRating(from: "a", to: "b", rating: 1, source: .manual)
    #expect(try db.adjustedWeight(baseWeight: 0.5, from: "a", to: "b") > 0.5)
}
@Test func negativeRatingLowersWeight() throws { /* rating -1 → < base */ }
@Test func playedEventsArePersistedAcrossReopen() throws { /* logPlayed, close, reopen same url, getFeedback count == 1 */ }
```

- [ ] **Step 2: Run to fail.** Run `swift test --filter RelationshipDatabaseTests`. Expected: `manualRatingChangesWeight` fails, because the weight is unchanged.
- [ ] **Step 3: Implement** the move, the public API and the query fix.
- [ ] **Step 4: Run to pass.** Then run the app `xcodebuild … build`. Expected: both succeed.
- [ ] **Step 5: Commit.** Message: `"Move RelationshipDatabase into HyperCore; count manual ratings in adjusted weights"`.

### Task 10: Real-time bridge — SPSC queue and snapshot box

**Files:**
- Create: `Sources/HyperCore/Realtime/SPSCQueue.swift`, `Sources/HyperCore/Realtime/SnapshotBox.swift`
- Test: `Tests/HyperCoreTests/RealtimeBridgeTests.swift`

**Interfaces — Produces:**
- `public final class SPSCQueue<Element>: @unchecked Sendable` with:
  - `init(capacity: Int)`, where capacity is rounded up to a power of two
  - `func push(_ e: Element) -> Bool`, which returns false when full and never blocks
  - `func pop() -> Element?`
  - `var isEmpty: Bool`
  - Storage is a preallocated `UnsafeMutablePointer<Element?>`. Head and tail are `Atomic<Int>` with acquire/release ordering.
- `public final class SnapshotBox<T: BitwiseCopyable>: @unchecked Sendable` with:
  - `init(_ initial: T)`
  - `func write(_ v: T)`, called by the single writer (audio)
  - `func read() -> T`, called by any reader and never torn
  - Use a seqlock: an `Atomic<UInt64>` sequence, with the reader retrying while the sequence is odd or changed.

- [ ] **Step 1: Write the failing tests:**
  - `fifoOrder`
  - `pushFailsWhenFull`: capacity 4 accepts exactly 4.
  - `concurrentProducerConsumerPreservesOrder`: 1,000,000 Ints, producer and consumer on two `Thread`s, and the consumer sees 0..<1_000_000 in order.
  - `snapshotNeverTorn`: `struct Pair { var a: Int; var b: Int }`, with the writer looping `write(Pair(a: i, b: i))` and the reader asserting `a == b` over 1,000,000 reads.
- [ ] **Step 2: Run to fail.** Run `swift test --filter RealtimeBridgeTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to pass.** Also run once with `swift test -c release --filter RealtimeBridgeTests`, so the races are exercised with optimizations. Then run with `--sanitize=thread`. Expected: no TSan reports.
- [ ] **Step 5: Commit.** Message: `"Add lock-free SPSC queue and seqlock snapshot"`.

### Task 11: AudioTrack, decoding, and the pinned LRU cache

**Files:**
- Create:
  - `Sources/HyperCore/Audio/AudioTrack.swift`
  - `Sources/HyperCore/Audio/TrackDecoder.swift`
  - `Sources/HyperCore/Audio/TrackCache.swift`
  - `Sources/HyperCore/Audio/TrackLoading.swift`
- Test: `Tests/HyperCoreTests/TrackLoadingTests.swift`. Tests write temporary WAVs with `AVAudioFile`.

**Interfaces — Produces:**
- `public final class AudioTrack: @unchecked Sendable` with:
  - `let url: URL`, `let sampleRate: Double`, `let frameCount: Int`
  - `let left: UnsafeMutablePointer<Float>`, `let right: UnsafeMutablePointer<Float>`, freed in `deinit`
  - `init(url:sampleRate:left:[Float],right:[Float])` for tests and synthesis
  - `var byteSize: Int`
- `public protocol TrackLoading: Sendable { func track(for url: URL, sampleRate: Double) async throws -> AudioTrack }`
- `public struct TrackDecoder: TrackLoading`. Decodes with `AVAudioFile` plus an `AVAudioConverter` to deinterleaved Float32 stereo at `sampleRate`:
  - Feed the input once, then return `.endOfStream`.
  - Loop `convert` until it reports `.endOfStream`, so the tail is flushed.
  - Mono is duplicated to both channels.
  - Errors: `TrackLoadError.fileNotFound(URL)` and `.unreadable(URL, String)`.
- `public actor TrackCache: TrackLoading` with:
  - `init(loader: any TrackLoading, budgetBytes: Int = 1_500_000_000)`
  - LRU by bytes, keyed by `(url, sampleRate)`
  - Concurrent requests for the same key share one in-flight `Task`.
  - `func pin(_ url: URL)` and `func unpin(_ url: URL)`, ref-counted. Pinned entries are never evicted.
  - `func removeAll()`

- [ ] **Step 1: Write the failing tests:**
  - `decodes48kMonoTo44100Stereo`: a 2.0 s 1 kHz sine at 48 kHz mono gives `frameCount` within ±2 of 88200, `left == right`, and a zero-crossing count of 4000 ± 10.
  - `decodes44100StereoUnchanged`: L ≠ R content is preserved sample-exactly.
  - `missingFileThrowsFileNotFound`
  - `cacheEvictsLeastRecentlyUsedOverBudget`: use a fake loader returning 1 MB tracks, a 2.5 MB budget, and a/b/c/a access order, so b is evicted. The fake loader counts calls.
  - `concurrentRequestsDecodeOnce`: 10 concurrent requests for the same URL give a loader count of 1.
  - `pinnedTracksAreNeverEvicted`: pin a, then exceed the budget; a stays and the count of a stays 1.
- [ ] **Step 2: Run to fail.** Run `swift test --filter TrackLoadingTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to pass.**
- [ ] **Step 5: Commit.** Message: `"Add AudioTrack, converter-correct decoder, pinned LRU cache"`.

### Task 12: DeckPlayer (DSP)

**Files:**
- Create: `Sources/HyperCore/DSP/DeckPlayer.swift`
- Test: `Tests/HyperCoreTests/DeckPlayerTests.swift`

**Interfaces:**
- Consumes: `AudioTrack` (Task 11)
- Produces: `public struct DeckPlayer`, a value type mutated only on the render thread. Members:
  - `var track: Unmanaged<AudioTrack>?`. It is set by `AudioCore`, which owns the retain and release.
  - `private(set) var position: Double`, in fractional frames, song-absolute.
  - `private(set) var isPlaying: Bool`
  - `private(set) var scheduledStart: Int64?`
  - `var bend: Double = 1.0`, the varispeed ratio, clamped to 0.9…1.1
  - `var loop: Range<Int>?`, a range of frames
  - `mutating func play(at sampleTime: Int64?)`: nil means immediately; otherwise playback starts exactly at that engine sample time.
  - `mutating func pause()`
  - `mutating func seek(toFrame f: Int)`
  - `mutating func nudge(frames: Int)`, clamped to `0...frameCount`
  - `mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, blockStart: Int64)`. It writes (never adds) output, uses cubic Hermite interpolation when `bend != 1` or `position` is fractional, and outputs silence with `isPlaying = false` at track end.

- [ ] **Step 1: Write the failing tests.** Use a test helper `ramp(n)` that builds an `AudioTrack` whose sample *i* equals `Float(i)`:
  - `playsSamplesExactly`: `position` 100, play, render 64 frames, output equals 100…163.
  - `scheduledStartIsSampleAccurate`: `play(at: 1000)`; render a block with `blockStart: 960` and 64 frames; out[0..<40] is 0 and out[40] equals track[0 + position].
  - `pauseOutputsSilenceAndHoldsPosition`
  - `loopWrapsSeamlessly`: loop 100..<164, position 150, render 32 frames; output is 150…163 followed by 100…117.
  - `bendAdvancesProportionally`: bend 1.02 over 1000 frames advances the position by 1020 ± 0.5.
  - `stopsAtEndOfTrack`
  - `noTrackRendersSilence`
- [ ] **Step 2: Run to fail.** Run `swift test --filter DeckPlayerTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to pass.**
- [ ] **Step 5: Commit.** Message: `"Add DeckPlayer with scheduled start, loop, bend"`.

### Task 13: SmoothedValue, IsolatorEQ, ChannelStrip

**Files:**
- Create: `Sources/HyperCore/DSP/SmoothedValue.swift`, `DSP/Biquad.swift`, `DSP/IsolatorEQ.swift`, `DSP/ChannelStrip.swift`
- Test: `Tests/HyperCoreTests/ChannelStripTests.swift`. Use a test helper `sine(freq, seconds, sr) -> [Float]` and `rmsDB(_:)` over the second half of the output, so filter settling is ignored.

**Interfaces — Produces:**
- `public struct SmoothedValue`:
  - `init(_ v: Float, rampSeconds: Float = 0.01, sampleRate: Double)`
  - `var target: Float`
  - `mutating func next() -> Float`: a linear ramp that reaches the target within `rampSeconds`
  - `mutating func reset(sampleRate: Double)`
- `public struct IsolatorEQ`:
  - `init(sampleRate: Double, lowCrossover: Double = 200, highCrossover: Double = 2500)`
  - `var lowDB, midDB, highDB: Float`, in the range `-Float.infinity ... 6`. Anything at or below `-60` is treated as a kill (linear 0).
  - `mutating func process(l: inout Float, r: inout Float)`
  - Topology:
    - an LR4 split at the low crossover gives `low` and `rest`
    - an LR4 split of `rest` at the high crossover gives `mid` and `high`
    - `low` also passes through an LR4-matched allpass at the high crossover, so the summed bands are magnitude-flat
    - the band gains are smoothed `SmoothedValue`s
- `public struct ChannelStrip`:
  - `var eq: IsolatorEQ`
  - `var trimDB: Float` (−12…+12), smoothed
  - `var fader: Float` (0…1, audio-taper `fader²`), smoothed
  - `mutating func process(left:right:frames:)`, in place
  - `func controlGains() -> (trim: Float, fader: Float, eqLinear: (Float, Float, Float))`, the *target* values, used by the centre rule

- [ ] **Step 1: Write the failing tests:**

```swift
@Test(arguments: [40.0, 200, 1000, 2500, 8000, 15000])
func flatAtZeroDB(freq: Double) { #expect(abs(rmsDB(processed(sine(freq))) - rmsDB(sine(freq))) < 0.1) }
@Test func lowKillRemoves50Hz()   { /* lowDB = -.infinity → attenuation > 40 dB at 50 Hz */ }
@Test func midKillRemoves1kHz()   { /* > 40 dB */ }
@Test func highKillRemoves10kHz() { /* > 40 dB */ }
@Test func killDoesNotAffectOtherBands() { /* lowDB kill: 8 kHz within 0.5 dB */ }
@Test func faderStepIsSmoothed() {
    // DC input 1.0, fader 1 → 0 at sample 0: max |Δout| per sample ≤ 1/(0.01*44100) + 1e-6, out ≈ 0 after 0.015 s
}
@Test func eqGainChangeHasNoStep() { /* same bound for highDB 0 → kill on a 5 kHz sine envelope */ }
```

- [ ] **Step 2: Run to fail.** Run `swift test --filter ChannelStripTests`.
- [ ] **Step 3: Implement.** Use biquad TDF-II in Double with per-channel state stored in fixed tuples, not arrays.
- [ ] **Step 4: Run to pass.**
- [ ] **Step 5: Commit.** Message: `"Add flat-summing LR4 isolator EQ and smoothed channel strip"`.

### Task 14: Mixer (crossfader, cue bus, limiter)

**Files:**
- Create: `Sources/HyperCore/DSP/Mixer.swift`, `DSP/SoftLimiter.swift`
- Test: `Tests/HyperCoreTests/MixerTests.swift`

**Interfaces:**
- Consumes: `ChannelStrip` (Task 13)
- Produces:
  - `public enum CrossfaderCurve: UInt8, Sendable { case smooth, sharp }`
    - `smooth` is constant power: gA = cos(x·π/2) and gB = sin(x·π/2), with x in 0…1.
    - `sharp` is 1.0 for both across 0.05…0.95, with linear 20-step edges at the ends.
  - `public static func crossfaderGains(_ x: Float, curve: CrossfaderCurve) -> (a: Float, b: Float)`
  - `public struct Mixer` with:
    - `var strips: (ChannelStrip, ChannelStrip)`
    - `var crossfader: Float` (smoothed) and `var curve: CrossfaderCurve`
    - `var masterDB: Float`
    - `var pfl: (Bool, Bool)`
    - `var cueMix: Float`: 0 = cue only, 1 = master only
    - `var cueDB: Float`
    - `mutating func mix(deckA: (UnsafePointer<Float>, UnsafePointer<Float>), deckB: (…), out: FourChannelOut, frames: Int)`
  - `public struct FourChannelOut { masterL, masterR, cueL, cueR: UnsafeMutablePointer<Float> }`
  - `public struct SoftLimiter`: transparent below −1 dBFS, soft-knee tanh-style above, hard ceiling 0.999. It is applied to master and cue.
  - PFL is post-EQ and pre-fader.

- [ ] **Step 1: Write the failing tests:**
  - `smoothCurveCentreIsMinus3dB`: (0.7071, 0.7071) ± 1e-3.
  - `sharpCurveCentreIsUnity`
  - `crossfaderEndsSilenceOtherSide`
  - `pflRoutesOnlyToCue`: PFL on A, crossfader fully to B; cue contains A, master contains only B.
  - `cueMixBlendsMaster`
  - `limiterCeiling`: input amplitude 4.0 gives max |out| ≤ 0.999.
  - `limiterTransparentForSmallSignals`: 0.1 amplitude is within 0.1 %.
- [ ] **Step 2: Run to fail, implement, run to pass.** Run `swift test --filter MixerTests`.
- [ ] **Step 3: Commit.** Message: `"Add mixer with crossfader curves, PFL cue bus, soft limiter"`.

### Task 15: AudioCore (render graph + command/snapshot plumbing)

**Files:**
- Create: `Sources/HyperCore/Engine/AudioCore.swift`, `Engine/CoreCommand.swift`, `Engine/CoreSnapshot.swift`
- Test: `Tests/HyperCoreTests/AudioCoreTests.swift`

**Interfaces:**
- Consumes: `SPSCQueue`, `SnapshotBox` (Task 10); `DeckPlayer` (Task 12); `Mixer`, `FourChannelOut` (Task 14); `AudioTrack` (Task 11)
- Produces:
  - `public enum DeckID: Int, CaseIterable, Sendable { case a = 0, b = 1 }`. This shadows the legacy app's `DeckID` only inside HyperCore; app files that import both use `HyperCore.DeckID`.
  - `public enum EQBand: UInt8, Sendable { case low, mid, high }`
  - `public enum CoreCommand: Sendable` with these cases:
    - `.load(DeckID, Unmanaged<AudioTrack>?, startFrame: Int)`
    - `.play(DeckID, at: Int64?)`, `.pause(DeckID)`
    - `.seek(DeckID, frame: Int)`, `.nudge(DeckID, frames: Int)`
    - `.bend(DeckID, Double)`, `.loop(DeckID, Range<Int>?)`
    - `.eq(DeckID, EQBand, Float)`, `.trim(DeckID, Float)`, `.fader(DeckID, Float)`
    - `.crossfader(Float)`, `.curve(CrossfaderCurve)`
    - `.pfl(DeckID, Bool)`, `.cueMix(Float)`, `.master(Float)`, `.cueLevel(Float)`
  - `public struct DeckSnapshot: BitwiseCopyable` with `position: Double`, `isPlaying: Bool`, `scheduledStart: Int64` (−1 if none), `trackToken: UInt64`, `peak: Float`
  - `public struct CoreSnapshot: BitwiseCopyable` with `sampleTime: Int64`, `a: DeckSnapshot`, `b: DeckSnapshot`
  - `public final class AudioCore: @unchecked Sendable` with:
    - `init(sampleRate: Double, maxFrames: Int = 4096)`, which preallocates all scratch buffers
    - `func send(_ c: CoreCommand) -> Bool`, for the main thread
    - `func render(frames: Int, out: FourChannelOut)`, for the render thread. It drains commands, renders both decks into scratch, mixes, advances `sampleTime`, and writes the snapshot.
    - `var snapshot: CoreSnapshot`, a read from the `SnapshotBox`
    - `func drainReleasedTracks()`, for the main thread. It calls `release()` on tracks the render thread replaced, which arrive via an internal `SPSCQueue<Unmanaged<AudioTrack>>`.
    - `let sampleRate: Double`
  - Ownership rule: the main thread calls `Unmanaged.passRetained(track)` before `.load`. The render thread never calls `release()`; it pushes replaced tracks to the release queue. The `trackToken` is the track's `ObjectIdentifier` bit pattern.

- [ ] **Step 1: Write the failing tests:**
  - `commandsApplyOnNextRender`: send fader and play, render 64 frames, and the snapshot shows `isPlaying` with position advanced by 64.
  - `replacedTrackIsReleasedOnMainThreadOnly`: load t1, render, load t2, render; then `drainReleasedTracks()` drops the last reference to t1, checked via a `weak var` that is nil after the drain and non-nil before.
  - `sampleTimeAdvances`
  - `snapshotPeakReflectsOutput`
  - `fullQueueReturnsFalse`
  - `endToEndCrossfade`: two constant-DC tracks (A = 0.5, B = −0.5), crossfader at 1.0, render 4096 frames; masterL ≈ −0.5 · fader² gain.
- [ ] **Step 2: Run to fail, implement, run to pass.** Run `swift test --filter AudioCoreTests`.
- [ ] **Step 3: Commit.** Message: `"Add AudioCore render graph with lock-free command and snapshot plumbing"`.

### Task 16: I/O host — devices, routing, aggregate cue device, configuration changes

**Files:**
- Create:
  - `Sources/HyperCore/IO/AudioDevices.swift`
  - `IO/OutputRouting.swift`
  - `IO/AggregateDevice.swift`
  - `IO/AudioHost.swift`
- Test: `Tests/HyperCoreTests/OutputRoutingTests.swift`, `Tests/HyperCoreTests/AudioHostTests.swift`

**Interfaces:**
- Consumes: `AudioCore`, `FourChannelOut` (Task 15)
- Produces:
  - `public struct AudioDeviceInfo: Sendable, Hashable, Identifiable` with `id: AudioDeviceID`, `uid: String`, `name: String`, `outputChannels: Int`, `nominalSampleRate: Double`
  - `public protocol DeviceProviding: Sendable { func outputDevices() -> [AudioDeviceInfo]; func defaultOutput() -> AudioDeviceInfo? }`
  - `public struct SystemDevices: DeviceProviding`. It reads CFStrings via `Unmanaged<CFString>` and the buffer list via `UnsafeMutableAudioBufferListPointer`, with no dangling pointers.
  - `public enum OutputRouting: Codable, Hashable, Sendable` with cases `.stereo(masterUID: String)`, `.splitCue(deviceUID: String)`, `.separate(masterUID: String, cueUID: String)` and `.multichannel(deviceUID: String)`.
  - `public func resolve(_ r: OutputRouting, devices: [AudioDeviceInfo]) -> OutputRouting`. Falls back to `.stereo(defaultOrMaster)` when a referenced device is missing; `.multichannel` falls back to `.stereo` when it has fewer than 4 outputs.
  - `public func channelLayout(for r: OutputRouting, deviceChannels: Int, masterChannels: Int) -> [OutputSource?]`, where `public enum OutputSource { case masterL, masterR, cueL, cueR, splitCueMono, splitMasterMono }`. It maps each hardware output channel of the (possibly aggregate) device to a source:
    - `.separate` → master device channels 0/1 carry master, and cue occupies the channels starting at `masterChannels`
    - `.splitCue` → `[.splitCueMono, .splitMasterMono]`
  - `enum AggregateDevice`:
    - `static func create(masterUID: String, cueUID: String) throws -> AudioDeviceID`. It creates a private aggregate (`kAudioAggregateDeviceIsPrivateKey: 1`) with master as the clock device and drift compensation on the cue sub-device.
    - `static func destroy(_ id: AudioDeviceID)`
  - `@MainActor public final class AudioHost` with:
    - `init(core: AudioCore, devices: any DeviceProviding = SystemDevices())`
    - `func start(routing: OutputRouting) throws`
    - `func stop()`
    - `private(set) var activeRouting: OutputRouting?`
    - `private(set) var sampleRate: Double`
    - `var onSampleRateChange: ((Double) -> Void)?`
    - `var onRoutingFallback: ((OutputRouting) -> Void)?`
    - `func handleConfigurationChange()`. This is internal and test-visible. It is subscribed to `AVAudioEngineConfigurationChange` and the CoreAudio device-list listener. It re-resolves the routing, rebuilds, restarts, and fires the callbacks.
    - `static func renderOffline(core: AudioCore, routing: OutputRouting, deviceChannels: Int, frames: Int) throws -> [[Float]]`. Uses `AVAudioEngine.enableManualRenderingMode(.offline, …)` with the same source node and layout code as the live path.
  - Single engine: one `AVAudioSourceNode` whose format has `deviceChannels` channels, connected to `outputNode`. The render block calls `core.render` into preallocated 4-channel scratch, then copies per `channelLayout`. The output device is set via `kAudioOutputUnitProperty_CurrentDevice` on `engine.outputNode.audioUnit`. `AudioCore` is recreated at the device's nominal rate by `HyperSession` (Task 18) via `onSampleRateChange`.

- [ ] **Step 1: Write the failing tests:**
  - `resolveFallsBackWhenCueMissing`: `.separate(m, c)` with only m present gives `.stereo(m)`.
  - `multichannelNeeds4Outputs`
  - `separateLayoutPutsCueAfterMasterChannels`: master has 2 channels and the aggregate has 4, giving `[.masterL, .masterR, .cueL, .cueR]`.
  - `splitCueLayout`
  - `offlineRenderProducesDeckAudio`: build a core with a DC track playing, call `renderOffline(… .stereo, deviceChannels: 2, frames: 4096)`, and channel 0 is non-zero.
  - `configurationChangeWithMissingCueFallsBackToStereo`: use a `FakeDevices` whose list drops the cue device between start and `handleConfigurationChange()`; `activeRouting == .stereo(m)` and `onRoutingFallback` fired. Fake devices are not opened, so this test exercises the resolve path. Structure `AudioHost` so engine start is behind an injectable `EngineStarting` closure that the test stubs.
- [ ] **Step 2: Run to fail, implement, run to pass.** Run `swift test --filter "OutputRoutingTests|AudioHostTests"`.
- [ ] **Step 3: Manual hardware check** (record the result in the commit message). Run a 20-line scratch executable or the app after Task 19 to verify `.separate(builtIn speakers, USB headphones)`. Expected: a tone on deck A with PFL on is heard in the headphones only, with crossfader on A and PFL off it is heard on the speakers only, and no drift clicks over 10 minutes.
- [ ] **Step 4: Commit.** Message: `"Add single-engine audio host with routing, aggregate cue device, config-change recovery"`.

### Task 17: CentreTracker

**Files:**
- Create: `Sources/HyperCore/Session/CentreTracker.swift`
- Test: `Tests/HyperCoreTests/CentreTrackerTests.swift`

**Interfaces — Produces:**
- `public func effectiveLevel(isPlaying: Bool, trim: Float, fader: Float, crossfaderGain: Float, eqLinear: (Float, Float, Float)) -> Double`. It returns 0 if not playing, otherwise `trim·fader·xf·eqOpenness`, where `eqOpenness = min(1, (0.5·low + 0.3·mid + 0.2·high))` with each band's linear gain clamped to 0…1.
- `public struct Handover: Equatable, Sendable { public let from: DeckID?; public let to: DeckID }`
- `public struct CentreTracker` with:
  - `init(margin: Double = 1.25, minLevel: Double = 0.2, dwell: TimeInterval = 1.0)`
  - `private(set) var centre: DeckID?`
  - `mutating func update(levels: [DeckID: Double], now: TimeInterval) -> Handover?`
- Rules:
  - When there is no centre, the first deck with level ≥ `minLevel` becomes centre immediately.
  - Otherwise, the other deck takes over once `other ≥ max(minLevel, centre·margin)` has held continuously for `dwell` seconds.
  - Any interruption resets the dwell timer.

- [ ] **Step 1: Write the failing tests:**
  - `firstAudibleDeckBecomesCentreImmediately`
  - `wiggleShorterThanDwellDoesNotSwitch`: B dominant for 0.6 s, then back.
  - `sustainedDominanceSwitchesAfterDwell`: switches at t = 1.0, not at 0.99.
  - `pullingBackReversesAfterDwell`
  - `stoppedCentreWithAudibleOtherSwitchesAfterDwell`
  - `belowMinLevelNeverTakesOver`
  - `effectiveLevelKillsReduceOpenness`: a low kill drops the level by 50 %.
- [ ] **Step 2: Run to fail, implement, run to pass.** Run `swift test --filter CentreTrackerTests`.
- [ ] **Step 3: Commit.** Message: `"Add CentreTracker display/logging rule"`.

### Task 18: HyperSession

**Files:**
- Create: `Sources/HyperCore/Session/HyperSession.swift`, `Session/DeckModel.swift`
- Test: `Tests/HyperCoreTests/HyperSessionTests.swift`. Tests drive time manually: build the session with an `AudioCore` and no host, call `core.render` in the test to advance audio, then `session.tick(now:)`. Use `FakeLoader: TrackLoading` with controllable completion (continuations) and `graph_v2.json`.

**Interfaces:**
- Consumes: everything above
- Produces:
  - `public enum QuantizeTarget: Sendable { case nextDownbeat, nextPhraseBoundary }`
  - `@MainActor @Observable public final class DeckModel` with:
    - `let id: DeckID`
    - `var track: URL?`, `var currentPhrase: PhraseNode?`, `var positionSeconds: Double`, `var isPlaying: Bool`
    - `var loadState: LoadState`, where `LoadState` is `.empty`, `.loading`, `.ready` or `.failed(String)`
    - `var loopEnabled: Bool`, `var pfl: Bool`
    - `var eq: (low: Float, mid: Float, high: Float)`, `var trimDB: Float`, `var fader: Float`
  - `@MainActor @Observable public final class HyperSession` with:
    - `init(navigator: GraphNavigator?, loader: any TrackLoading, feedback: RelationshipDatabase?, sampleRate: Double, now: @escaping () -> TimeInterval)`
    - `let decks: [DeckID: DeckModel]`
    - `private(set) var core: AudioCore`, recreated on a sample-rate change
    - `private(set) var centre: DeckID?`
    - `var centreDeck: DeckModel?`
    - `private(set) var incoming: (deck: DeckID, branch: Branch)?`
    - `private(set) var lastTransition: Branch?`
    - `var branches: [Branch]`: computed from the centre deck's current phrase, with limit 8, adjusted through `feedback.adjustedWeight`
    - `var crossfader: Float`, `var curve: CrossfaderCurve`, `var cueMix: Float`, `var masterDB: Float`
    - `private(set) var message: String?`, for user-facing refusals and errors
    - `func start(phrase: PhraseNode, on deck: DeckID = .a) async`: loads at the phrase start and plays
    - `func loadBranch(_ b: Branch) async`: targets the non-centre deck, positions at `b.to.startTime`, paused, with PFL on, and sets `incoming`. It is refused with `message` when the target's effective level > 0.
    - `func play(_ d: DeckID)`, `func pause(_ d: DeckID)`
    - `func quantizedStart(_ d: DeckID, target: QuantizeTarget = .nextDownbeat)`
    - `func nudge(_ d: DeckID, ms: Double)`
    - `func bend(_ d: DeckID, active: Bool, up: Bool)`: ±4 % while held
    - `func toggleLoop(_ d: DeckID)`: loops the deck's current phrase range
    - setters `setEQ(_ d: DeckID, _ band: EQBand, dB: Float)`, `setTrim(_ d: DeckID, dB: Float)`, `setFader(_ d: DeckID, _ v: Float)`, `setPFL(_ d: DeckID, _ on: Bool)`
    - `func rateLastTransition(_ rating: Int)`
    - `func tick()`: called at about 60 Hz by the app. It reads the snapshot, updates decks, derives `currentPhrase` via `navigator.phrase(atSongTime:inTrack:)`, runs `CentreTracker`, logs on handover, calls `core.drainReleasedTracks()`, and pins and unpins cache entries.
    - `func engineSampleRateChanged(to sr: Double) async`: rebuilds the core, re-decodes loaded tracks at `sr`, restores positions in seconds, play states and mixer values
- Latest-wins loads: a per-deck `UInt64` load generation is captured before `await loader.track(...)`. On completion, a stale generation is discarded.
- Logging rule, from the spec:
  - On a `Handover(to: d)` where `incoming?.deck == d`, call `feedback.logPlayed(from: incoming.branch.from.id, to: incoming.branch.to.id, source: .performance)`, set `lastTransition`, and clear `incoming`.
  - Reloading that deck clears `incoming` without logging.
  - Handovers to a deck without `incoming` log nothing.
- Quantize: the target song time is the first `centreDeck.currentPhrase.songTime(ofPhraseRelative: downbeat)` strictly after the centre's current song time; with `.nextPhraseBoundary`, it is the phrase `endTime`. It is converted to engine sample time as `snapshot.sampleTime + (target − now)·sr`. With no downbeats, use `.nextPhraseBoundary`; with no centre playing, start immediately.

- [ ] **Step 1: Write the failing tests:**
  - `currentPhraseFollowsPositionWithoutSkipping`: play track 1 from 0 and render through all 3 phrases in 512-frame blocks with `tick()` after each; the observed `currentPhrase.trackIndex` sequence is exactly [0, 1, 2]. This is the regression for the skip bug.
  - `latestLoadWins`: start loads X then Y on deck B, complete Y then X; deck B's track is Y. This is the regression for the wrong-song race.
  - `loadBranchTargetsNonCentreDeckAtPhraseStartWithPFL`
  - `loadBranchRefusedWhenTargetDeckIsAudible`
  - `quantizedStartLandsOnNextDownbeat`: the deck B snapshot `scheduledStart` equals the expected sample time to within ±1.
  - `quantizedStartWithoutDownbeatsFallsBack`
  - `handoverLogsBranchedFromPhraseEvenAfterCentreAdvanced`: load a branch from phrase A0; deck A advances to A1; fade in B; after the dwell, the DB has `played(A0 → B?)` and `lastTransition` is set.
  - `abandonedLoadIsNotLogged`
  - `rateLastTransitionWritesRating`
  - `failedLoadSetsDeckErrorAndSendsNoCommand`
  - `sampleRateChangeRedecodesAndKeepsPositionSeconds`: 44100 → 48000; `positionSeconds` is within 1 ms and the loader was called with 48000.
  - `releasedTracksAreDrainedOnTick`
- [ ] **Step 2: Run to fail.** Run `swift test --filter HyperSessionTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to pass, then run the full suite.** Run `swift test`. Expected: all suites pass.
- [ ] **Step 5: Commit.** Message: `"Add HyperSession: workflow, quantize, centre handover logging, sample-rate recovery"`.

---

## Part D — App

### Task 19: HyperMusic tab on HyperSession; remove the old player

**Files:**
- Create in `MusicMill/HyperMusic/`:
  - `HyperMusicView.swift`: the layout, keeping today's arrangement: top waveform strip, left control panel, main graph area
  - `CentreGraphView.swift`: the centre deck's phrase sequence with the current phrase highlighted, its branches, and the incoming phrase attached to its branch
  - `DeckPanel.swift`: per-deck play/pause, quantized start, nudge ±, bend hold, loop, PFL, load state and errors, and a `MetalWaveformView` with `useOriginalFile: true` and `trackPlaybackProgress`
  - `MixerPanel.swift`: per-channel EQ knobs with kill toggles, trim, fader, crossfader with curve picker, cue mix, master
  - `OutputSettingsView.swift`: master and cue device pickers from `SystemDevices`. The `OutputRouting` is persisted to `UserDefaults` key `"hyper.outputRouting"` as JSON.
  - `HyperShortcuts.swift`: keyboard shortcuts, listed below
  - `AppAudio.swift`: an `@MainActor` holder that creates `AudioHost`, `HyperSession` and `TrackCache(loader: TrackDecoder())`, wires `onSampleRateChange` → `session.engineSampleRateChanged` and `onRoutingFallback` → `session.message`, and drives `session.tick()` from a 60 Hz `Timer` in `.common` mode
- Modify:
  - `MusicMill/App/MusicMillApp.swift`: owns `AppAudio` as `@State`
  - `MusicMill/App/ContentView.swift`: tab 0 is `HyperMusicView()`
- Delete: `MusicMill/Generation/HyperPhrasePlayer.swift`, `MusicMill/Generation/TransitionEngine.swift`, `MusicMill/Performance/HyperPhraseView.swift`
- Keep from the old view: the session start/end and thumbs up/down controls, now calling `HyperSession`/`RelationshipDatabase`.
- Shortcuts:

  | Action | Deck A | Deck B |
  |---|---|---|
  | Play/pause | `Q` | `P` |
  | Quantized start | `W` | `O` |
  | Nudge −/+ | `A`/`S` | `K`/`L` |
  | Bend while held | `Z`/`X` | `,`/`.` |
  | Loop | `E` | `I` |
  | PFL | `1` | `0` |

  - Load branch N: `⌘1`…`⌘8`
  - Crossfader steps: `←`/`→`
  - Rate the last transition: `+`/`−`

Views hold no logic beyond formatting. Every action is a single `HyperSession` call, and the core is already tested in Tasks 7–18. Verification is a build plus a manual checklist.

- [ ] **Step 1: Delete the old files and build** to list everything that referenced them. Run `xcodebuild … build 2>&1 | grep error: | sort -u`. Expected: errors only in files being replaced.
- [ ] **Step 2: Implement the views and `AppAudio`.**
- [ ] **Step 3: Build.** Expected: `** BUILD SUCCEEDED **`, with no new warnings in `MusicMill/HyperMusic/`. Check with `… build 2>&1 | grep "HyperMusic/.*warning" | wc -l`, which should print 0.
- [ ] **Step 4: Manual checklist** against the real graph rebuilt in Task 6. Run the app from Xcode and tick each item:
  - The graph loads and deck A starts on a random phrase. The centre shows it, with branches listed.
  - Clicking a branch loads it onto deck B, paused at its phrase start with PFL on, and it is drawn as incoming.
  - Quantized start on B lands on A's downbeat audibly.
  - Nudge and bend move B's phase. Looping B is seamless.
  - EQ is transparent at 0, and kills are clean with no zipper noise.
  - Crossfader curves behave as designed. Raising B above A moves the centre after about 1 s; a quick wiggle doesn't.
  - After the handover, the thumbs buttons rate the logged A-phrase → B-phrase pair. Check with `sqlite3 ~/Documents/MusicMill/relationships.db "select * from transition_events order by rowid desc limit 3"`.
  - A cue device set in Output settings is heard only through cue. Unplugging it mid-play keeps master playing and shows a fallback message.
  - Clicking a phrase on a deleted or moved file shows a deck error.
  - The Prep, Granular, RAVE and Training tabs still open.
- [ ] **Step 5: Commit.** Message: `"Rebuild HyperMusic tab on HyperSession; remove HyperPhrasePlayer and TransitionEngine"`.

### Task 20: Full verification, soak test, follow-ups recorded

**Files:**
- Modify: `README.md` (Architecture and Getting Started for HyperCore, the Python venv and `pytest`), `FUTURE_IDEAS.md` (add the follow-ups list from the spec in order: time-stretch/sync, track browser, MIDI/gear)

- [ ] **Step 1: Run all suites.**

```bash
(cd Packages/HyperCore && swift test 2>&1 | tail -3)
(cd scripts && .venv/bin/pytest -q 2>&1 | tail -2)
xcodebuild -project MusicMill.xcodeproj -scheme MusicMill -destination 'platform=macOS' test 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)"
```

Expected: every suite passes and `** TEST SUCCEEDED **`.
- [ ] **Step 2: TSan run of the core.** Run `(cd Packages/HyperCore && swift test --sanitize=thread 2>&1 | grep -c "ThreadSanitizer")`. Expected: `0`.
- [ ] **Step 3: One-hour soak.** Mix continuously in the app with branches every 1–3 minutes, with Activity Monitor and Console open. Expected:
  - no crash or hang
  - no audio dropouts heard, and no `HALC`/overload messages in Console filtered by "MusicMill"
  - memory plateaus under the cache budget plus about 300 MB
- [ ] **Step 4: Update the docs, and commit.** Message: `"Docs: HyperCore architecture, test commands, follow-ups"`.
