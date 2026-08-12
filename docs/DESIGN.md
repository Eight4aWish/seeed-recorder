# Design

## Problem

A Eurorack musician often produces a great take they weren't recording.
A retrospective recorder continuously captures audio and lets the user
save a window ending at the moment they realize "that was good."

## Requirements

- Capture via a button on a Eurorack module, with LED feedback.
- Two distinct module form factors, both first-class:
  - **RP2040 + USB-MIDI** for desk-side rigs where USB to the Mac is convenient.
  - **ESP32-C5 + HTTP/WiFi** for mobile rigs that move around and connect over the LAN.
- Re-usable trigger: any MIDI controller can fire it on the USB-MIDI path.
- Manual menu-bar trigger for testing / disconnected use.
- Multichannel support (tested on a Focusrite Scarlett 16i16 4th Gen, which exposes 18 input channels including a 2-channel loopback).
- Lightweight per-channel configuration: each input is saved as mono by default; the user may mark adjacent pairs as stereo. Silent channels (peak < −60 dBFS at extract time) are skipped.
- WAV output compatible with Ableton (no multichannel WAVs — emit sibling files).
- **One-press capture**: press = save the last N minutes ending at the moment of press. Auto-rearm.
- Default lookback: 60 seconds, user-configurable (30 s – 30 min).
- Mac app keeps buffering if the modules are disconnected; button triggers simply become unavailable until reconnect.
- BPM, when known, baked into both filename and WAV metadata. Known when the Mac app is currently joined to an Ableton Link session as a follower; unknown / omitted otherwise.

## Architecture

Two trigger transports, one capture engine, identical output.

```
   RP2040 module           Xiao ESP32-C5 module
       |                          |
   USB-MIDI                  HTTP POST (WiFi)
       |                          |
       v                          v
  +----------------------------------+
  |   Mac app: Retrospective         |
  |   ┌─ Trigger router ─┐           |
  |   ├─ CoreAudio buffer            |
  |   ├─ Link follower (BPM source)  |
  |   ├─ WAV extractor               |
  |   └─ Menu-bar UI (manual trigger)|
  +----------------------------------+
```

### Transport 1: USB MIDI (RP2040 module)

MIDI class-compliant. Zero drivers, works alongside any DAW, allows
reuse from any MIDI controller.

See [CLAUDE.md](../CLAUDE.md) for the protocol table.

### Transport 2: HTTP/mDNS over WiFi (ESP32-C5 module)

Discovery via Bonjour (`_recorder._tcp.local.` on TCP/8765); capture
via `POST /capture`; health via `GET /healthz`. Optional
`RECORDER_HOST` fallback in the firmware's `secrets.h` for networks
where mDNS doesn't work.

