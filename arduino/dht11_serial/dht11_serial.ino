// Reads a DHT11 and prints "<temp_c>,<humidity>" once per second.
// Pair with read_dht.py on the Raspberry Pi.
//
// Libraries (install via Arduino Library Manager):
//   - "DHT sensor library" by Adafruit
//   - "Adafruit Unified Sensor"

#include <DHT.h>

#define DHTPIN  2
#define DHTTYPE DHT11

DHT dht(DHTPIN, DHTTYPE);

void setup() {
  Serial.begin(9600);
  dht.begin();
}

void loop() {
  float h = dht.readHumidity();
  float t = dht.readTemperature();  // Celsius

  if (isnan(h) || isnan(t)) {
    // Skip bad reads; the Python side ignores non-CSV lines.
    delay(1000);
    return;
  }

  Serial.print(t, 1);
  Serial.print(',');
  Serial.println(h, 1);

  delay(1000);  // DHT11 sampling rate is ~1 Hz
}
