#!/usr/bin/env python3
"""DHT11 Prometheus exporter.

Reads CSV temperature/humidity lines from an Arduino over USB serial and
exposes them as gauges for Prometheus to scrape.

Config (environment variables):
  DHT_PORT       Serial device (default: /dev/ttyACM0)
  DHT_BAUD       Baud rate (default: 9600)
  DHT_TIMEOUT    Serial read timeout, seconds (default: 2.0)
  METRICS_PORT   Port to expose /metrics on (default: 9101)
  METRICS_ADDR   Address to bind (default: 127.0.0.1)

Exposes:
  dht_temperature_celsius              latest reading
  dht_humidity_percent                 latest reading
  dht_last_reading_timestamp_seconds   unix ts of last reading (0 = never)
"""

import os
import sys
import time

import serial
from prometheus_client import Gauge, start_http_server


temperature_c = Gauge(
    "dht_temperature_celsius",
    "Most recent DHT temperature reading in Celsius.",
)
humidity_pct = Gauge(
    "dht_humidity_percent",
    "Most recent DHT humidity reading in percent.",
)
last_reading_ts = Gauge(
    "dht_last_reading_timestamp_seconds",
    "Unix timestamp of the most recent successful reading (0 = none yet).",
)


def read_loop(port: str, baud: int, serial_timeout: float) -> None:
    while True:
        try:
            with serial.Serial(port, baud, timeout=serial_timeout) as ser:
                time.sleep(2)  # Arduino resets when the port opens
                ser.reset_input_buffer()
                while True:
                    line = ser.readline().decode("utf-8", errors="replace").strip()
                    if not line:
                        continue
                    parts = line.split(",")
                    if len(parts) != 2:
                        print(f"skip: {line!r}", file=sys.stderr)
                        continue
                    try:
                        t, h = (float(p) for p in parts)
                    except ValueError:
                        print(f"skip: {line!r}", file=sys.stderr)
                        continue
                    temperature_c.set(round(t, 1))
                    humidity_pct.set(round(h, 1))
                    last_reading_ts.set_to_current_time()
        except serial.SerialException as exc:
            # Keep the metrics endpoint up so Prom can still scrape and
            # surface staleness via dht_last_reading_timestamp_seconds.
            print(f"serial error: {exc}", file=sys.stderr)
            time.sleep(5)


def main() -> None:
    port = os.environ.get("DHT_PORT", "/dev/ttyACM0")
    baud = int(os.environ.get("DHT_BAUD", "9600"))
    serial_timeout = float(os.environ.get("DHT_TIMEOUT", "2.0"))
    metrics_port = int(os.environ.get("METRICS_PORT", "9101"))
    metrics_addr = os.environ.get("METRICS_ADDR", "127.0.0.1")

    temperature_c.set(float("nan"))
    humidity_pct.set(float("nan"))
    last_reading_ts.set(0)

    start_http_server(metrics_port, addr=metrics_addr)
    print(f"metrics on http://{metrics_addr}:{metrics_port}/metrics", flush=True)

    try:
        read_loop(port, baud, serial_timeout)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
