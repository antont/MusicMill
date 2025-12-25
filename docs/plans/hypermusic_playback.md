# HyperMusic Playback System

## Overview

The HyperMusic system enables navigating through a music collection as a graph of interconnected phrases. Users can play songs normally or branch off to compatible phrases from other tracks.

## Current Implementation (December 2024)

### Playback Modes

1. **Same Track Sequential** - Gapless playback
   - Phrases from the same track play seamlessly
   - No transition effects, just continuous audio
   - Like playing the original song

2. **Cross-Track Transition** - Phrase boundary switch
   - User taps a phrase from a different track
   - Current phrase plays to completion
   - Switches to new track at phrase boundary
   - Clean direct cut (no fade)

### Files

- `HyperPhrasePlayer.swift` - Core playback engine
- `HyperPhraseView.swift` - Timeline UI with branch options
- `PhraseDatabase.swift` - Graph data model
- `TransitionEngine.swift` - (Reserved for future DJ transitions)

## Future Options

### Transition Trigger Modes

**A) Quick Switch (Not Yet Implemented)**
- Immediate beat-aligned cut
- User action: Double-tap? Long press? Modifier key?
- Uses `player.triggerTransition()` which waits for next beat
- Good for: Live performance, tight control

**B) Phrase Boundary Switch (Current)**
- Wait for current phrase to end
- User action: Single tap queues the next phrase
- Good for: Smooth listening experience

### DJ-Style Transitions (Future)

The `TransitionEngine` is preserved for sophisticated transitions:

1. **Crossfade** - Simple volume blend over N bars
2. **EQ Swap** - Kill bass on outgoing, bring in bass on incoming
3. **Filter Sweep** - Low-pass filter out, high-pass filter in
4. **Echo Out** - Delay/reverb tail on outgoing

### UI Controls for Future

- Transition duration selector (bars)
- Transition type selector
- Manual crossfader slider
- Beat-sync toggle
- Loop current phrase button

## Implementation Notes

### Beat Alignment

The `isNearBeat()` function uses:
- 50ms tolerance for beat detection
- Falls back to immediate cut if no beat data
- Cuts near phrase end if within 100ms

### Buffer Management

- Current and next buffers preloaded
- `executeDirectCut()` swaps buffers instantly
- New next phrase queued after switch
- Async buffer loading with completion handlers

