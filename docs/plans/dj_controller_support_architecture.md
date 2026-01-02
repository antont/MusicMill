---
name: DJ Controller Support Architecture
overview: Design and implement a flexible DJ controller support system for Numark NVII and Pioneer XDJ-XZ, with extensible architecture for future controllers. The system will handle MIDI/HID input, map controls to Deck and mixer functions, and support controller display output.
todos: []
---

# DJ Controller Support Architecture

## Overview

Add comprehensive DJ controller support to MusicMill, starting with Numark NVII (primary test device) and Pioneer XDJ-XZ. The architecture will be extensible to support additional controllers in the future.

**HyperMusic Integration**: The controller displays and performance pads will integrate with the HyperMusic graph system:

- **Left display (Deck A)**: Shows currently playing phrase with waveform and metadata
- **Right display (Deck B)**: Shows branch options (up to 8) when Deck B is not loaded, or shows Deck B phrase when loaded for cueing
- **Performance pads**: When Deck B is not loaded, pads 1-8 select branch options to load to Deck B for cueing and mixing

**HyperMusic Integration**: The controller displays and performance pads will integrate with the HyperMusic graph system:

- **Left display (Deck A)**: Shows currently playing phrase with waveform and metadata
- **Right display (Deck B)**: Shows branch options (up to 8) when Deck B is not loaded, or shows Deck B phrase when loaded for cueing
- **Performance pads**: When Deck B is not loaded, pads 1-8 select branch options to load to Deck B for cueing and mixing

## Architecture Design

### Layer Structure

```javascript
┌─────────────────────────────────────────┐
│  DJMixerView / HyperPhraseView         │  (UI Layer)
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  ControllerManager                      │  (Orchestration)
│  - Manages active controller            │
│  - Routes input/output                  │
└──────────────┬──────────────────────────┘
               │
    ┌──────────┴──────────┐
    │                     │
┌───▼────────┐    ┌───────▼────────┐
│ MIDIInput  │    │ HIDInput       │  (Input Layer)
│ Handler    │    │ Handler        │
└───┬────────┘    └───────┬────────┘
    │                     │
    └──────────┬──────────┘
               │
┌──────────────▼──────────────────────────┐
│  Controller Protocol                     │  (Abstraction)
│  - NumarkNVII                            │
│  - PioneerXDJXZ                          │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  ControlMapper                           │  (Mapping Layer)
│  - Maps MIDI CC → Deck functions         │
│  - Handles jog wheel → position          │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  Deck / DJMixerViewModel                 │  (Application Layer)
└──────────────────────────────────────────┘
```

## Implementation Plan

### Phase 1: Core Input Infrastructure

**1.1 Create MIDI Input Handler**

- File: `MusicMill/Audio/MIDIInputHandler.swift`

- Uses CoreMIDI framework
- Responsibilities:

- Create MIDI client and input port

- Discover and connect to MIDI sources

- Parse MIDI messages (Note On/Off, CC, SysEx)

- Emit events via Combine publishers
- Key methods:
  ```swift
    func startListening()
    func stopListening()
    func connectToSource(_ source: MIDIEndpointRef)
    var midiEvents: PassthroughSubject<MIDIEvent, Never>
  ```


**1.2 Create HID Input Handler**

- File: `MusicMill/Audio/HIDInputHandler.swift`

- Uses IOKit.hid framework

- Responsibilities:

- Discover HID devices (jog wheels, touch strips)

- Handle continuous position data

- Low-latency input for jog wheel scrubbing
- Key methods:
  ```swift
    func startListening()
    func connectToDevice(_ device: IOHIDDevice)
    var jogWheelEvents: PassthroughSubject<JogWheelEvent, Never>
  ```


**1.3 Create MIDI Event Types**

- File: `MusicMill/Audio/MIDITypes.swift`
- Define event structures:
  ```swift
    enum MIDIEvent {
        case controlChange(channel: UInt8, cc: UInt8, value: UInt8)
        case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
        case noteOff(channel: UInt8, note: UInt8)
        case sysEx(data: Data)
    }
    
    struct JogWheelEvent {
        let deck: DeckID
        let position: Float  // 0-1 or relative delta
        let isPressed: Bool
    }
  ```


