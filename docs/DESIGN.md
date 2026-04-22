# Design

## Problem

A Eurorack musician often produces a great take they weren't recording. A retrospective recorder continuously captures audio and lets the user save a window ending at the moment they realize "that was good."

## Requirements

- Capture via a button on a Eurorack module, with LED feedback.
- Re-usable trigger: any MIDI controller with a button should also be able to fire it.
- Multichannel support (up to 16 channels from a Focusrite Scarlett 16i6).
- Per-channel configuration: mono or stereo pair.
- WAV output compatible with Ableton (i.e. no multichannel WAVs — emit sibling files).
- Two-press capture: first press = "save the last N minutes starting from now," second press = "stop; the captured window extends to now."
- Default lookback: 5 minutes, user-configurable.
- Auto-rearm after save.
- Mac app keeps buffering if the Seeed is unplugged; button triggers simply become unavailable until reconnect.

## Architecture

### Transport: USB MIDI

MIDI class-compliant. Zero drivers, works alongside any DAW, allows reuse from any MIDI controller.

See [CLAUDE.md](../CLAUDE.md) for the protocol table.

### Seeed firmware

Arduino + Adafruit TinyUSB on the arduino-pico core. Single `.ino` file.

- Poll button on `D0` with internal pull-up. Debounce ~20 ms.
- On press, send Note On (ch 16, note 60, vel 127). On release, Note Off.
- Listen for incoming Note On ch 16 note 60: velocity 127 → LED solid; velocity 1 → LED off.
- (Later: could support a "armed but idle" blink state via velocity 64.)

### Mac app: Retrospective

SwiftUI + AppKit, macOS Sonoma+, menu-bar app via `MenuBarExtra`.

#### CoreAudio capture

- Enumerate devices with `AudioObjectGetPropertyData` on `kAudioHardwarePropertyDevices`.
- User selects device; open at its native sample rate and bit depth.
- Input render callback fans interleaved frames out per channel.

#### Rolling disk buffer

- Scratch directory: `~/Library/Application Support/Retrospective/buffer/`.
- One fixed-size file per enabled channel, written circularly.
- File size = `lookback × sampleRate × bytesPerSample` (e.g. ~43 MB per channel for 5 min @ 48 kHz / 24-bit).
- Track `(currentWritePosition, timestampAtPosition)` in memory; persist periodically so a restart can roughly resume.

#### MIDI I/O

- `MIDIClientCreate`, `MIDIInputPortCreate`. Listen for Note On ch 16 note 60.
- On first press: note `startTime = now − lookback`. Send LED-solid message.
- On second press: note `endTime = now`. Send LED-off message. Schedule extraction on background queue. Rearm.

#### Extraction

For each enabled channel:

- If mono: write one WAV spanning `[startTime, endTime]` from that channel's scratch file.
- If stereo L: read from its channel and its paired (+1) channel, interleave, write one stereo WAV.
- Filename: `YYYY-MM-DD_HH-MM-SS_ch<NN>[-<NN>]_Label.wav`.

#### Settings UI

- Device picker.
- Output folder (NSOpenPanel, store security-scoped bookmark).
- Lookback seconds slider (30 s – 30 min).
- Channel table: row per channel with Enable, Role (Off / Mono / Stereo L / Stereo R), Label.

#### Sandbox / entitlements

- Audio Input
- User-Selected File (Read/Write) for output folder
- Security-scoped bookmark for persistence across launches

#### Disconnect handling

- MIDI source disappearance → menu bar icon goes grey; LED commands no-op. Audio capture continues so a reconnect resumes immediately.
- MIDI source reappearance → resumes normal operation.

## Deferred to v2

- CV/gate input on the module (trigger saves from a patch).
- Gate output (recording-state signal for routing).
- Multiple buttons for tagged takes (good / idea / weird).
- "Armed but idle" LED blink state.
- Handling of sample-rate changes mid-session.
