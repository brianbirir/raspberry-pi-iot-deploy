# Deployment

Two scripts cover the full provision-and-deploy story:

- [`scripts/deploy-pi.sh`](../scripts/deploy-pi.sh) — Raspberry Pi
  (DHT11 reader + Prometheus agent + node_exporter)
- [`scripts/deploy-monitoring.sh`](../scripts/deploy-monitoring.sh) —
  Droplet (Prometheus + nginx + Grafana via docker-compose)

Both scripts are idempotent and start with an identical `ensure_iot_bot`
phase that creates and configures the `iot_bot` operator account on
their target host if it doesn't already exist.

## Flow

```txt
         ┌──────────────────────────────────────────────────────────┐
         │                Operator's machine (this repo)             │
         └─────────────────┬───────────────────────┬─────────────────┘
                           │                       │
            ./scripts/deploy-pi.sh    ./scripts/deploy-monitoring.sh
                           │                       │
                           ▼                       ▼
                ┌──────────────────┐     ┌──────────────────┐
                │  Raspberry Pi    │     │  Droplet (Rocky) │
                │  192.168.100.8   │     │  167.99.251.176  │
                └──────────────────┘     └──────────────────┘

   ── Shared phase 0: ensure_iot_bot (idempotent) ──────────────────

   a) probe: ssh iot_bot@host && sudo -n true
   b) if missing or sudo needs a password, ssh as $BOOTSTRAP_USER and:
        useradd -m iot_bot                      (skip if exists)
        usermod -aG sudo|wheel iot_bot          (sudo on Pi, wheel on droplet)
        /etc/sudoers.d/90-iot_bot-nopasswd      (NOPASSWD:ALL)
        ~iot_bot/.ssh/authorized_keys           (your local pubkey)

   ── Per-host phase ───────────────────────────────────────────────

   Pi:                                      Droplet:

   1. apt install:                          1. pre-flight:
        prometheus                                 ~/monitoring/.env
        prometheus-node-exporter                   nginx/certs/server.{crt,key}
        python3-serial
        python3-prometheus-client            2. scp tracked files:
                                                   docker-compose.yml
   2. usermod -aG dialout iot_bot                  prometheus/prometheus.yml
                                                   nginx/nginx.conf.template
   3. install configs:
        /home/iot_bot/read_dht.py            3. render nginx/nginx.conf via
        /etc/prometheus/prometheus.yml          envsubst in a throwaway
        /etc/default/prometheus                 nginx container
        /etc/default/prometheus-node-exporter
        /etc/default/dht-reader              4. docker compose config -q
        /etc/systemd/system/                    docker compose up -d
          dht-reader.service
                                             5. reload nginx + prom in place
   4. promtool check config                     (skip with --no-reload)
      systemctl daemon-reload
      systemctl restart:
        dht-reader
        prometheus            (agent mode)
        prometheus-node-exporter

   ── After both deploys ──────────────────────────────────────────

                    Pi  ──── remote_write ────►  droplet Prom
                                                       │
                                                       ▼
                                                   Grafana :3000
                                                       │
                                                       ▼
                                          DHT11 dashboard (see
                                          configs/grafana/dashboards/)
```

## ensure_iot_bot

Identical function in both scripts. It runs **before** anything else and
is safe to re-run:

1. **Probe.** Tries `ssh iot_bot@host 'sudo -n true'`. If both the user
   exists and sudo is passwordless, returns immediately — nothing to do.
2. **Pick a pubkey.** Prefers the first key in your `ssh-agent`; falls
   back to `~/.ssh/id_ed25519.pub`, `id_rsa.pub`, or `id_ecdsa.pub`.
3. **SSH as bootstrap user.** Uses `$PI_BOOTSTRAP_USER` (default `pi`)
   or `$DROPLET_BOOTSTRAP_USER` (default `root`). This is the one
   account the script needs you to have access to once, when the host
   is fresh.
4. **Create + configure iot_bot.** `useradd -m` if missing; add to
   `sudo` (Pi) or `wheel` (droplet); write a NOPASSWD sudoers fragment
   at `/etc/sudoers.d/90-iot_bot-nopasswd` and validate it with
   `visudo -cf`; append your pubkey to
   `/home/iot_bot/.ssh/authorized_keys` (dedupes — `grep -qxF` first).
5. **Re-verify.** Re-runs the probe; aborts with a helpful error if
   things still don't work.

Skip it with `--skip-bootstrap` if you've provisioned the account some
other way (e.g. cloud-init, Ansible).

## Usage

```bash
./scripts/deploy-pi.sh
./scripts/deploy-monitoring.sh
```

Useful overrides:

```bash
PI_HOST=192.168.1.50 \
PI_BOOTSTRAP_USER=ubuntu \
  ./scripts/deploy-pi.sh

DROPLET_HOST=mon.example.com \
DROPLET_BOOTSTRAP_USER=admin \
  ./scripts/deploy-monitoring.sh
```

Flags:

| Script                    | Flag                | Effect                                   |
| ------------------------- | ------------------- | ---------------------------------------- |
| both                      | `--skip-bootstrap`  | skip `ensure_iot_bot`                    |
| `deploy-pi.sh`            | `--skip-apt`        | skip the apt install (faster re-runs)    |
| `deploy-monitoring.sh`    | `--no-reload`       | apply files but don't trigger nginx/prom reloads |

## Bootstrap pre-reqs per host

| Host    | Needs (first-run only)                                                       |
| ------- | ---------------------------------------------------------------------------- |
| Pi      | SSH access as `pi` (or whatever `PI_BOOTSTRAP_USER` you set) with sudo       |
| Droplet | SSH access as `root` (or whatever `DROPLET_BOOTSTRAP_USER` you set); `~iot_bot/monitoring/` directory tree, `.env`, and TLS cert in place — see [`monitoring-server.md`](./monitoring-server.md#first-time-bootstrap) |

After the first successful run, future runs only need SSH-as-iot_bot
(key-based) — the bootstrap phase short-circuits.
