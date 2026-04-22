# Seeed Recorder

Retrospective audio recorder for Eurorack/studio use. A Seeed Xiao RP2040 in a Eurorack module provides a button + LED; a macOS menu-bar app continuously buffers multichannel audio to disk, and the button captures the last N minutes into per-channel WAV files.

## Repo layout

- `firmware/` — Arduino sketch for the Seeed Xiao RP2040
- `mac-app/` — Xcode project for the macOS menu-bar app ("Retrospective")
- `hardware/` — panel design, schematic (future)
- `docs/` — design docs and notes

## Architecture

- **Transport**: USB MIDI, class-compliant. Seeed enumerates as "Seeed Recorder". Any MIDI controller sending the same Note can also trigger.
- **Seeed role**: button + LED only; no audio.
- **Mac app role**: CoreAudio capture, rolling disk buffer, MIDI I/O, WAV extraction on trigger.

### MIDI protocol

Channel 16, Note 60:

| Direction | Message | Meaning |
|---|---|---|
| Seeed → Mac | Note On vel 127 | Button pressed |
| Seeed → Mac | Note Off | Button released (app currently ignores) |
| Mac → Seeed | Note On vel 127 | LED solid (armed/capturing) |
| Mac → Seeed | Note On vel 1 | LED off |

### Capture semantics

- Lookback default **5 minutes**, user-configurable (30 s – 30 min).
- **First press**: capture window starts at `now − lookback`. LED solid.
- **Second press**: capture window ends at `now`. Extract to WAV files. LED off. Auto-rearm.
- Buffer strategy: **rolling on-disk scratch file per channel** (circular write), size = `lookback × sampleRate × bytesPerSample`. Survives crashes, bounded.

### Audio / files

- Match the interface's native sample rate and bit depth.
- Target device: Focusrite Scarlett 16i6 (up to 16 channels), but any CoreAudio input device works.
- User configures each channel: `Off` | `Mono` | `Stereo L (pairs with next)` | `Stereo R`.
- Saved files: `YYYY-MM-DD_HH-MM-SS_ch01_Label.wav` for mono, or `..._ch01-02_Label.wav` for stereo pairs. Timestamp = first-press wall-clock time (start of captured window).
- Ableton can't read multichannel WAVs — stereo pairs emit one interleaved stereo file; monos stay separate.

## Hardware wiring (Seeed Xiao RP2040)

**Button** (momentary tactile): leg 1 → GPIO `D0`, leg 2 → `GND`. Configure pin `INPUT_PULLUP`. No external resistor. Debounce ~20 ms in firmware.

**LED**: GPIO `D1` → 220 Ω resistor → LED anode → LED cathode → `GND`. Pin HIGH = on. Use red or yellow LED (Vf ≈ 2.0 V). Blue/green/white (Vf ≈ 3.0–3.2 V) won't run well at 3.3 V drive.

**Power**: USB cable from the module's panel jack to the Mac. No Eurorack bus power in v1.

## Dev environment

- **macOS target**: Sonoma (14) or later.
- **Mac app**: Xcode project (SwiftUI + `MenuBarExtra`), edited in VS Code via the Swift extension, built and run from Xcode (⌘R). Debugging is better in Xcode.
- **Firmware**: Arduino IDE 2.x with the **arduino-pico** core (Earle Philhower) and **Adafruit TinyUSB Library**. Board: "Seeed XIAO RP2040". USB Stack: "Adafruit TinyUSB".

## Build order

1. Firmware (button + LED + MIDI). Verifiable with any MIDI monitor app.
2. Mac app skeleton: menu-bar UI, settings window, device enumeration.
3. CoreAudio capture + rolling disk buffer.
4. Save path: MIDI-triggered WAV extraction.
5. Polish: reconnect handling, code signing, app icon.

## Conventions

- Small commits on `main` for now (solo project, no PR overhead).
- No secrets in repo. No generated build artifacts committed.
- User (n8synth builder) is experienced with analog Eurorack and comfortable with Arduino; less familiar with macOS app development — explain Swift/CoreAudio choices more fully than firmware choices.
