# Seeed Recorder

Retrospective multichannel audio recorder. The Mac continuously buffers audio from your CoreAudio input device into a rolling on-disk ring; pressing a button on either of two Eurorack modules captures the last few minutes into per-channel 32-bit float WAV files.

Built for studio / Eurorack workflows where the best take just happened and you weren't recording.

## How it works

The Mac app ("Retrospective") lives in the menu bar and continuously buffers every enabled channel from your CoreAudio input device to per-channel circular files in `~/Library/Application Support/Retrospective/scratch/`, sized to `lookback × sampleRate × bytesPerSample`. Default lookback is 5 minutes; the buffer is bounded by definition.

On a capture trigger it pauses the writer, reads each channel chronologically in parallel, and writes the rest as 32-bit float WAVs to the chosen output folder.

Three trigger paths fire the same capture engine and produce identical output:

| Path | Module | Transport | Best for |
|---|---|---|---|
| USB-MIDI | Seeed Xiao RP2040 (this repo) | USB-MIDI class-compliant | Desk-side rig with a USB cable to the Mac |
| HTTP/mDNS | Xiao ESP32-C5 (sibling repo `eurorack_modules`) | HTTP POST over WiFi | Mobile rig that moves around |
| Menu bar | (none) | UI click | Testing, or no module reachable |

Any MIDI controller sending the same Note can also trigger.

While the Mac app is running it joins the local Ableton Link network as a follower. If a Link session is active, the current tempo is baked into the captured filenames and WAV metadata so the take never loses its musical context.

Filenames: `YYYY-MM-DD_HH-MM-SS[_<bpm>bpm]_ch<NN>[-<NN>].wav`. The BPM segment is included only when a Link session is active.

## Components

- **`firmware/`** — Arduino sketch for the Seeed Xiao RP2040 (button → MIDI Note On, MIDI Note On → LED). Built with the arduino-pico core and Adafruit TinyUSB.
- **`mac-app/`** — SwiftUI `MenuBarExtra` app. CoreAudio capture, scratch buffer, CoreMIDI client, HTTP/mDNS server, Link follower, manual menu-bar trigger, settings persistence.
- **`docs/`** — design notes.

The Xiao ESP32-C5 module's firmware (the HTTP/mDNS trigger path) lives in the sibling [`eurorack_modules`](https://github.com/Eight4aWish/eurorack_modules) repo as `esp32-clklinkrec`. The HTTP wire contract is documented at [`eurorack_modules/docs/RECORDER_PROTOCOL.md`](https://github.com/Eight4aWish/eurorack_modules/blob/main/docs/RECORDER_PROTOCOL.md).

## Hardware (RP2040 module)

- Seeed Xiao RP2040
- Momentary tactile switch — `D5` to `GND` (firmware uses `INPUT_PULLUP`)
- LED — `D0` → 220 Ω → LED anode (long leg); cathode (short leg) to `GND`. Use red or yellow; blue/green/white run dim at 3.3 V.
- USB cable from the module's panel jack to the Mac. No Eurorack bus power in v1.

The ESP32-C5 module's hardware lives in the sibling `eurorack_modules` repo; it adds WiFi, Ableton Link clock outputs, and the Capture button feeds the same Mac app.

## Requirements

- macOS 14 (Sonoma) or later
- For the Mac app: Xcode 15+ (uses `MenuBarExtra`), and `xcodegen` if you want to regenerate the project from `mac-app/project.yml`
- For the RP2040 firmware: `arduino-cli` with the [`arduino-pico`](https://github.com/earlephilhower/arduino-pico) core and the Adafruit TinyUSB library
- For the C5 firmware: see the `eurorack_modules` repo (PlatformIO + pioarduino)

## Build

### RP2040 firmware

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
  seeed_recorder/          production RP2040 sketch + Makefile
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
