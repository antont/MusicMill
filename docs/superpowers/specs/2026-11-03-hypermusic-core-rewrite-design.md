# HyperMusic Core Rewrite — Design

Date: 2026-11-03
Status: draft for review

## Intent

MusicMill's point is HyperMusic: you play a song, the app shows phrases in *other* songs that match the one playing, and you jump into one of them and carry on. The phrase graph **suggests** where to go. **You do the mixing**, like a DJ: load the suggested phrase onto the other deck, pre-listen it, EQ it, line it up in time, and bring it in with the faders.

Today, the audible playback is a single-stream player that hard-cuts between songs. The two decks, their EQ and cue preview exist in the UI but are never connected to audio, so they are silent. The core also has a deadlock, a phrase-tracking bug, races, and real-time-unsafe audio code (see "Known defects" at the end). The Python graph builder has scoring bugs that hide a quarter of the cross-song matches.

The rewrite makes the standalone Mac side good, clear, robust and bug-free: a real two-deck mixer driven by mouse and keyboard, a correct graph, and a codebase built test-first that MIDI and DJ gear can later plug into without changes to the core.

## Success

A long session (an hour or more) of jumping between songs with:
- no crashes, freezes or audio glitches
- what's shown always matching what is heard (current phrase, positions, waveforms)
- the mixer behaving like DJ hardware: EQ that is transparent at 0 dB and kills cleanly, smooth faders, nothing clicking when controls move

## Goals

