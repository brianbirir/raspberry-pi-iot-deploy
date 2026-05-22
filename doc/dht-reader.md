# DHT11 Reader (Arduino → Raspberry Pi → Remote HTTP)

Reads temperature and humidity from a DHT11 sensor connected to an Arduino Uno,
streams them over USB serial to the Raspberry Pi, and POSTs each reading as
JSON to a remote HTTP endpoint. Runs as a systemd service on the Pi.

## Architecture

```
DHT11 ──► Arduino Uno ──USB serial──► Raspberry Pi (systemd: dht-reader)
                                              │
                                              ├─► journalctl -u dht-reader
                                              └─► HTTPS POST → remote server
```

- Arduino samples the DHT11 once per second and prints one CSV line per reading:
  `<temp_c>,<humidity>\n` at 9600 baud.
- Python script on the Pi opens `/dev/ttyACM0`, parses each line, logs the
  reading as JSON to stdout (captured by the journal), and POSTs it to
  `TELEMETRY_URL`. Bad/partial lines and failed POSTs are dropped (the next
  reading is ~1 s away).
- systemd captures stdout into the journal and restarts the script on failure
  (e.g., Arduino unplugged).

## Telemetry payload

```json
{
  "ts": "2026-05-22T19:30:01Z",
  "device": "raspberrypi",
  "temperature_c": 24.3,
  "humidity_pct": 55.0
}
```

Sent with `Content-Type: application/json` and (if `TELEMETRY_AUTH` is set) an
`Authorization` header using the env var's value verbatim — e.g.
`TELEMETRY_AUTH="Bearer abc123"`.

## Hardware

| DHT11 pin | Uno pin       |
| --------- | ------------- |
| VCC       | 5V            |
| GND       | GND           |
| DATA      | D2            |

Bare 4-pin DHT11 modules need a 10 kΩ pull-up from DATA to VCC. The common blue
PCB modules already include it.

The Uno connects to the Pi over USB. Linux enumerates it as `/dev/ttyACM0`.

## Arduino sketch

Path: `arduino/dht11_serial/dht11_serial.ino`

Libraries (Arduino IDE → Library Manager):

- **DHT sensor library** by Adafruit
- **Adafruit Unified Sensor** (pulled in automatically)

Upload to the Uno at 9600 baud. The sketch skips `NaN` reads so the Python side
never sees malformed data.

## Python script

Path: `read_dht.py` (deployed to `/home/iot_bot/read_dht.py` on the Pi)

Dependencies: `pyserial` only (HTTP uses stdlib `urllib`). pyserial 3.5 is
already present on the Pi.

Config is via environment variables — see the header docstring of
`read_dht.py` for the full list. The two that matter most:

| Variable        | Purpose                                              |
| --------------- | ---------------------------------------------------- |
| `TELEMETRY_URL` | POST endpoint. **Required** for remote shipping; if empty, readings only land in the journal. |
| `TELEMETRY_AUTH`| Full `Authorization` header value (e.g. `Bearer …`). |

Run manually for debugging:

```
TELEMETRY_URL=https://example.com/ingest python3 /home/iot_bot/read_dht.py
```

## systemd service

Unit file: `systemd/dht-reader.service` → installed at
`/etc/systemd/system/dht-reader.service` on the Pi.

Key choices:

- `User=iot_bot` — `iot_bot` was added to the `dialout` group so it can open
  `/dev/ttyACM0`. New group membership requires a fresh session; the service
  picks it up on next start.
- `EnvironmentFile=-/etc/default/dht-reader` — telemetry URL and auth live
  here, root-owned so the token isn't world-readable. The leading `-` makes
  the file optional (service still starts if it's missing).
- `Restart=always`, `RestartSec=5` — if the Arduino is unplugged, the script
  exits and systemd restarts it every 5 s until the device returns.
- `StandardOutput=journal` — readings and errors are visible via `journalctl`.

The env file template is `systemd/dht-reader.default` in this repo. Edit it
with the real endpoint/token before installing, or edit `/etc/default/dht-reader`
on the Pi after install.

## Deployment

From the project root:

```
scp read_dht.py systemd/dht-reader.service systemd/dht-reader.default \
    iot_bot@192.168.100.8:/home/iot_bot/
ssh iot_bot@192.168.100.8
```

On the Pi (one-time setup):

```
sudo usermod -aG dialout iot_bot
sudo install -m 0644 ~/dht-reader.service /etc/systemd/system/dht-reader.service
sudo install -m 0640 -o root -g root ~/dht-reader.default /etc/default/dht-reader
sudo systemctl daemon-reload
sudo systemctl enable --now dht-reader.service
```

Then edit `/etc/default/dht-reader` to set `TELEMETRY_URL` (and
`TELEMETRY_AUTH` if needed) and `sudo systemctl restart dht-reader`.

Re-deploying the script after edits:

```
scp read_dht.py iot_bot@192.168.100.8:/home/iot_bot/
ssh iot_bot@192.168.100.8 'sudo systemctl restart dht-reader'
```

## Operations

| Task              | Command                                       |
| ----------------- | --------------------------------------------- |
| Service status    | `systemctl status dht-reader`                 |
| Live readings/log | `journalctl -u dht-reader -f`                 |
| Recent log lines  | `journalctl -u dht-reader -n 50 --no-pager`   |
| Restart           | `sudo systemctl restart dht-reader`           |
| Stop / disable    | `sudo systemctl disable --now dht-reader`     |

## Troubleshooting

- **`could not open port /dev/ttyACM0: No such file or directory`** — Arduino
  is not plugged in, or it enumerated as `ttyUSB0` / `ttyACM1`. Check
  `ls /dev/ttyACM* /dev/ttyUSB*` and pass `--port` if needed (edit the unit's
  `ExecStart`).
- **`Permission denied` on `/dev/ttyACM0`** — `iot_bot` is not yet in
  `dialout` for this session. Run `sudo systemctl restart dht-reader`, or log
  out and back in.
- **`skip: '...'` in the journal** — a single garbled line; harmless. The
  Arduino resets when the port opens, so the first 1–2 reads after a restart
  are commonly skipped.
