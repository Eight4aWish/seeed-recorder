# Seeed Recorder

Retrospective audio recorder for Eurorack/studio use. A macOS menu-bar
app continuously buffers multichannel audio to disk; a button press on
either of two Eurorack modules captures the last N minutes into
per-channel WAV files. The two modules use different transports but
trigger the *same* capture engine and produce *identical* output.

## Repo layout

- `firmware/` — Arduino sketch for the Seeed Xiao RP2040 module
- `mac-app/` — Xcode project for the macOS menu-bar app ("Retrospective")
- `hardware/` — panel design, schematic (future)
- `docs/` — design docs and notes

The companion Xiao ESP32-C5 module lives in the sibling
[`eurorack_modules`](https://github.com/Eight4aWish/eurorack_modules)
repo as `esp32-clklinkrec`. Its firmware uses the same Mac app via a
different transport.

## Architecture

Two trigger paths into one capture engine. Both produce the same
file format (see "Audio / files" below).

| Trigger path | Module | Transport | Use case |
|---|---|---|---|
| USB-MIDI | Seeed Xiao RP2040 (this repo's `firmware/`) | USB-MIDI class-compliant. Module enumerates as "Seeed Recorder". Any MIDI controller sending the same Note can also trigger. | Desktop rig — module sits next to the Mac with a USB cable from the panel jack. |
| HTTP/mDNS | Xiao ESP32-C5 (`esp32-clklinkrec` in `eurorack_modules` repo) | HTTP POST over WiFi. Mac app advertises via Bonjour. | Mobile rig — module moves around and connects over WiFi without a cable. |
| Manual | (none) | Menu-bar UI click | Testing, or when neither module is reachable. |

### MIDI protocol (RP2040 trigger path)

Channel 16, Note 60. Single press = one trigger event; there is no two-press
window. The firmware has never had two-press logic — the old two-press
semantics lived only on the Mac side and have been removed.

| Direction | Message | Meaning |
|---|---|---|
| Seeed → Mac | Note On vel 127 | Capture press. Firmware also lights its own LED locally at this moment — no Mac round-trip needed for the press feedback. |
| Seeed → Mac | Note Off | Released (app ignores) |
| Mac → Seeed | Note On vel 127 | LED solid (capture in flight). Redundant for the RP2040 button path; needed for menu-bar / HTTP triggers where the firmware didn't see the press. |
| Mac → Seeed | Note On vel 1 | LED off (idle, or successful capture round-trip) |
| Mac → Seeed | Note On vel 64 | LED blink at ~1 Hz (signals a capture error) |

The blink clears on the next vel 127 / vel 1 / vel 64 the firmware receives,
or on the next local button press.

### HTTP/mDNS protocol (C5 trigger path)

Fully specified in
[`eurorack_modules/docs/RECORDER_PROTOCOL.md`](https://github.com/Eight4aWish/eurorack_modules/blob/main/docs/RECORDER_PROTOCOL.md).

Summary:
- Mac advertises `_recorder._tcp.local.` on TCP/8765 via Bonjour
- `POST /capture` (empty body) triggers the same capture engine as a MIDI press
- `GET /healthz` returns version, buffer size, audio source, Link state
- `RECORDER_HOST` fallback in the firmware's secrets.h for networks where mDNS is blocked

### Capture semantics (both transports)

- Lookback default **60 seconds**, user-configurable (30 s – 30 min).
- One press = capture the last `lookback` seconds. Auto-rearm — no
  second press needed.
- While extraction is in flight (usually <2 s), additional presses
  from either trigger path are **ignored**. MIDI gets no response;
  HTTP gets `503 capture_in_flight`.
- Buffer strategy: **rolling on-disk scratch file per channel**
  (circular write), size = `lookback × sampleRate × bytesPerSample`.
  Survives crashes, bounded.

### Link participation

The Mac app joins the Ableton Link network as a **follower** whenever
it's running. It never proposes its own tempo. The Link tempo and play
state are read solely to enrich captures (BPM in filename + WAV
metadata). When no other Link peer is present on the LAN the BPM
information is omitted from captures.

### Audio / files

- Match the interface's native sample rate and bit depth (recorded as
  32-bit float regardless of source bit depth).
- Target device: Focusrite Scarlett 16i6 (up to 16 channels), but any
  CoreAudio input device works.
- Channel handling (current implementation): every input channel is captured;
  the user marks adjacent pairs as stereo via a toggle list in Settings.
  Marked pairs save as one interleaved 2-channel WAV (`ch<NN>-<MM>`);
  unmarked channels save as mono WAVs. At extraction, channels whose peak is
  below **−60 dBFS** are skipped as silence. (The fuller `Off / Mono / Stereo L /
  Stereo R` per-channel role table from the original spec is deferred — the
  lightweight model serves the current use cases.)
- Filename format:
  `YYYY-MM-DD_HH-MM-SS[_<bpm>bpm]_ch<NN>[-<NN>].wav`
  - Timestamp = wall-clock at trigger time
  - `<bpm>` segment included only when Link is active; rounded to nearest integer
  - `ch<NN>` for mono channels, `ch<NN>-<MM>` for stereo pairs
- Ableton can't read multichannel WAVs — stereo pairs emit one
  interleaved stereo file; monos stay separate.
- WAV metadata: BPM, Link play state, and capture timestamp are
  written into the LIST-INFO chunk (`ICMT`, `ICRD`, `ISFT`) so the
  tempo survives a rename.

## Hardware wiring (Seeed Xiao RP2040)

**Button** (momentary tactile): leg 1 → GPIO `D5`, leg 2 → `GND`. Configure pin `INPUT_PULLUP`. No external resistor. Debounce ~20 ms in firmware.

**LED**: GPIO `D0` → 220 Ω resistor → LED anode (long leg) → LED cathode (short leg) → `GND`. Pin HIGH = on. Use red or yellow LED (Vf ≈ 2.0 V). Blue/green/white (Vf ≈ 3.0–3.2 V) won't run well at 3.3 V drive.

**Power**: USB cable from the module's panel jack to the Mac. No Eurorack bus power in v1.

The Xiao ESP32-C5 module's wiring lives in the sibling
[`eurorack_modules`](https://github.com/Eight4aWish/eurorack_modules)
repo (`docs/ESP32_CLKLINKREC.md`).

## Dev environment

- **macOS target**: Sonoma (14) or later.
- **Mac app**: Xcode project (SwiftUI + `MenuBarExtra`), edited in VS Code via the Swift extension, built and run from Xcode (⌘R). Debugging is better in Xcode.
- **Firmware (RP2040)**: Arduino IDE 2.x with the **arduino-pico** core (Earle Philhower) and **Adafruit TinyUSB Library**. Board: "Seeed XIAO RP2040". USB Stack: "Adafruit TinyUSB".
- **Firmware (C5)**: see the `eurorack_modules` repo. Built with PlatformIO under pioarduino.

## Build order

1. Firmware (RP2040: button + LED + MIDI). Verifiable with any MIDI monitor app.
2. Mac app skeleton: menu-bar UI, settings window, device enumeration.
3. CoreAudio capture + rolling disk buffer.
4. Save path: MIDI-triggered WAV extraction.
5. **HTTP server + mDNS advertisement** (for the C5 trigger path). Same capture engine, new entry point.
6. **Ableton Link follower participation** for BPM-aware captures.
7. **Menu-bar manual trigger** for testing.
8. Polish: reconnect handling, code signing, app icon.

## Conventions

- Small commits on `main` for now (solo project, no PR overhead).
- No secrets in repo. No generated build artifacts committed.
- User (n8synth builder) is experienced with analog Eurorack and comfortable with Arduino; less familiar with macOS app development — explain Swift/CoreAudio choices more fully than firmware choices.