1. **One audio engine with two symmetric decks and a mixer.** Each deck has a channel strip (3-band EQ with kills, trim/gain, channel fader, cue/PFL button). There is a crossfader and a master level. Neither deck is permanently "main" or "cue". Either deck can play out, be pre-listened, or both.
2. **The HyperMusic mixing workflow.** The audio side is plain DJ: two independent decks and a normal mixer. "What is playing now" is a *display and logging* concept layered on top. It never changes audio.
   - **Centre of the UI = the dominant channel.** This is the channel the user has made the main sound, judged from **control state, not measured loudness**: trim × channel fader × crossfader gain × an EQ openness factor, with a stopped deck counting as 0. The centre shows that deck's current phrase, its phrase sequence, and its branches into other songs in the graph view.
   - **Picking a branch** from the centre loads that phrase onto the **other deck**, positioned at the phrase start and paused, with that deck's cue/PFL turned on. In the graph it is drawn as the **incoming** phrase, attached to the branch it came from, with its own position and waveform visible while mixing.
   - The incoming phrase can be:
     - started **quantized**: playback begins exactly on the centre deck's next downbeat, sample-accurately, with a selectable option for the next phrase boundary instead
     - **nudged** (jump by ±ms) and **bent** (temporary varispeed of a few percent while held) to fix phase
     - **looped** on its phrase while you wait
   - **Handover.** The user mixes manually. When the incoming channel's effective level exceeds the centre channel's by a clear margin and holds there briefly (hysteresis plus a dwell time, so crossfader wiggles and bass swaps don't flip the screen), the incoming deck becomes the centre and its own branches appear. Pulling it back reverses the handover by the same rule.
   - **Logging.** At handover, the transition logged to `relationships.db` is **the phrase the branch was picked from → the phrase that was loaded**, which is the graph link actually followed. The rating buttons rate that last logged transition.
     - Loads never brought in are not logged.
     - A handover reversed within the dwell window never happened.
     - A handover back to a deck that wasn't loaded from a branch (for example, returning to the original song) logs nothing.
3. **Sequential playback within a song is gapless and natural.** Phrase boundaries are only markers. The "current phrase" is *derived* from the deck's play position, never advanced by the audio thread.
4. **Robust audio:**
   - Any common file format, sample rate and channel count loads correctly.
   - The engine runs at the device's sample rate and survives device or configuration changes.
   - The render path is real-time safe.
5. **Correct graph (Python pipeline fixes):**
   - Phrases get cross-song matches.
   - Key matching is correct, including major/minor.
   - Energy is normalized to 0–1.
   - Transition suggestions span the intended range.
   - Phrase IDs are stable across rebuilds, so ratings survive. Re-analysis that moves phrase boundaries may change IDs, which is accepted.
   - Manual ratings affect link weights.
   - `relationships.db` holds no events today, so no migration is needed.
6. **Test-driven.** Every unit of core behavior is written test-first. Tests run fast and offline from the command line, with no dependency on the user's music library.
7. **Remove genuinely dead code.**

## Non-goals (this rewrite)

- MIDI, HID and DJ controllers. The core must not *preclude* them (see Constraints), but none are built.
- Time-stretch, key-lock, tempo sync, a BPM fader. This is the **first follow-up** after the rewrite. The varispeed bend is in scope only as a phase-nudging tool.
- A track browser to choose the starting song. **Follow-up.** For now, start the way it does today: a random start phrase, plus clicking any shown phrase.
- Redesigning the HyperMusic screen. The current layout is fine. It gets rebuilt on the new core with the same overall arrangement, plus the mixer controls that now actually work.
- Prep, Phrase, Granular, RAVE and Training tabs. They stay as they are and are not touched beyond what's needed to keep them compiling.

## Anti-goals

- Any lock, allocation, logging, Objective-C messaging, or main-thread dispatch on the render thread.
- The audio thread deciding UI state, such as which phrase is "current".
- Tests that need the user's real library, `~/Documents/MusicMill`, or a Python venv in order to pass. Tests that pass silently when data is missing.
- Rewriting the legacy tabs or the Metal waveform renderer.

## Constraints

- macOS 15.6 deployment target, Xcode 26 / Swift 6.2. `Synchronization` (`Atomic`) and Swift Testing are available.
- Graph files stay where they are: `~/Documents/MusicMill/PhraseGraph/phrase_graph.json` and `~/Documents/MusicMill/relationships.db`. The graph JSON schema may change, since the app and builder are updated together, but old graphs must produce a clear "rebuild the graph" error, not a crash.
- **Gear-ready output shape** (my call): the core mixer produces **four channels: master L/R and cue L/R**. The I/O layer maps them to hardware:
  - On a device with ≥4 outputs: master → 1/2, cue → 3/4.
  - **Separate cue device (the user's choice for today):** master goes to one output device and cue to another, for example speakers plus headphones on a USB interface. To keep a single engine and a single clock (my call), the I/O host builds a private CoreAudio **aggregate device** from the two devices, with drift correction on the cue sub-device, and maps master and cue onto its channels.
    - The user picks the master and cue devices in the app, and the choice is persisted.
  - With only one stereo device selected: master only, plus an optional **split-cue** mode (left = cue in mono, right = master in mono) as a fallback.
  - Later MIDI/gear work then only adds a controller layer that sends the same commands the UI sends.

## Architecture (decided)

### Packaging

A new local Swift package, **`HyperCore`** (in `Packages/HyperCore`), holds everything except SwiftUI views. The app target depends on it.
- `swift test` in that folder runs the whole core test suite in seconds, with no app host.
- The graph model types (`PhraseNode`, `PhraseLink`, …) move into it, and legacy tabs `import HyperCore` where they need them.

### Layers inside HyperCore

1. **Graph** (pure, value types)
   - `PhraseGraph` is the decoded JSON plus indexes, with schema-version checking.
   - `GraphNavigator` answers:
     - the phrase at a time in a track
     - the next phrase in the original sequence
     - cross-song branch options for a phrase, ranked, with relationship-DB adjustment
     - higher- and lower-energy alternatives
   - All queries are precomputed or indexed, with no full scans per call.
2. **DSP** (pure, deterministic, buffer-in/buffer-out, testable offline)
   - `DeckPlayer`:
     - play/pause/seek
     - sample-accurate scheduled start at a target engine sample time
     - varispeed bend with interpolation
     - nudge
     - loop region
     - reports its position
   - `ChannelStrip`:
     - DJ isolator EQ built from Linkwitz-Riley crossovers, so the bands sum flat at 0 dB
     - kills to silence
     - trim and fader
     - all gains smoothed per sample to avoid zipper noise
   - `Mixer`:
     - two strips feeding a crossfader with a selectable curve (smooth/constant-power, sharp cut)
     - master level
     - cue bus fed by PFL selections, with a cue/master blend
     - output safety: a soft clip/limiter on master and cue
3. **Real-time bridge**
   - Commands flow UI → audio through a lock-free single-producer/single-consumer queue of plain value enums.
   - State flows audio → UI through an atomic snapshot that the UI polls at display rate: positions, playing flags, levels and engine sample time. This replaces per-buffer `DispatchQueue.main.async`.
   - Track buffers are handed to the audio thread through the command queue, and old buffers are handed back on a return queue so they are freed off the audio thread.
   - The render callback holds no Swift class references that would retain or release.
4. **Audio I/O host**
   - One `AVAudioEngine` with one `AVAudioSourceNode` that renders the whole `Mixer` at the engine/device rate, with the channel mapping described in Constraints.
   - Handles `AVAudioEngineConfigurationChange` and device loss by rebuilding and restarting while keeping deck state.
   - Can run in **manual rendering mode** for integration tests.
5. **Track loading**
   - Decodes any supported file to float stereo at the engine rate, using `AVAudioConverter` correctly, off the main thread.
   - A memory-bounded LRU cache of decoded tracks. Loading for a deck is cancellable, and only the latest request for a deck wins, which removes the wrong-song race.
6. **Session** (`@MainActor`, `@Observable`)
   - `HyperSession` owns the engine, the loader, the navigator and the relationship DB.
   - It exposes the UI model:
     - each deck's track, current phrase (derived from the polled position), waveform and state
     - which deck is the centre
     - the incoming phrase and the branch it came from
     - branch suggestions
     - mixer control values
   - It turns UI intents into commands: load branch to the other deck, quantized start, nudge, bend, loop, EQ, faders, cue.
   - The **centre rule** (effective level from control state, margin, hysteresis, dwell) is a pure, separately tested `CentreTracker` fed by mixer control values and deck play states. It drives the handover and transition logging. It has no effect on audio.

### App

- The HyperMusic tab is rebuilt as small SwiftUI views bound to `HyperSession`, keeping today's layout and adding working mixer controls.
- Keyboard shortcuts cover the core performance actions:
  - play/pause per deck
  - quantized start
  - nudge/bend
  - load suggestion N
  - cue toggles
  - crossfader steps
- The existing Metal waveform views are reused, fed from session state.
- Deleted: `HyperPhrasePlayer` and `TransitionEngine`, which nothing else uses.
- Kept but moved under `MusicMill/Legacy/` only because the Prep tab uses them: `Deck`, `AudioRouter`, `ThreeBandEQ`. They stay untouched, and HyperMusic no longer uses them.

### Python pipeline fixes (`scripts/analyze_library.py`, `scripts/build_phrase_graph.py`)

- **Link budget.**
  - Each phrase keeps its original-sequence link plus up to N cross-song links, selected separately.
  - Same-song non-sequence links are capped separately or dropped.
  - Per-track features no longer let same-song pairs crowd out other songs.
- **Weights and transitions.**
  - Scoring is rescaled so weights use the 0–1 range meaningfully.
  - `MIN_LINK_WEIGHT` and the transition-type thresholds are recalibrated so `eqSwap`, `filter` and `cut` actually occur.
  - This is checked by a distribution test on fixtures.
- **Key.**
  - Detection uses major/minor key profiles (Krumhansl-style correlation over chroma).
  - One consistent naming scheme for sharps and flats.
  - Circle-of-fifths distance with relative major/minor treated as compatible.
- **Energy** is normalized to 0–1 across the library (percentile-based).
- **Downbeats** are estimated by choosing the bar phase with the strongest onset/low-band energy, instead of assuming beat 0 is a downbeat. The first phrase starts at the first downbeat or at 0 when it is near 0.
- **Stable IDs.** The phrase ID is a short hash of (track path, phrase index). No DB migration, since the DB is empty.
- **Format.**
  - `beats` placement is made consistent.
  - The graph JSON gets a `schemaVersion`.
  - The track-list scan inside the n² loop is removed.
- **Ratings.** `RelationshipDatabase.adjustedWeight` counts manual ratings, not only played events.

### Testing approach (TDD)

- Red → green → refactor for every behavior. Each plan task starts with failing tests.
- **Core:**
  - Swift Testing in `HyperCore`, with synthetic signals generated in tests: sines, clicks at known BPM, impulses.
  - DSP is asserted numerically: EQ null/flatness and kill depth, smoothing (no step larger than ε), sample-accurate scheduled start, loop seams without discontinuity, crossfader curves, and limiter ceiling.
  - Graph tests use small hand-written JSON fixtures.
  - The real-time bridge is tested for ordering, overflow behavior and buffer hand-back.
- **Engine integration:** `AVAudioEngine` manual rendering mode renders a full scenario offline (load two tracks, quantized start, crossfade) and checks the output.
- **Python:** `pytest` with synthetic audio fixtures (click tracks at known tempo and phase, tonal fixtures in known keys) and graph-building fixtures. Includes a regression test that no phrase is left without cross-song links when compatible ones exist.
- **Existing tests:**
  - Tests for deleted code are deleted.
  - Machine-specific tests for legacy tabs are kept but excluded from the default test plan, so the default run is hermetic.

## Removal list (verified unreferenced)

Removed (recoverable from git history):
- **Unreferenced types:** `StructureAnalyzer`, `SegmentExtractor`, `RekordboxParser`, `SpectralAnalyzer`, `NeuralGenerator`, `SampleGenerator`, `GenerativeModelTrainer`, `PerformanceView`, `GenerationController`, `MixingEngine`, `PlaybackController`, `StyleController`, `TrackSelector`, `DJMixerView`.
- **Referenced only by tests**, decided as dead (my call): `QualityAnalyzer`, `ConcatenativeSynthesizer`.
- **Files:** the empty `SegmentMatcher.swift`, and files not in any target (`RunAnalysis.swift`, `WaveformPerformanceTest.swift`, `WaveformPerformanceBenchmark.swift`).
- **Unused methods:** the unused `PhraseDatabase`/`AnalysisStorage`/`SynthesisEngine` methods.
- **Repo:** the committed `default.profraw`, now gitignored.

The builder re-verifies each with a build after removal. Anything a legacy tab still reaches stays.

## Left to the builder

- Exact crossover frequencies and EQ range (typical DJ isolator: about 200 Hz and 2–2.5 kHz, +6 dB to kill).
- Crossfader curve shapes, limiter design, varispeed interpolation quality (at least linear, cubic preferred), and bend range.
- LRU memory budget.
- Snapshot polling mechanism (a display-link or timer at about 60 Hz).
- Queue capacity.
- Cross-song link count N and the recalibrated thresholds, chosen by looking at the real graph's distribution after the fixes.
- Keyboard shortcut assignments.
- How the HyperMusic views are split into files.

## Follow-ups after the rewrite (in order)

1. Time-stretch / tempo sync / key-lock.
2. A track browser to choose the starting song.
3. MIDI/HID controller layer and gear output routing (Numark NVII, XDJ-XZ), per `docs/plans/dj_controller_support_architecture.md`.

## Known defects this rewrite eliminates (from the 2026-11-03 review)

- **Deadlock:** `HyperPhrasePlayer.selectPhrase` locks again when the song is already cached.
- **Phrase-skipping:** the per-buffer `phraseEndSample` makes auto-advance cascade through phrases.
- **Wrong-song race:** `pendingSongBuffer` is not tied to the queued song, and a branch can fire before its load finishes.
- **Real-time violations:** locks, allocation, database queries, `print`, and main-thread dispatch in render callbacks. Unprotected shared state.
- **Loading failures:** 48 kHz and mono files fail to load, and the song cache is unbounded.
- **Silent decks:** Deck A/B source nodes are never connected, so the EQ and cue do nothing. Decks are hard-wired to main/cue engines.
- **Deck position bugs:** Deck plays from song start rather than phrase start. Beat-seek mixes phrase-relative beats with song time. The converter re-feeds its input.
- **EQ bugs:** the high-pass runs twice per sample, the mid band is wrong, Q is wrong, and gains are not smoothed.
- **AudioRouter:** `deinit` escapes `self`, there is no configuration-change handling, and the CFString/buffer-list handling is undefined behaviour.
- **Graph scoring:** same-track link domination, all-crossfade transitions, key-circle mixing, raw-RMS energy, UUID IDs, and manual ratings being ignored.
