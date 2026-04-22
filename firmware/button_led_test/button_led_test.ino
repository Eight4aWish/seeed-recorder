// Wiring test: press button on D5 to toggle LED on D0.
// No MIDI, no USB stack requirements — plain Arduino.

#include <Arduino.h>

const uint8_t LED_PIN = D0;
const uint8_t BTN_PIN = D5;
const unsigned long DEBOUNCE_MS = 20;

bool ledOn = false;
int  lastStableLevel = HIGH;   // INPUT_PULLUP: released = HIGH, pressed = LOW
int  lastReadLevel   = HIGH;
unsigned long lastChangeMs = 0;

void setup() {
  pinMode(LED_PIN, OUTPUT);
  pinMode(BTN_PIN, INPUT_PULLUP);
  digitalWrite(LED_PIN, LOW);

  Serial.begin(115200);
}

void loop() {
  int reading = digitalRead(BTN_PIN);

  if (reading != lastReadLevel) {
    lastChangeMs = millis();
    lastReadLevel = reading;
  }

  if ((millis() - lastChangeMs) > DEBOUNCE_MS && reading != lastStableLevel) {
    lastStableLevel = reading;

    // Toggle on press edge (HIGH -> LOW).
    if (lastStableLevel == LOW) {
      ledOn = !ledOn;
      digitalWrite(LED_PIN, ledOn ? HIGH : LOW);
      Serial.println(ledOn ? "LED ON" : "LED OFF");
    }
  }
}
