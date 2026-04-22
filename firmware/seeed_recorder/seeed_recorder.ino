// Seeed Recorder firmware — USB MIDI button/LED module.
//
// Button on D5 → Note On ch16 note60 vel127 (release: Note Off).
// Incoming Note On ch16 note60: vel127 → LED solid, vel1 → LED off.
// Any other note/channel is ignored.

#include <Arduino.h>
#include <Adafruit_TinyUSB.h>
#include <MIDI.h>

Adafruit_USBD_MIDI usb_midi;
MIDI_CREATE_INSTANCE(Adafruit_USBD_MIDI, usb_midi, MIDI);

const uint8_t LED_PIN          = D0;
const uint8_t BTN_PIN          = D5;
const uint8_t MIDI_CH          = 16;
const uint8_t MIDI_NOTE        = 60;
const unsigned long DEBOUNCE_MS = 20;

int lastStableLevel = HIGH;
int lastReadLevel   = HIGH;
unsigned long lastChangeMs = 0;

void handleNoteOn(byte channel, byte note, byte velocity) {
  if (channel != MIDI_CH || note != MIDI_NOTE) return;
  if (velocity == 127)     digitalWrite(LED_PIN, HIGH);
  else if (velocity == 1)  digitalWrite(LED_PIN, LOW);
}

void setup() {
  TinyUSBDevice.setManufacturerDescriptor("n8synth");
  TinyUSBDevice.setProductDescriptor("Seeed Recorder");
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

  int reading = digitalRead(BTN_PIN);
  if (reading != lastReadLevel) {
    lastChangeMs = millis();
    lastReadLevel = reading;
  }
  if ((millis() - lastChangeMs) > DEBOUNCE_MS && reading != lastStableLevel) {
    lastStableLevel = reading;
    if (lastStableLevel == LOW) {
      MIDI.sendNoteOn(MIDI_NOTE, 127, MIDI_CH);
    } else {
      MIDI.sendNoteOff(MIDI_NOTE, 0, MIDI_CH);
    }
  }
}
