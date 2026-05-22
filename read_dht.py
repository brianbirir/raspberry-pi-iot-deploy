#!/usr/bin/env python3
"""Read DHT11 readings from an Arduino over serial and POST them to a remote
HTTP endpoint as JSON.

Config (environment variables):
  DHT_PORT          Serial device (default: /dev/ttyACM0)
  DHT_BAUD          Baud rate    (default: 9600)
  DHT_TIMEOUT       Serial read timeout, seconds (default: 2.0)
  TELEMETRY_URL     POST endpoint. If empty, readings are only logged.
  TELEMETRY_AUTH    Full Authorization header value, e.g. "Bearer abc123"
  TELEMETRY_TIMEOUT HTTP timeout, seconds (default: 5.0)
  DEVICE_ID         Identifier sent with each reading (default: hostname)

Payload format:
  {"ts": "<iso8601-utc>", "device": "<id>",
   "temperature_c": <float>, "humidity_pct": <float>}
"""

import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import serial


def post_reading(url: str, auth: str, payload: dict, timeout: float) -> None:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if auth:
        req.add_header("Authorization", auth)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if resp.status >= 300:
            raise urllib.error.HTTPError(
                url, resp.status, resp.reason, resp.headers, None
            )


def read_loop(port: str, baud: int, serial_timeout: float,
              url: str, auth: str, http_timeout: float,
              device: str) -> None:
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
                temp_c, humidity = (float(p) for p in parts)
            except ValueError:
                print(f"skip: {line!r}", file=sys.stderr)
                continue

            payload = {
                "ts": datetime.now(timezone.utc).isoformat(
                    timespec="seconds"
                ).replace("+00:00", "Z"),
                "device": device,
                "temperature_c": round(temp_c, 1),
                "humidity_pct": round(humidity, 1),
            }
            print(json.dumps(payload), flush=True)

            if not url:
                continue

            try:
                post_reading(url, auth, payload, http_timeout)
            except (urllib.error.URLError, urllib.error.HTTPError,
                    TimeoutError, OSError) as exc:
                # Drop this reading; the next one is ~1 s away.
                print(f"post failed: {exc}", file=sys.stderr)


def main() -> None:
    port = os.environ.get("DHT_PORT", "/dev/ttyACM0")
    baud = int(os.environ.get("DHT_BAUD", "9600"))
    serial_timeout = float(os.environ.get("DHT_TIMEOUT", "2.0"))
    url = os.environ.get("TELEMETRY_URL", "").strip()
    auth = os.environ.get("TELEMETRY_AUTH", "").strip()
    http_timeout = float(os.environ.get("TELEMETRY_TIMEOUT", "5.0"))
    device = os.environ.get("DEVICE_ID", "").strip() or socket.gethostname()

    if not url:
        print("TELEMETRY_URL not set — readings will only be logged",
              file=sys.stderr)

    try:
        read_loop(port, baud, serial_timeout,
                  url, auth, http_timeout, device)
    except KeyboardInterrupt:
        pass
    except serial.SerialException as exc:
        print(f"serial error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