### Phase 2: Controller Abstraction

**2.1 Create Controller Protocol**

- File: `MusicMill/Audio/DJController.swift`

- Protocol definition:
  ```swift
    protocol DJController {
        var name: String { get }
        var manufacturer: String { get }
        var supportsDisplay: Bool { get }
        
        func start()
        func stop()
        func updateDisplay(deck: DeckID, data: DisplayData)
        
        var controlEvents: PassthroughSubject<ControlEvent, Never> { get }
    }
    
    enum ControlEvent {
        case playPause(deck: DeckID)
        case cue(deck: DeckID)
        case volume(deck: DeckID, value: Float)
        case eqLow(deck: DeckID, value: Float)
        case eqMid(deck: DeckID, value: Float)
        case eqHigh(deck: DeckID, value: Float)
        case jogWheel(deck: DeckID, delta: Float, isPressed: Bool)
        case crossfader(value: Float)
        case loadTrack(deck: DeckID)
        case hotCue(deck: DeckID, index: Int)
        // HyperMusic-specific: Select branch option via performance pad
        case selectBranchOption(index: Int)  // 0-7, maps to performance pad
    }
  ```


**2.2 Implement Numark NVII Controller**

- File: `MusicMill/Audio/Controllers/NumarkNVIIController.swift`

- MIDI CC mappings (to be determined via testing):

- Deck A/B play/pause buttons

- Deck A/B cue buttons

- Deck A/B volume faders

- Deck A/B EQ knobs (low/mid/high)

- Jog wheels (HID or MIDI)

- Performance pads (hot cues / branch selection)

- Crossfader

- Display support:

- **Left display (Deck A)**: Current playing phrase
  - Waveform visualization
  - Track title, artist, BPM, key
  - Playback position indicator

- **Right display (Deck B / Branch Options)**:
  - **If Deck B loaded**: Show Deck B phrase (for cueing/mixing)
  - **If Deck B not loaded**: Show up to 8 branch options in grid
    - Each option shows: waveform preview, track name, compatibility score
    - Highlighted option corresponds to pad selection
    - Performance pads 1-8 map to options 0-7

- Send waveform images via MIDI SysEx

- Send track metadata (title, BPM, key)

- Send branch options grid layout via MIDI SysEx

**2.3 Implement Pioneer XDJ-XZ Controller**

- File: `MusicMill/Audio/Controllers/PioneerXDJXZController.swift`

- Similar structure to NVII

- Different MIDI CC mappings

- Display support:

- Central 7" touchscreen
- On-jog displays
- Different SysEx protocol

### Phase 3: Control Mapping System

**3.1 Create Control Mapper**

- File: `MusicMill/Audio/ControlMapper.swift`

- Responsibilities:

- Map `ControlEvent` → Deck/DJMixer function calls

- Handle jog wheel → position seeking

- Apply smoothing/filtering for knobs/faders

- Support custom mapping profiles

- Key methods:
  ```swift
    func mapEvent(_ event: ControlEvent, to deckA: Deck, deckB: Deck, mixer: DJMixerViewModel)
    func setJogWheelSensitivity(_ sensitivity: Float)
    func setKnobSmoothing(_ enabled: Bool)
  ```


**3.2 Integration with DJMixerViewModel and HyperMusic**

- Modify: `MusicMill/Performance/DJMixerView.swift`
- Add `@StateObject var controllerManager: ControllerManager`
- Connect controller events to deck/mixer functions
- Integrate HyperMusic branch selection via performance pads

