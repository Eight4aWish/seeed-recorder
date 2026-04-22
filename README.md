# Seeed Recorder

A retrospective audio recorder. The Mac app continuously buffers incoming audio to disk; pressing a button on a Eurorack module (or any MIDI controller) captures the last several minutes to WAV files.

Designed for studio/Eurorack workflows where the best take just happened and you weren't recording.

## Status

Early development.

## Components

- **Firmware** (`firmware/`) — Arduino sketch for a Seeed Xiao RP2040 inside a Eurorack module. Button + LED only; all audio stays on the Mac.
- **macOS app** (`mac-app/`) — menu-bar app ("Retrospective") that captures from a CoreAudio input device and writes WAV files on MIDI trigger.

## Hardware BOM (v1)

- Seeed Xiao RP2040
- Momentary tactile switch
- LED (red/yellow, Vf ≈ 2.0 V)
- 220 Ω resistor
- USB-C cable to Mac

## Requirements

- macOS Sonoma (14) or later
- Xcode (for building the Mac app)
- Arduino IDE 2.x with the arduino-pico core (for flashing firmware)

## Documentation

- [CLAUDE.md](CLAUDE.md) — concise architecture reference
- [docs/DESIGN.md](docs/DESIGN.md) — full design and rationale
