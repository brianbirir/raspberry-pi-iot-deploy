# DHT11 Reader (Arduino → Raspberry Pi → Prometheus → Grafana)

Reads temperature and humidity from a DHT11 sensor wired to an Arduino Uno,
streams readings over USB serial to the Raspberry Pi, and exposes them as
**Prometheus metrics** on a local HTTP endpoint. The same Prometheus agent
that ships host metrics (see [`pi-metrics-prometheus.md`](./pi-metrics-prometheus.md))
also scrapes this exporter and `remote_write`s the readings to the
droplet, where Grafana queries them.

Runs as a systemd service on the Pi.

## Architecture

```
DHT11 ──► Arduino Uno ──USB serial──► dht-reader (:9101/metrics)
                                              │
                                  scrape ◄────┘
                            (Pi Prom agent)
                                              │
                                  remote_write│
                                              ▼
                                  droplet Prometheus
                                              │
                                              ▼
                                          Grafana
```

- Arduino samples the DHT11 once per second and prints one CSV line per
  reading: `<temp_c>,<humidity>\n` at 9600 baud.
- The Python script opens `/dev/ttyACM0`, parses each line, and updates
  three Prometheus gauges served on `127.0.0.1:9101/metrics`.
- The local Prometheus agent (already configured for host metrics) has a
  second scrape job (`dht-sensor`) pointed at `:9101` and ships the
  samples to the droplet via `remote_write`.
- If the Arduino is unplugged the metrics endpoint stays up — the script
  retries serial open every 5 s. Staleness is visible from
  `dht_last_reading_timestamp_seconds`.

## Exposed metrics

| Metric                                | Type  | Notes                                                       |
| ------------------------------------- | ----- | ----------------------------------------------------------- |
| `dht_temperature_celsius`             | gauge | Latest reading; `NaN` before the first successful read.     |
| `dht_humidity_percent`                | gauge | Latest reading; `NaN` before the first successful read.     |
| `dht_last_reading_timestamp_seconds`  | gauge | Unix ts of the last successful read (`0` = never).          |

Labels (set by the scrape job — see `configs/prometheus/prometheus.yml`):
`{job="dht-sensor", instance="raspberrypi"}`.

## Hardware

| DHT11 pin | Uno pin |
| --------- | ------- |
| VCC       | 5V      |
| GND       | GND     |
| DATA      | D2      |

Bare 4-pin DHT11 modules need a 10 kΩ pull-up from DATA to VCC. The
common blue PCB modules already include it.

The Uno connects to the Pi over USB. Linux enumerates it as
`/dev/ttyACM0`.

## Arduino sketch

Path: `src/arduino/dht11_serial/dht11_serial.ino`

Libraries (Arduino IDE → Library Manager):

- **DHT sensor library** by Adafruit
- **Adafruit Unified Sensor** (pulled in automatically)

Upload to the Uno at 9600 baud. The sketch skips `NaN` reads so the
Python side never sees malformed data.

## Python exporter

Path: `src/read_dht.py` (deployed to `/home/iot_bot/read_dht.py` on the Pi)

Dependencies (apt): `python3-serial`, `python3-prometheus-client` (both
installed on the Pi).

All config is via environment variables — defaults work for the current
hardware:

| Variable       | Default         | Purpose                                  |
| -------------- | --------------- | ---------------------------------------- |
| `DHT_PORT`     | `/dev/ttyACM0`  | Serial device                            |
| `DHT_BAUD`     | `9600`          | Baud rate                                |
| `DHT_TIMEOUT`  | `2.0`           | Serial read timeout, seconds             |
| `METRICS_PORT` | `9101`          | Port for `/metrics`                      |
| `METRICS_ADDR` | `127.0.0.1`     | Bind address (local Prom scrapes it)     |

Run manually for debugging:

```
python3 /home/iot_bot/read_dht.py
curl -s http://127.0.0.1:9101/metrics | grep ^dht_
```

## systemd service

Unit file: `systemd/dht-reader.service` → `/etc/systemd/system/dht-reader.service`
on the Pi.

Key choices:

- `User=iot_bot` — `iot_bot` is in the `dialout` group so it can open
  `/dev/ttyACM0`.
- `EnvironmentFile=-/etc/default/dht-reader` — optional overrides; the
  template is `configs/systemd/dht-reader.default` (no secrets, just settings).
- `Restart=always`, `RestartSec=5` — safety net. The script itself
  doesn't crash on serial errors any more (it retries internally), so
  this only kicks in for unhandled failures.

## Deployment

From the project root:

```bash
scp src/read_dht.py configs/systemd/dht-reader.service configs/systemd/dht-reader.default \
    iot_bot@192.168.100.8:/home/iot_bot/
ssh iot_bot@192.168.100.8 'sudo sh -c "
  install -m 0644 ~iot_bot/dht-reader.service /etc/systemd/system/dht-reader.service &&
  install -m 0644 ~iot_bot/dht-reader.default /etc/default/dht-reader &&
  rm ~iot_bot/dht-reader.service ~iot_bot/dht-reader.default &&
  systemctl daemon-reload &&
  systemctl enable --now dht-reader.service
"'
```