- Example mapping:
  ```swift
    controllerManager.controlEvents
        .sink { event in
            switch event {
            case .playPause(let deck):
                (deck == .a ? viewModel.deckA : viewModel.deckB).togglePlayPause()
            case .volume(let deck, let value):
                (deck == .a ? viewModel.deckA : viewModel.deckB).volume = value
            case .selectBranchOption(let index):
                // HyperMusic: Load selected branch option to Deck B
                if index < viewModel.branchOptions.count {
                    let selectedOption = viewModel.branchOptions[index]
                    viewModel.loadToCue(selectedOption.phrase)
                }
            // ... etc
            }
        }
    
    // Setup display observation
    controllerManager.observeDeckState(
        deckA: viewModel.deckA,
        deckB: viewModel.deckB,
        viewModel: viewModel
    )
  ```


**3.3 Performance Pad Mapping for Branch Selection**

- Modify: `MusicMill/Audio/Controllers/NumarkNVIIController.swift`
- Map Deck B performance pads (8 pads) to branch option selection
- When Deck B is not loaded:
  - Pads 1-8 → `ControlEvent.selectBranchOption(index: 0-7)`
- When Deck B is loaded:
  - Pads function as normal hot cues
- Visual feedback: Highlight selected pad on display (if supported)

### Phase 4: Display Output System with HyperMusic Integration

**4.1 Create Display Data Structure**

- File: `MusicMill/Audio/DisplayData.swift`
- Structure:
  ```swift
    struct DisplayData {
        var waveform: WaveformData?
        var trackTitle: String
        var artist: String
        var bpm: Int
        var key: String?
        var playbackPosition: Double
        var isPlaying: Bool
    }
    
    // For branch options display (right screen when Deck B not loaded)
    struct BranchOptionsDisplayData {
        var options: [BranchOptionDisplay]  // Up to 8 options
        var selectedIndex: Int?  // Highlighted option
    }
    
    struct BranchOptionDisplay {
        var phrase: PhraseNode
        var waveform: WaveformData?
        var score: Double
        var index: Int  // 0-7 for pad mapping
    }
  ```


**4.2 Implement Display Renderer**

- File: `MusicMill/Audio/DisplayRenderer.swift`
- Responsibilities:

- Convert `WaveformData` to image (RGB bitmap)

- Compress image for MIDI SysEx transmission

- Format text metadata

- Render branch options grid (up to 8 options with waveforms)

- Methods:
  ```swift
    func renderWaveform(_ waveform: WaveformData, size: CGSize) -> NSImage
    func renderBranchOptions(_ data: BranchOptionsDisplayData, size: CGSize) -> NSImage
    func compressImage(_ image: NSImage) -> Data
    func formatMetadata(_ data: DisplayData) -> Data
  ```


**4.3 Update Display Output with HyperMusic Integration**

- Modify: `MusicMill/Audio/ControllerManager.swift`
- Responsibilities:
  - Monitor Deck A state → update left display (current playing phrase)
  - Monitor Deck B state → update right display:
    - If Deck B loaded: show Deck B phrase (for cueing)
    - If Deck B not loaded: show branch options from current phrase
  - Subscribe to `DJMixerViewModel.branchOptions` changes
  - Update displays when:
    - Deck A phrase changes
    - Deck B loads/unloads
    - Branch options update (from `updateBranchOptions(for:)`)
    - Playback position updates (throttled to ~30fps)

- Integration with `DJMixerViewModel`:
  ```swift
  // In ControllerManager
  func observeDeckState(deckA: Deck, deckB: Deck, viewModel: DJMixerViewModel) {
      // Left display: Always show Deck A
      deckA.$currentPhrase
          .combineLatest(deckA.$playbackPosition, deckA.$isPlaying)
          .sink { [weak self] phrase, position, isPlaying in
              self?.updateLeftDisplay(phrase: phrase, position: position, isPlaying: isPlaying)
          }
      
      // Right display: Deck B if loaded, else branch options
      Publishers.CombineLatest3(
          deckB.$isLoaded,
          deckB.$currentPhrase,
          viewModel.$branchOptions
      )
      .sink { [weak self] isLoaded, phrase, options in
          if isLoaded, let phrase = phrase {
              // Show Deck B phrase
              self?.updateRightDisplay(phrase: phrase, position: deckB.playbackPosition, isPlaying: deckB.isPlaying)
          } else {
              // Show branch options
              let displayOptions = Array(options.prefix(8)).enumerated().map { index, option in
                  BranchOptionDisplay(phrase: option.phrase, waveform: option.phrase.waveform, score: option.score, index: index)
              }
              self?.updateRightDisplayBranchOptions(displayOptions)
          }
      }
  }
  ```


