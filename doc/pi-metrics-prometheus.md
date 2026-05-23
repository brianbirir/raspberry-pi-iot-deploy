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

| Component                         | State                                                       |
| --------------------------------- | ----------------------------------------------------------- |
| `prometheus-node-exporter` 1.5.0  | Installed, active, listening on `*:9100`                    |
| `prometheus` 2.42.0 (agent mode)  | Installed, active, bound to `127.0.0.1:9090`                |
| `/etc/default/prometheus`         | Agent-mode flags via `ARGS=…`                               |
| `/etc/prometheus/prometheus.yml`  | Scrapes local node_exporter, `remote_write`s to the droplet |
| Shipping target                   | `https://167.99.251.176:9090/api/v1/write` (nginx-fronted, bearer auth, self-signed TLS) |

Confirmed flowing — `up{instance="raspberrypi", job="pi-metrics"} = 1`
on the remote Prom.

## Installed config

The authoritative source lives in this repo under
[`prometheus/`](../prometheus/):

| Repo file                                      | Deploys to                                  |
| ---------------------------------------------- | ------------------------------------------- |
| `prometheus/prometheus.yml`                    | `/etc/prometheus/prometheus.yml` (mode `0640`, `root:prometheus`) |
| `prometheus/prometheus.defaults`               | `/etc/default/prometheus`                   |
| `prometheus/prometheus-node-exporter.defaults` | `/etc/default/prometheus-node-exporter`     |

`prometheus/prometheus.yml` contains a `${PROM_BEARER_TOKEN}` placeholder
that must be substituted before installing. The token itself lives only
in `~iot_bot/monitoring/.env` on the droplet (the source of truth) and
in `/etc/prometheus/prometheus.yml` on the Pi (rendered from the
template) — never in this repo.

### Deploy / re-deploy

```bash
# 1. Fetch the token from the source of truth on the droplet.
export PROM_BEARER_TOKEN=$(ssh iot_bot@167.99.251.176 \
  'grep ^PROM_BEARER_TOKEN= ~/monitoring/.env | cut -d= -f2-' \
  | tr -d '"'"'"' ')

# 2. Render the templated yml and stage the three files on the Pi.
envsubst < prometheus/prometheus.yml > /tmp/prometheus.yml.rendered
chmod 600 /tmp/prometheus.yml.rendered
scp -q /tmp/prometheus.yml.rendered \
       prometheus/prometheus.defaults \
       prometheus/prometheus-node-exporter.defaults \
       iot_bot@192.168.100.8:/tmp/
rm /tmp/prometheus.yml.rendered
unset PROM_BEARER_TOKEN

# 3. Install with sudo on the Pi (will prompt for password).
ssh -t iot_bot@192.168.100.8 'sudo sh -c "
  install -m 0640 -o root -g prometheus /tmp/prometheus.yml.rendered /etc/prometheus/prometheus.yml &&
  install -m 0644 -o root -g root /tmp/prometheus.defaults /etc/default/prometheus &&
  install -m 0644 -o root -g root /tmp/prometheus-node-exporter.defaults /etc/default/prometheus-node-exporter &&
  rm /tmp/prometheus.yml.rendered /tmp/prometheus.defaults /tmp/prometheus-node-exporter.defaults &&
  promtool check config /etc/prometheus/prometheus.yml &&
  systemctl restart prometheus prometheus-node-exporter
"'
```

The `--config.file` flag in `prometheus.defaults` is needed because the
Debian unit runs `/usr/bin/prometheus $ARGS` with no working-directory
trick, so the binary won't find `prometheus.yml` unless told.

The bearer token in `prometheus.yml` is checked on the droplet by an
nginx `map $http_authorization` block before requests are proxied to
Prom.

### Why `relabel_configs` instead of `external_labels`

The natural-looking first attempt was:

```yaml
global:
  external_labels:
    instance: raspberrypi
    job: pi-metrics
```

This **does not work**. `external_labels` only fills labels that are
*missing* on a sample. After scraping, every sample already has
`job="<job_name>"` (e.g. `node`) and `instance="<__address__>"`
(`127.0.0.1:9100`) — both come from the scrape_config and target — so
`external_labels` becomes a no-op. Samples land on the remote Prom under
`job="node", instance="127.0.0.1:9100"`, colliding with what a locally
scraped node_exporter on the remote host would look like. Symptom: Prom
returns 204 to every write, the TSDB head_samples counter grows, but
`up{instance="raspberrypi"}` is empty.