After any change to `configs/prometheus/prometheus.yml`, redeploy that too — see
[`pi-metrics-prometheus.md`](./pi-metrics-prometheus.md#deploy--re-deploy).

Re-deploying just the script after edits:

```bash
scp src/read_dht.py iot_bot@192.168.100.8:/home/iot_bot/
ssh iot_bot@192.168.100.8 'sudo systemctl restart dht-reader'
```

## Grafana

### Ready-to-import dashboard

A pre-built dashboard lives at
[`configs/grafana/dashboards/dht11.json`](../configs/grafana/dashboards/dht11.json).
It has five panels:

| Panel                           | Query                                                                  |
| ------------------------------- | ---------------------------------------------------------------------- |
| Stat: Temperature               | `dht_temperature_celsius{instance="$instance"}`                        |
| Stat: Humidity                  | `dht_humidity_percent{instance="$instance"}`                           |
| Stat: Seconds since last reading | `time() - (dht_last_reading_timestamp_seconds{instance="$instance"} > 0)` |
| Time series: Temperature        | `dht_temperature_celsius{instance="$instance"}`                        |
| Time series: Humidity           | `dht_humidity_percent{instance="$instance"}`                           |

The `$instance` template variable is populated from
`label_values(dht_temperature_celsius, instance)`, so it'll show every
Pi sending DHT readings (currently just `raspberrypi`).

The freshness stat uses `... > 0` so the value is **empty (—) before
the first reading** rather than displaying "57 years ago" because the
gauge starts at 0.

#### Import

1. Open Grafana on the droplet: <http://167.99.251.176:3000>
2. Left nav → **Dashboards** → **New** (top right) → **Import**
3. **Upload JSON file** → pick `configs/grafana/dashboards/dht11.json`
   from this repo (or paste its contents into the textarea)
4. Grafana will prompt for the **Prometheus** datasource — select the
   one pointed at the droplet's local Prom (the receiver of remote_write)
5. Click **Import**

The dashboard auto-refreshes every 30 s (matching the scrape interval).
Time range defaults to *Last 1 hour*; widen it from the top-right picker
once you have history.

### PromQL cheatsheet (for ad-hoc / custom panels)

Drop the `{instance="raspberrypi"}` matcher when you only have one Pi.

| Need                       | Query                                                                                |
| -------------------------- | ------------------------------------------------------------------------------------ |
| Temperature (°C)           | `dht_temperature_celsius{instance="raspberrypi"}`                                    |
| Humidity (%)               | `dht_humidity_percent{instance="raspberrypi"}`                                       |
| Seconds since last reading | `time() - (dht_last_reading_timestamp_seconds{instance="raspberrypi"} > 0)`          |
| Alert: stale > 2 min       | `(time() - (dht_last_reading_timestamp_seconds{instance="raspberrypi"} > 0)) > 120`  |

## Operations

| Task              | Command                                                |
| ----------------- | ------------------------------------------------------ |
| Service status    | `systemctl status dht-reader`                          |
| Live log          | `journalctl -u dht-reader -f`                          |
| Local metrics     | `curl -s http://127.0.0.1:9101/metrics \| grep ^dht_`  |
| Restart           | `sudo systemctl restart dht-reader`                    |
| Stop / disable    | `sudo systemctl disable --now dht-reader`              |

## Troubleshooting

- **`/dev/ttyACM0: No such file or directory`** — Arduino isn't plugged
  in, or it enumerated differently. Check `ls /dev/ttyACM* /dev/ttyUSB*`
  and override `DHT_PORT` in `/etc/default/dht-reader`.
- **`Permission denied` on `/dev/ttyACM0`** — `iot_bot` isn't in
  `dialout` for the current systemd session. `sudo systemctl restart
  dht-reader` after the group is added.
- **`skip: '...'` in the journal** — a garbled serial line; harmless.
  The Arduino resets when the port opens, so the first 1–2 reads after
  a restart are commonly skipped.
- **`dht_*` metrics absent on the droplet Prom** — check `/api/v1/targets`
  on the Pi (`curl -s http://127.0.0.1:9090/api/v1/targets`) to confirm
  the `dht-sensor` target is `up`; then check the
  [Grafana label compatibility](./pi-metrics-prometheus.md#label-scheme--grafana-compatibility)
  note — `job="dht-sensor"` here is different from `job="pi-metrics"`.
- **Values are `NaN`** — exporter is up but hasn't seen a valid reading
  yet. Either the Arduino is unplugged (check
  `dht_last_reading_timestamp_seconds == 0`) or the sketch isn't running.
