# Future Ideas & Roadmap

## Rekordbox Integration

### Reading Rekordbox Data
- **Crate Digger** ([github.com/Deep-Symmetry/crate-digger](https://github.com/Deep-Symmetry/crate-digger)) - Java library for reading Rekordbox databases and ANLZ files
- **rekordbox-parse** - Python tools exist for parsing Rekordbox data
- Rekordbox stores data in:
  - `rekordbox.db` (SQLite) or newer `.edb` format
  - `.anlz` files on USB exports (waveforms, cue points, beat grids)
  - Some metadata in ID3 tags (`GEOB` frames)

### Potential Features
1. **Import cue points** - Use existing Rekordbox hot cues and memory cues as phrase markers or branch hints
2. **Import beat grids** - Use Rekordbox's beat analysis to improve phrase boundary accuracy
3. **Export phrase boundaries** - Write phrase start points back as Rekordbox memory cues
4. **Sync energy/mood tags** - Map Rekordbox's "My Tag" categories to phrase properties

### Implementation Notes
- Most cue point data is in Rekordbox's database, not in MP3 files directly
- USB exports contain `.anlz` files which are easier to parse
- Consider supporting both import from Rekordbox DB and from exported USB drives

---

## Other Future Ideas

### Audio Analysis
- [ ] Integrate with Rekordbox beat grids for more accurate phrase boundaries
- [ ] Use existing cue points as hints for phrase segmentation

### Performance Features  
- [ ] MIDI controller support (jog wheels, faders, buttons)
- [ ] OSC protocol for external control
- [ ] Ableton Link for tempo sync with other apps

### Data & History
- [ ] Import performance history from Rekordbox to seed transition ratings
- [ ] Export successful transitions as Rekordbox playlists

