# Seeed Recorder

Retrospective multichannel audio recorder. The Mac continuously buffers audio from your CoreAudio input device into a rolling on-disk ring; pressing a USB-MIDI button captures the last few minutes into per-channel 32-bit float WAV files.

Built for studio / Eurorack workflows where the best take just happened and you weren't recording.

## How it works

A Seeed Xiao RP2040 inside a Eurorack module presents itself to the Mac as a class-compliant USB MIDI device named **"Seeed Recorder"**. It has one button and one LED. The button sends Note On ch16 note60 vel127. Incoming Note On ch16 note60 lights the LED (vel127 = on, vel1 = off). Any MIDI controller sending the same Note can also trigger.

The Mac app (also called Retrospective) lives in the menu bar. While running with an audio input selected, it continuously buffers all input channels to per-channel circular files in `~/Library/Application Support/Retrospective/scratch/`, sized to `lookback × sampleRate × bytesPerSample`. On a button press it pauses the writer, reads each channel chronologically in parallel, computes peak amplitude, skips channels below −60 dBFS as silent, and writes the rest as 32-bit float WAVs to the chosen output folder. Default lookback is 2 minutes; the buffer is bounded by definition.

Filenames follow `YYYY-MM-DD_HH-MM-SS_chNN.wav`, with the timestamp set at the moment the button was pressed.

## Components

- **`firmware/`** — Arduino sketch for the Seeed Xiao RP2040 (button → MIDI Note On, MIDI Note On → LED). Built with the arduino-pico core and Adafruit TinyUSB.
- **`mac-app/`** — SwiftUI `MenuBarExtra` app. CoreAudio capture, scratch buffer, CoreMIDI client, MIDI-triggered extraction, settings persistence.
- **`docs/`** — design notes.

## Hardware (v1)

- Seeed Xiao RP2040
- Momentary tactile switch — `D5` to `GND` (firmware uses `INPUT_PULLUP`)
- LED — `D0` → 220 Ω → LED anode (long leg); cathode (short leg) to `GND`. Use red or yellow; blue/green/white run dim at 3.3 V.
- USB cable from the module's panel jack to the Mac. No Eurorack bus power in v1.

## Requirements

- macOS 14 (Sonoma) or later
- For the Mac app: Xcode 15+ (uses `MenuBarExtra`), and `xcodegen` if you want to regenerate the project from `mac-app/project.yml`
- For the firmware: `arduino-cli` with the [`arduino-pico`](https://github.com/earlephilhower/arduino-pico) core and the Adafruit TinyUSB library

## Build

### Firmware

From `firmware/seeed_recorder/`:

```sh
make upload      # compile + upload via arduino-cli (PORT=/dev/cu.usbmodemXXXX)
```

The Makefile bakes in the `usbstack=tinyusb` FQBN extension and the build-time flags that make the device enumerate as **"Seeed Recorder"**.

### Mac app

From `mac-app/`:

```sh
make install     # Release build → /Applications/Retrospective.app
make run         # launch it (look for the icon in the menu bar)
make icon        # regenerate AppIcon set from scripts/icon-source.jpg
```

The app is ad-hoc signed for local use. On first capture macOS will prompt for microphone access; click Allow. To launch automatically at login: System Settings → General → Login Items → drag `/Applications/Retrospective.app` into "Open at Login".

## Repo layout

```
firmware/
  button_led_test/         minimal wiring sanity sketch (no USB)
  seeed_recorder/          production sketch + Makefile
mac-app/
  project.yml              xcodegen project spec
  Makefile                 release / install / icon helpers
  scripts/
    generate-icon.swift    AppIcon generator
    icon-source.jpg        eight4awish magpie logo (used as icon source)
  Retrospective/           Swift sources, entitlements, asset catalog
hardware/                   panel design, schematic (TBD)
docs/                       design notes
```

## License

MIT — see [LICENSE](LICENSE).
