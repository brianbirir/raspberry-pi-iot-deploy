# Raspberry Pi Agentic Controller

A Raspberry Pi acting as the on-site controller for a small IoT setup,
managed with help from an AI agent (Claude Code). Currently it does two
things:

1. **Reads a DHT11 sensor** (temperature + humidity) connected to an
   Arduino Uno over USB serial, and exposes the readings as Prometheus
   gauges on a local HTTP endpoint.
2. **Ships its own host metrics** (CPU, memory, disk, network, …) and
   the DHT readings to a self-hosted Prometheus + Grafana stack on a
   DigitalOcean droplet, using Prometheus in agent mode + `remote_write`.

Both run as systemd services on the Pi and survive reboots; Grafana on
the droplet visualizes everything from the same Prometheus datasource.

## Hardware

- **Raspberry Pi** running Debian 12 (bookworm), on the LAN at
  `192.168.100.8`. SSH user: `iot_bot`.
- **Arduino Uno** plugged into the Pi over USB (enumerates as
  `/dev/ttyACM0`), sampling a **DHT11** sensor on digital pin 2.
- **Droplet** (`167.99.251.176`) running Prometheus + Grafana + nginx
  in Docker, accepting `remote_write` from the Pi.

## Repo layout

```
src/read_dht.py              Pi-side DHT11 Prometheus exporter
src/arduino/dht11_serial/    Arduino sketch (DHT11 → CSV over serial)
configs/systemd/             Pi: unit + env-file for the dht-reader service
configs/prometheus/          Pi: Prom agent + node_exporter configs
configs/monitoring/          Droplet: docker-compose stack (Prom + nginx + Grafana)
configs/grafana/dashboards/  Importable Grafana dashboards
scripts/                     Deploy scripts (Pi + droplet)
doc/                         Setup / operations docs
```

## Documentation

- **[doc/deployment.md](doc/deployment.md)** — end-to-end deploy flow
  (both scripts), `ensure_iot_bot` algorithm, flow diagram, overrides.
- **[doc/dht-reader.md](doc/dht-reader.md)** — DHT11 → Arduino → Pi →
  Prometheus pipeline: wiring, sketch, Python exporter, systemd service,
  Grafana queries, ops, troubleshooting.
- **[doc/pi-metrics-prometheus.md](doc/pi-metrics-prometheus.md)** —
  Pi host metrics → self-hosted Prometheus via `remote_write`: agent-mode
  config, tracked configs in `configs/prometheus/`, deploy workflow, the
  `relabel_configs` vs `external_labels` gotcha, token rotation.
- **[doc/monitoring-server.md](doc/monitoring-server.md)** — remoter server
  side: docker-compose stack, nginx auth + TLS, Grafana setup, first-time
  bootstrap.

## Deployment

```bash
./scripts/deploy-pi.sh           # Pi: DHT reader + Prom agent + node_exporter
./scripts/deploy-monitoring.sh   # Droplet: Prometheus + nginx + Grafana stack
```

Both scripts are idempotent and start with an `ensure_iot_bot` phase
that creates and configures the `iot_bot` operator account (sudo group
membership, NOPASSWD sudo, your SSH key authorized) if it doesn't
already exist. Re-run them anytime tracked files change.

See [`doc/deployment.md`](doc/deployment.md) for the full flow diagram,
the `ensure_iot_bot` algorithm, env-var overrides, and the per-host
prereqs.

## Quick ops cheatsheet

```bash
# SSH to the Pi
ssh iot_bot@192.168.100.8

# DHT11 reader
systemctl status dht-reader
journalctl -u dht-reader -f

# Prometheus agent + node_exporter
systemctl status prometheus prometheus-node-exporter
journalctl -u prometheus -f

# Check metrics on the droplet (Prom is on 127.0.0.1:9091; nginx
# exposes only /api/v1/write publicly)
ssh iot_bot@167.99.251.176 \
  'curl -s "http://127.0.0.1:9091/api/v1/query?query=up%7Binstance%3D%22raspberrypi%22%7D"'
```