The fix is to set the desired identity *at scrape time*: name the scrape
job `pi-metrics` so `job` is correct, and use `relabel_configs` to
overwrite `instance`. Those labels are baked into the samples before
remote_write sees them.

### Label scheme & Grafana compatibility

Samples land on the remote Prom with:

- `job="pi-metrics"`
- `instance="raspberrypi"`

**The `job` value is intentionally non-standard.** The node_exporter
community convention is `job="node"`, which most public Grafana
dashboards (e.g. dashboard 1860 "Node Exporter Full") hardcode in their
queries. Symptom of the mismatch: a freshly-imported dashboard shows
"No data" on every panel even though `up{instance="raspberrypi"}` is 1
on the Prom server.

Fix on the dashboard side (preferred — keeps this repo unchanged):

1. Open the dashboard → Settings (gear) → **Variables** → find the
   `job` variable. If it's defined as
   `label_values(node_cpu_seconds_total, job)`, the `pi-metrics` value
   will appear in the dropdown at the top of the dashboard; just select
   it and save.
2. For panels that still show "No data," edit them and change any
   hardcoded `{job="node"}` to `{job="pi-metrics"}`, or drop the
   `job=` matcher entirely since `instance="raspberrypi"` is unique.

Alternative (single-edit, breaks any "pi-metrics" series we've already
sent — they'd age out): rename `job_name: pi-metrics` back to `node` in
`prometheus/prometheus.yml` and redeploy.

## Verifying samples are flowing

- **On the Pi**:
  - `sudo ls /var/lib/prometheus/agent/wal/` — WAL segments rotating.
  - `curl -s http://127.0.0.1:9090/api/v1/targets` — `health=up` for
    `{instance: raspberrypi, job: pi-metrics}`.
  - `curl -s http://127.0.0.1:9090/metrics | grep prometheus_remote_storage_samples_total`
    grows; `samples_failed_total` stays at 0.
- **On the remote Prom** (Prom listens on `127.0.0.1:9091` of the
  droplet; the public nginx on `:9090` only proxies `/api/v1/write`, not
  `/api/v1/query`, so query via SSH):
  ```bash
  ssh iot_bot@167.99.251.176 \
    'curl -s "http://127.0.0.1:9091/api/v1/query?query=up%7Binstance%3D%22raspberrypi%22%7D"'
  ```
  Expect a vector result with value `1`.

## Pending follow-ups

1. **Rotate the bearer token.** During the initial setup the token was
   briefly visible in a `curl -v` output captured in chat. To rotate:
   1. Generate a new value on the droplet and write it to
      `~iot_bot/monitoring/.env` (`PROM_BEARER_TOKEN=<new>`).
   2. Update the `map $http_authorization` block in the
      `prometheus-nginx` container's `nginx.conf` to match the new
      `Bearer <new>` value, then reload nginx
      (`docker exec prometheus-nginx nginx -s reload`).
   3. Re-render `/etc/prometheus/prometheus.yml` on the Pi with the new
      token (same `scp` + `sudo install -m 0640 -o root -g prometheus`
      pattern) and `sudo systemctl restart prometheus`.
   4. Verify the Pi's `prometheus_remote_storage_samples_failed_total`
      stays at 0 — a non-zero counter means nginx is rejecting with 401.
2. **Replace the self-signed cert with a real one** (optional). Point a
   domain at `167.99.251.176` and run certbot (or similar) to issue a
   trusted cert for the nginx container, then drop
   `tls_config.insecure_skip_verify` from the Pi's `prometheus.yml`. The
   pipeline already runs over TLS today; this just gets us actual cert
   validation.

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
- `/etc/prometheus/prometheus.yml` holds the remote_write bearer token.
  Install it `root:prometheus` mode `0640` so Prom (running as
  `prometheus`, via group membership) can read it but other users can't.
  If the token leaks, rotate it on the droplet (`~iot_bot/monitoring/.env`),
  update the nginx `map $http_authorization` block on the droplet, and
  re-render this file with the new value.
- If Prom's WAL ever balloons (e.g. remote endpoint down for hours), it
  lives at `/var/lib/prometheus/agent/`. Disk usage there is bounded by
  retention but grows during outages.