The full wire contract lives in the C5 firmware's repo:
[`eurorack_modules/docs/RECORDER_PROTOCOL.md`](https://github.com/Eight4aWish/eurorack_modules/blob/main/docs/RECORDER_PROTOCOL.md).
That document is the source of truth — when the protocol changes,
edit there first.

### Transport 3: Manual menu-bar trigger

Menu-bar UI click fires capture with identical semantics to the
module-driven paths. Useful for testing, for confirming the audio
buffer is healthy without a module reachable, and for one-off
captures when neither module is in the rig.

### Seeed RP2040 firmware

Arduino + Adafruit TinyUSB on the arduino-pico core. Single `.ino` file.

- Poll button on `D5` with internal pull-up. Debounce ~20 ms.
- On press, immediately set the local LED solid AND send Note On (ch 16,
  note 60, vel 127). The local LED light-up means the user sees instant
  feedback without waiting for the Mac round-trip; a pressed button always
  also clears any sticky error blink. On release, send Note Off.
- Listen for incoming Note On ch 16 note 60:
  - vel 127 → LED solid (capture in flight). Idempotent for button-triggered
    captures; this is what lights the LED for menu-bar / HTTP triggers where
    the firmware didn't see the press itself.
  - vel 64 → LED blink at ~1 Hz (capture error). Sticky until the next
    inbound Note On or local button press.
  - vel 1 → LED off (idle, or successful capture round-trip).

### Seeed C5 firmware

Lives in the sibling
[`eurorack_modules`](https://github.com/Eight4aWish/eurorack_modules)
repo as `esp32-clklinkrec`. Already implements the WiFi association,
Ableton Link sync (for clock/reset/run outputs), and Capture button
hardware. The HTTP POST flow is the remaining workstream on the
firmware side.

### Mac app: Retrospective

SwiftUI + AppKit, macOS Sonoma+, menu-bar app via `MenuBarExtra`.

#### CoreAudio capture

- Enumerate devices with `AudioObjectGetPropertyData` on `kAudioHardwarePropertyDevices`.
- User selects device; open at its native sample rate.
- Input render callback fans interleaved frames out per channel.

#### Rolling disk buffer

- Scratch directory: `~/Library/Application Support/Retrospective/scratch/`.
- One fixed-size file per enabled channel, written circularly.
- File size = `lookback × sampleRate × bytesPerSample` (e.g. ~43 MB per channel for 5 min @ 48 kHz / 24-bit).
- Track `(currentWritePosition, timestampAtPosition)` in memory; persist periodically so a restart can roughly resume.

#### Trigger router

A single internal "capture pressed" event feeds extraction. Sources:

1. MIDI listener (`MIDIClientCreate`, `MIDIInputPortCreate`, listen for Note On ch 16 note 60).
2. HTTP server (`POST /capture` on the mDNS-advertised port).
3. Menu-bar UI button.

While one extraction is in flight, additional events from any source
are dropped. The MIDI path gets no response; the HTTP path gets
`503 capture_in_flight`; the menu-bar button greys out.

#### Ableton Link follower

The app joins the Link network as a **follower** at launch and
remains joined for its lifetime. It never proposes a tempo. The
current tempo and play state are read at the moment of each capture
to enrich filenames and WAV metadata. If no other Link peer is
present on the LAN, both fields are absent and captures omit BPM
information entirely.

The same C library (`abl_link`) used by the C5 firmware should
underpin this on the Mac side.

#### Extraction

For each output unit (mono channel, or stereo pair if marked):

- Mono unit: read one channel chronologically and write a single-channel WAV.
- Stereo unit (a pair the user marked): read both channels and write one
  interleaved 2-channel WAV.
- Compute peak amplitude per unit; **skip units whose peak is below −60 dBFS**
  (the silence threshold) so disconnected / dead channels don't produce
  empty files.
- Filename: `YYYY-MM-DD_HH-MM-SS[_<bpm>bpm]_ch<NN>[-<NN>].wav`.
- Timestamp = wall-clock at trigger time.
- `<bpm>` segment included only when the Link follower currently has a tempo
  (rounded to nearest integer).
- WAV metadata: write BPM + Link play state + capture timestamp into the
  LIST-INFO chunk (`ICMT`, `ICRD`, `ISFT`) so tempo survives a rename.

#### Review window

Between capture and edit. Opened from the menu bar; reads the flat output
folder directly, so it works on captures made before it existed.

- **Sittings.** Captures within 30 minutes of each other are shown as one
  session. The threshold was measured against the real library rather than
  chosen: gaps inside a sitting reached 20.4 min, the next gap up was 52.9 min.
  Adjustable in Settings.
- **Audition.** One `AVAudioPlayerNode` per file into a shared mixer, all
  started at one `AVAudioTime`. Mute is `volume = 0` — stopping a node would
  desync it. Pause and seek stop every node and reschedule together. Playback
  streams via `scheduleSegment`; buffering 16 channels of a 30-minute capture
  would need ~5.5 GB. Per-track level, solo, loop region, output-device picker,
  master gain, and transient stepping for sparse channels.
- **Junk detection.** A single analysis pass yields peak, RMS, crest, DC offset,
  a windowed activity profile and a waveform envelope. A channel is flagged when
  it has almost no signal but a loud peak. The decisive metric is **absolute
  active time**, not activity as a fraction of the capture: a fraction scales
  with the lookback setting, and would have flagged a genuine 7.6 s take sitting
  in a 120 s window. Measured separation on the real library: 0.020 s of
  activity among flagged files against 2.56 s for the shortest kept one.
  Sustained audio registers as a *single* event, so event count only
  discriminates for intermittent material and serves as a secondary guard.
- **Cleanup.** Flagged files are pre-ticked but never acted on automatically;
  deletion is `trashItem`, so a misjudged call is recoverable from Finder.
- **Combine.** Two monos into one interleaved stereo, streamed rather than
  buffered, lower channel number to the left, originals to the Trash.
- **Tagging.** See "Metadata for DaVinci Resolve" below.

Analysis is computed during extraction, where the samples are already in RAM,
and cached by path + mtime + size — so a fresh capture opens instantly and a
retag (which rewrites the file) invalidates its entry automatically.

#### Metadata for DaVinci Resolve

Resolve reads two chunks beyond `LIST-INFO`, both written before `data`:

- **`bext`** — BWF, EBU Tech 3285. Fixed 602-byte Version 1 struct (Version 2
  would require 0x7FFF sentinels for the loudness fields we do not measure).
  Description carries a readable session line; OriginationDate/Time carry local
  wall clock. `TimeReference` is held at **0** so a capture's channels share a
  timecode and align to each other under *Auto Sync by Timecode*, without
  captures spreading across a 24-hour timeline.
- **`iXML`** — `SCENE`, `TAKE`, `NOTE`, `CIRCLED`, `PROJECT`, `TAPE`. Resolve
  20.2+ reads these actively and makes them searchable in the Media Pool.

Tagging happens after extraction, so it rewrites existing files: build a fresh
header, stream the untouched `data` payload after it, swap atomically with
`replaceItemAt`, then rename. The swap-before-rename order means a failed rename
still leaves a correctly tagged file. Audio is copied byte-for-byte and never
re-encoded, so repeated tagging is lossless.

#### Settings UI

- Audio input picker (CoreAudio devices, persisted by stable device UID).
- MIDI source / destination pickers (CoreMIDI endpoints).
- Output folder (NSOpenPanel; persisted as a plain path while the app is
  non-sandboxed; switch to a security-scoped bookmark when sandbox is enabled).
- Lookback seconds slider (30 s – 30 min).
- Stereo pair toggles (one per adjacent pair given the current channel count).
- Manual capture button (mirrors module presses).
- Read-only status row: current audio source, Link peer count, current tempo.

#### HTTP server / Bonjour

- Bind to LAN interfaces only, never public.
- Advertise `_recorder._tcp.local.` on TCP/8765 via NetService.
- TXT records: `version=2.0`, `app=seeed-recorder`, `link_peer=true|false`.
- Endpoints as specified in
  [`eurorack_modules/docs/RECORDER_PROTOCOL.md`](https://github.com/Eight4aWish/eurorack_modules/blob/main/docs/RECORDER_PROTOCOL.md).

#### Sandbox / entitlements

- Audio Input
- User-Selected File (Read/Write) for output folder
- Security-scoped bookmark for persistence across launches
- Network entitlements for the HTTP server and Bonjour advertisement
- (No authentication — relies on LAN trust)

#### Disconnect handling

- **USB MIDI**: source disappearance → menu bar icon goes grey; LED commands no-op. Audio capture continues so a reconnect resumes immediately.
- **HTTP**: WiFi or Bonjour going away has no Mac-side effect (the C5 just stops being able to reach us). Audio capture continues.
- Either way, the menu-bar manual trigger continues to work as long as the Mac app is running.

## Deferred to vN+1

- CV/gate input on the C5 module (trigger saves from a patch).
- Gate output (recording-state signal for routing).
- Multiple buttons for tagged takes (good / idea / weird).
- Per-channel names in the review window (iXML `TRACK_LIST`), so a 16-channel
  capture reads as "Kick / Bass / 303" in Resolve rather than by channel number.
- Group-level tagging — applying a name to a whole sitting at once.
- Capture by bar/beat boundary instead of fixed seconds, using the Link beat clock.
- Handling of sample-rate changes mid-session.
- Optional shared-secret HMAC on the HTTP path for untrusted LANs.