### Phase 5: Controller Manager

**5.1 Create Controller Manager**

- File: `MusicMill/Audio/ControllerManager.swift`

- Responsibilities:

- Auto-detect connected controllers

- Manage controller lifecycle

- Route input/output

- Provide UI for controller selection

- Key properties:
  ```swift
    @Published var availableControllers: [DJController]
    @Published var activeController: DJController?
    var controlEvents: PassthroughSubject<ControlEvent, Never>
  ```


**5.2 Controller Discovery**

- Scan for MIDI devices matching known controller names

- Check HID devices for jog wheel characteristics

- Present list in UI for manual selection

### Phase 6: Testing & Configuration

**6.1 Create MIDI CC Mapping Configuration**

- File: `MusicMill/Audio/ControllerMappings.swift`

- Store default mappings for each controller

- Allow user customization (future enhancement)

- Format:
  ```swift
    struct ControllerMapping {
        let playPauseCC: [UInt8]  // [DeckA, DeckB]
        let cueCC: [UInt8]
        let volumeCC: [UInt8]
        let eqLowCC: [UInt8]
        // ... etc
    }
  ```


**6.2 Add Controller Selection UI**

- Modify: `MusicMill/Performance/DJMixerView.swift`

- Add controller selection menu in header

- Show connection status

- Display active mappings

## File Structure

```javascript
MusicMill/
├── Audio/
│   ├── MIDIInputHandler.swift          (NEW)
│   ├── HIDInputHandler.swift            (NEW)
│   ├── MIDITypes.swift                  (NEW)
│   ├── DJController.swift               (NEW - protocol)
│   ├── ControlMapper.swift              (NEW)
│   ├── ControllerManager.swift          (NEW)
│   ├── DisplayData.swift                (NEW)
│   ├── DisplayRenderer.swift            (NEW)
│   ├── ControllerMappings.swift         (NEW)
│   ├── Controllers/
│   │   ├── NumarkNVIIController.swift   (NEW)
│   │   └── PioneerXDJXZController.swift (NEW)
│   ├── Deck.swift                       (EXISTING - integrate display updates)
│   └── AudioRouter.swift                (EXISTING)
└── Performance/
    └── DJMixerView.swift                (MODIFY - add controller integration)
```

## Testing Strategy

1. **Phase 1 Testing (NVII)**

- Connect NVII via USB

- Test MIDI input detection

- Map each control manually (document CC numbers)

- Test jog wheel input (HID or MIDI)

- Verify display output (waveform, metadata)

2. **Phase 2 Testing (XDJ-XZ)**

- Repeat with XDJ-XZ

- Document differences in CC mappings

- Test display protocols

3. **Integration Testing**

- Full DJ performance workflow

- Beat matching with jog wheels

- EQ mixing

- Crossfader transitions

- Hot cue triggering

4. **HyperMusic Integration Testing**

- Verify left display shows current playing phrase (Deck A)

- Verify right display shows branch options when Deck B not loaded

- Test performance pad selection of branch options (1-8)

- Verify selected option loads to Deck B for cueing

- Test transition workflow: select branch → cue → mix in → execute transition

- Verify display updates when Deck B loads/unloads

- Test with different numbers of branch options (1-8)

## Dependencies

- CoreMIDI framework (system)

- IOKit.hid framework (system)

- Combine framework (already used)

- CoreGraphics (for display rendering)

## Future Enhancements

- Custom mapping profiles (save/load)

- Multiple controller support

- Controller-specific features (e.g., XDJ-XZ standalone mode)