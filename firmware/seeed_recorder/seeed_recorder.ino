// Seeed Recorder firmware — USB MIDI button/LED module.
//
// Capture trigger (Seeed → Mac):
//   Button edge on D5 → LED solid locally AND Note On ch16 note60 vel127.
//   Release           → Note Off.
//
// The LED lights locally on press so the user sees instant feedback without
// waiting for the Mac round-trip. The Mac then drives the LED's eventual
// state via Note On ch16 note60:
//   vel 127 → LED solid  (redundant for button presses; lights LED for HTTP /
//                         menu-bar triggers where the firmware didn't see the press)
//   vel 64  → LED blink  (~1 Hz; signals an error in the capture process)
//   vel 1   → LED off    (idle, or successful capture round-trip)
//
// Blink clears on the next vel 127 / vel 1 / vel 64 message, or on the next
// local button press.
//
// Any other channel, note, or velocity is ignored.

#include <Arduino.h>
#include <Adafruit_TinyUSB.h>
#include <MIDI.h>

Adafruit_USBD_MIDI usb_midi;
MIDI_CREATE_INSTANCE(Adafruit_USBD_MIDI, usb_midi, MIDI);

// Pins
const uint8_t LED_PIN = D0;
const uint8_t BTN_PIN = D5;

// MIDI protocol (CLAUDE.md)
const uint8_t MIDI_CH         = 16;
const uint8_t MIDI_NOTE       = 60;
const uint8_t VEL_PRESS       = 127;
const uint8_t VEL_LED_SOLID   = 127;
const uint8_t VEL_LED_ERROR   = 64;
const uint8_t VEL_LED_OFF     = 1;

// Timing
const unsigned long DEBOUNCE_MS    = 20;
const unsigned long BLINK_PERIOD_MS = 500;   // half-period; full blink = 1 s

enum LEDState : uint8_t { LED_OFF, LED_SOLID, LED_BLINK_ERROR };
LEDState ledState = LED_OFF;

int lastStableLevel = HIGH;
int lastReadLevel   = HIGH;
unsigned long lastChangeMs = 0;

void handleNoteOn(byte channel, byte note, byte velocity) {
  if (channel != MIDI_CH || note != MIDI_NOTE) return;
  switch (velocity) {
    case VEL_LED_SOLID: ledState = LED_SOLID;       break;
    case VEL_LED_ERROR: ledState = LED_BLINK_ERROR; break;
    case VEL_LED_OFF:   ledState = LED_OFF;         break;
    default: break;  // unknown velocity → no change
  }
}

void updateLED() {
  switch (ledState) {
    case LED_OFF:
      digitalWrite(LED_PIN, LOW);
      break;
    case LED_SOLID:
      digitalWrite(LED_PIN, HIGH);
      break;
    case LED_BLINK_ERROR: {
      // Drive HIGH for one half-period, LOW for the next. Idempotent each loop.
      bool on = ((millis() / BLINK_PERIOD_MS) % 2) == 0;
      digitalWrite(LED_PIN, on ? HIGH : LOW);
      break;
    }
  }
}

void setup() {
  // Device iManufacturer / iProduct are set at build time — see Makefile.
  // This sets only the MIDI interface (port) name.
  usb_midi.setStringDescriptor("Seeed Recorder");

  MIDI.begin(MIDI_CHANNEL_OMNI);
  MIDI.setHandleNoteOn(handleNoteOn);

  pinMode(LED_PIN, OUTPUT);
  pinMode(BTN_PIN, INPUT_PULLUP);
  digitalWrite(LED_PIN, LOW);

  Serial.begin(115200);
}

void loop() {
  MIDI.read();
  updateLED();

  int reading = digitalRead(BTN_PIN);
  if (reading != lastReadLevel) {
    lastChangeMs = millis();
    lastReadLevel = reading;
  }
  if ((millis() - lastChangeMs) > DEBOUNCE_MS && reading != lastStableLevel) {
    lastStableLevel = reading;
    if (lastStableLevel == LOW) {
      // Local feedback first — don't wait for the Mac round-trip.
      // Clears any sticky blink from a previous failed capture.
      ledState = LED_SOLID;
      MIDI.sendNoteOn(MIDI_NOTE, VEL_PRESS, MIDI_CH);
    } else {
      MIDI.sendNoteOff(MIDI_NOTE, 0, MIDI_CH);
    }
  }
}
