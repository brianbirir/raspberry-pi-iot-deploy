# Pi system metrics → self-hosted Prometheus (remote_write)

Ships Raspberry Pi host metrics (CPU, memory, disk, network, etc.) to a
remote, self-hosted Prometheus + Grafana stack. The Pi pushes; the remote
server does not need to reach the Pi's LAN.

This is independent of the DHT11 telemetry pipeline (see
[`dht-reader.md`](./dht-reader.md)). They share the same Pi but otherwise
don't interact.

## Architecture

```
                      Pi (192.168.100.8)
   ┌──────────────────────────────────────────┐
   │  node_exporter ──► Prometheus (agent)    │
   │  :9100 (LAN)       :9090 (127.0.0.1)     │
   │                          │               │
   └──────────────────────────┼───────────────┘
                              │ remote_write
                              ▼
                  ┌───────────────────────────┐
                  │ remote Prometheus server  │
                  │   (with Grafana on top)   │
                  └───────────────────────────┘
```

- **node_exporter** exposes host metrics on `:9100`.
- **Prometheus in agent mode** scrapes the local node_exporter every 30 s,
  buffers samples in a write-ahead log, and `remote_write`s them out. No
  local TSDB, no query API, no UI usefully exposed.
- Prom is bound to `127.0.0.1:9090` because nothing remote should query it.

## Why this design

- **Push, not pull.** The remote Prometheus is off-LAN and can't reach the
  Pi at `192.168.100.8:9100` (NAT). `remote_write` inverts the direction so
  the Pi initiates the connection.
- **Prometheus in agent mode, not a third-party shipper.** Agent mode (Prom
  flag `--enable-feature=agent`, added in 2.32) turns Prometheus itself into
  a minimal remote_write agent — same binary we'd install anyway, no extra
  packages or config languages (vs. Grafana Alloy / vmagent).
- **node_exporter handles host metrics.** Same Debian package previously
  used; battle-tested.

## Remote server requirements

The remote Prometheus must accept `remote_write`. Either:

- Vanilla Prometheus started with `--web.enable-remote-write-receiver`
  (available since 2.33), or
- A `remote_write`-compatible receiver in front of it (Mimir, Thanos
  Receive, Cortex, VictoriaMetrics, etc.).

If using Grafana for visualization, it queries the **remote** Prometheus —
nothing Grafana-specific runs on the Pi.

## Current state on the Pi

| Component                         | State                                         |
| --------------------------------- | --------------------------------------------- |
| `prometheus-node-exporter` 1.5.0  | Installed, active, listening on `*:9100`      |
| `prometheus` 2.42.0               | Installed, active, **default config** (TSDB mode on `*:9090`) |
| `/etc/default/prometheus`         | `ARGS=""` (agent-mode flags not yet applied)  |
| `/etc/prometheus/prometheus.yml`  | Debian default (scrapes self + node_exporter) |
| `remote_write` configured         | **No — pending endpoint URL and auth**        |

Until the agent-mode flags and remote_write block are written, Prometheus
on the Pi is just running its default local-TSDB config. It is *not*
shipping anywhere yet.

## Finalization (after URL + auth are provided)

### 1. Configure agent mode (Pi-side)

`/etc/default/prometheus`:

```
ARGS="--enable-feature=agent --storage.agent.path=/var/lib/prometheus/agent --web.listen-address=127.0.0.1:9090"
```

### 2. Replace `/etc/prometheus/prometheus.yml`

Template (root-owned, mode `0640` since it'll hold the remote_write token):

```yaml
global:
  scrape_interval: 30s
  external_labels:
    instance: raspberrypi   # override per device fleet
    job: pi-metrics

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']

remote_write:
  - url: https://<remote>/api/v1/write
    # Pick ONE auth block (or omit both for unauthenticated):
    basic_auth:
      username: <user>
      password: <pass>
    # authorization:
    #   type: Bearer
    #   credentials: <token>
```

### 3. Apply

```bash
sudo systemctl daemon-reload  # not strictly needed; ARGS is via EnvironmentFile
sudo systemctl restart prometheus
systemctl status prometheus --no-pager
journalctl -u prometheus -n 30 --no-pager
```

### 4. Verify samples are flowing

- On the Pi: `ls /var/lib/prometheus/agent/wal/` should show segment files
  appearing and rotating.
- On the remote Prom: query `up{instance="raspberrypi", job="node"}` —
  expect `1`. Then `node_cpu_seconds_total` etc. should appear.

## Operations

| Task                  | Command                                              |
| --------------------- | ---------------------------------------------------- |
| Prom service status   | `systemctl status prometheus`                        |
| node_exporter status  | `systemctl status prometheus-node-exporter`          |
| Prom logs (live)      | `journalctl -u prometheus -f`                        |
| Inspect local metrics | `curl -s http://127.0.0.1:9100/metrics \| head`      |
| Restart Prom (config) | `sudo systemctl restart prometheus`                  |

## Reverting

To stop shipping metrics:

```bash
sudo systemctl disable --now prometheus
sudo systemctl disable --now prometheus-node-exporter
```

To fully remove, see the purge pattern in shell history — same as the
earlier local Prom+Grafana decommission (`apt purge prometheus
prometheus-node-exporter`).

## Notes

- node_exporter binds `*:9100` by default, so anything on the LAN can read
  it. That's fine for a home network but worth tightening (bind
  `127.0.0.1:9100` and only let local Prom scrape it) if the LAN isn't
  trusted.
- `/etc/prometheus/prometheus.yml` will hold the remote_write credentials.
  Keep it `root:root` mode `0640` — Prom runs as `prometheus` which
  belongs to the `prometheus` group with read access.
- If Prom's WAL ever balloons (e.g. remote endpoint down for hours), it
  lives at `/var/lib/prometheus/agent/`. Disk usage there is bounded by
  retention but grows during outages.
