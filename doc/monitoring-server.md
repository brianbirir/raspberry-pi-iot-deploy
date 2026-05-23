# Remote monitoring server (Prometheus + Grafana on a DigitalOcean droplet)

A self-hosted Prometheus + Grafana stack on a public Rocky Linux droplet at
`167.99.251.176`. Prometheus accepts `remote_write` from the Pi (and any
other device) over HTTPS, authenticated by a bearer token. Grafana queries
Prometheus over the internal Docker network.

This is the receiving end of the pipeline described in
[`pi-metrics-prometheus.md`](./pi-metrics-prometheus.md).

## Architecture

```
                   public internet
                          │
                          │ HTTPS :9090  (self-signed)
                          ▼
        ┌─────────────────────────────────────────┐
        │ nginx (TLS + bearer auth)               │
        │  - /api/v1/write → requires Bearer token │
        │  - /healthz      → 200 (no auth)        │
        │  - everything else → 404                │
        └────────────────┬────────────────────────┘
                         │ http (docker network)
                         ▼
              ┌──────────────────────┐    ┌────────────────────┐
              │ Prometheus            │◄──┤ Grafana            │
              │  --web.enable-remote- │   │ :3000 (public)     │
              │    write-receiver     │   │ admin/<password>   │
              │ 127.0.0.1:9091 (host) │   │                    │
              └──────────────────────┘    └────────────────────┘
                  ↑ admin UI only via SSH tunnel
```

- **nginx** terminates TLS and is the only thing on the public `:9090`
  surface. It validates `Authorization: Bearer <token>` for write requests
  and proxies them to Prometheus on the internal Docker network.
- **Prometheus** is not directly published to the public internet. It's
  bound to `127.0.0.1:9091` on the host so the admin UI can be reached via
  an SSH tunnel, and it's reachable on the internal Docker network as
  `prometheus:9090`. It runs with `--web.enable-remote-write-receiver` so
  the Pi can push samples to `/api/v1/write`.
- **Grafana** is public on `:3000` with an admin password set from `.env`.
  It uses `http://prometheus:9090` as its data source URL.

## Why this design

- **Pi can't be scraped (pull) over NAT.** The droplet is on the public
  internet; the Pi is on a home LAN. Prometheus's `remote_write` inverts
  the usual flow — the Pi pushes. See `pi-metrics-prometheus.md` for the
  Pi-side rationale.
- **Bearer token in front of remote_write.** Prometheus's HTTP server
  doesn't natively gate `/api/v1/write` with bearer tokens, so nginx sits
  in front as the auth boundary. This also lets us terminate TLS in one
  place and restrict the public surface to exactly two endpoints
  (`/api/v1/write` + `/healthz`).
- **Self-signed cert, not Let's Encrypt.** The droplet is addressed by IP,
  not a domain — Let's Encrypt requires a DNS name. The Pi's Prometheus
  config sets `tls_config: insecure_skip_verify: true`. If a domain gets
  pointed at this droplet later, swap nginx for Caddy (auto Let's Encrypt)
  and drop the `insecure_skip_verify`.
- **Docker Compose, not native packages.** One file describes the whole
  stack; upgrades are `docker compose pull && docker compose up -d`.
  Prometheus and Grafana don't share host packages with anything else on
  this droplet.
- **Prometheus admin UI is not public.** It's bound to `127.0.0.1:9091` on
  the host. There's no auth on the Prometheus UI itself, so it would leak
  every metric to anyone who found the port. SSH tunnel keeps it behind
  the existing key-based SSH auth.

## Host

| Field      | Value                       |
| ---------- | --------------------------- |
| Provider   | DigitalOcean                |
| Hostname   | `rocky-linux-s-1vcpu-2gb-fra1` |
| OS         | Rocky Linux 9.2 (Blue Onyx) |
| Public IP  | `167.99.251.176`            |
| Admin user | `iot_bot` (SSH key, wheel + NOPASSWD sudo, password locked) |

`root` SSH login still works via key. `iot_bot` is the day-to-day user.

## Endpoints

| Endpoint                                          | Auth                | Purpose                       |
| ------------------------------------------------- | ------------------- | ----------------------------- |
| `https://167.99.251.176:9090/api/v1/write`        | `Bearer <token>`    | Pi pushes samples here        |
| `https://167.99.251.176:9090/healthz`             | none                | nginx liveness check          |
| `http://167.99.251.176:3000`                      | Grafana admin login | Dashboards / data source      |
| `http://127.0.0.1:9091` (via SSH tunnel)          | none                | Prometheus admin UI           |

SSH tunnel for the Prometheus UI:

```
ssh -L 9091:127.0.0.1:9091 iot_bot@167.99.251.176
# then open http://localhost:9091 in a browser
```

## Accessing Grafana

1. Open `http://167.99.251.176:3000`.
2. Log in as `admin` with the password from
   `~iot_bot/monitoring/.env` (`GRAFANA_ADMIN_PASSWORD`).
3. On first login Grafana prompts for a new admin password. After
   changing it, update `GRAFANA_ADMIN_PASSWORD` in `.env` to match so the
   password survives a `docker compose down && up -d` (the env var is
   only applied if Grafana's database doesn't already have a configured
   admin, but keeping `.env` accurate avoids future drift).

### Adding Prometheus as a data source

The first time the Grafana UI is opened, the Prometheus data source has
to be wired up manually:

1. **Connections → Data sources → Add data source → Prometheus**.
2. **Prometheus server URL:** `http://prometheus:9090`
   — the container name on the internal Docker network. Not `localhost`,
   not the public IP, not `:9091`. Grafana and Prometheus share the
   `monnet` bridge network; DNS resolves `prometheus` to the container.
3. Leave auth empty. Prometheus has no auth on the internal network,
   and the public bearer-token check lives in nginx, which Grafana doesn't
   go through.
4. **Save & test** → expect "Successfully queried the Prometheus API".

### Importing a starter dashboard

Once the Pi is shipping `node_exporter` metrics via `remote_write` (see
[`pi-metrics-prometheus.md`](./pi-metrics-prometheus.md)), import the
community **Node Exporter Full** dashboard to get CPU / memory / disk /
network panels with no further config:

- **Dashboards → New → Import → 1860 → Load**, then select the Prometheus
  data source on the next screen.

## Layout on the droplet

Everything lives under `~iot_bot/monitoring/`:

```
monitoring/
├── docker-compose.yml          # the three services + bridge network
├── .env                        # secrets, mode 600
│                               #   GRAFANA_ADMIN_PASSWORD=...
│                               #   PROM_BEARER_TOKEN=...
├── prometheus/
│   └── prometheus.yml          # self-scrape only (remote_write is inbound)
└── nginx/
    ├── nginx.conf              # rendered (token embedded), mode 600
    ├── nginx.conf.template     # template with ${PROM_BEARER_TOKEN} placeholder
    └── certs/
        ├── server.crt          # self-signed, CN=167.99.251.176, 10-yr
        └── server.key          # mode 600
```

**Secrets never leave the droplet.** `.env`, `nginx/nginx.conf`, and the
TLS cert/key are the only places that hold the bearer token, Grafana
password, and private key. None of those are in this repo. To retrieve
the env: `ssh iot_bot@167.99.251.176 'cat ~/monitoring/.env'`.

### Tracked in this repo

| Droplet path                            | Repo path                                          |
| --------------------------------------- | -------------------------------------------------- |
| `~/monitoring/docker-compose.yml`       | `configs/monitoring/docker-compose.yml`            |
| `~/monitoring/prometheus/prometheus.yml`| `configs/monitoring/prometheus/prometheus.yml`     |
| `~/monitoring/nginx/nginx.conf.template`| `configs/monitoring/nginx/nginx.conf.template`     |
| `~/monitoring/.env` (structure only)    | `configs/monitoring/.env.example`                  |

Not tracked: `.env` (real values), rendered `nginx/nginx.conf` (embeds
token), TLS cert/key. Regenerate the cert with `openssl` against CN
`167.99.251.176`; regenerate the token with `openssl rand -hex 32`.

### Deploy / re-deploy

**Recommended:** from the project root run

```bash
./scripts/deploy-monitoring.sh
```

It checks the droplet for `.env` + TLS cert, scp's the tracked files,
re-renders `nginx/nginx.conf` via `envsubst` in a throwaway nginx
container, runs `docker compose config -q` + `docker compose up -d`,
and reloads nginx + Prom in place. Pass `--no-reload` to skip the
runtime reloads (useful when only the compose file changed and you want
the new container to take over instead).

The script is idempotent. The equivalent manual steps:

```bash
# Stage the tracked files on the droplet.
scp configs/monitoring/docker-compose.yml \
    iot_bot@167.99.251.176:~/monitoring/docker-compose.yml
scp configs/monitoring/prometheus/prometheus.yml \
    iot_bot@167.99.251.176:~/monitoring/prometheus/prometheus.yml
scp configs/monitoring/nginx/nginx.conf.template \
    iot_bot@167.99.251.176:~/monitoring/nginx/nginx.conf.template

# Re-render nginx.conf from the template (token comes from .env).
ssh iot_bot@167.99.251.176 'cd ~/monitoring && set -a && . ./.env && set +a &&
  docker run --rm -e PROM_BEARER_TOKEN \
    -v "$PWD/nginx/nginx.conf.template:/in:ro" \
    nginx:1.27-alpine sh -c "envsubst \"\\\$PROM_BEARER_TOKEN\" < /in" \
  > nginx/nginx.conf && chmod 600 nginx/nginx.conf'

# Apply.
ssh iot_bot@167.99.251.176 'cd ~/monitoring &&
  docker compose up -d &&
  docker compose exec nginx nginx -s reload &&
  curl -sS -o /dev/null -w "prom reload: %{http_code}\n" \
    -X POST http://127.0.0.1:9091/-/reload'
```

First-time bootstrap on a fresh droplet:

1. `mkdir -p ~/monitoring/{prometheus,nginx/certs}` on the droplet.
2. `cp configs/monitoring/.env.example` to the droplet as `.env`, fill
   in real values (`chmod 600`).
3. Generate the self-signed cert into `~/monitoring/nginx/certs/`
   (CN=`167.99.251.176`, 10-yr).
4. Run the deploy block above.

## Pi-side configuration

Drop this into `/etc/prometheus/prometheus.yml` on the Pi alongside the
agent-mode flags described in [`pi-metrics-prometheus.md`](./pi-metrics-prometheus.md):

```yaml
remote_write:
  - url: https://167.99.251.176:9090/api/v1/write
    authorization:
      type: Bearer
      credentials: <PROM_BEARER_TOKEN from .env>
    tls_config:
      insecure_skip_verify: true   # self-signed cert
```

Then `sudo systemctl restart prometheus` on the Pi and verify on the
droplet's Prometheus UI (via the SSH tunnel to `localhost:9091`):
`up{job="node", instance="raspberrypi"}` should report `1`. The `job`
label comes from the Pi-side scrape config; `instance` is set via
`external_labels` in the same file (see `pi-metrics-prometheus.md`).

## Operations

| Task                          | Command (run as `iot_bot` on the droplet, from `~/monitoring`) |
| ----------------------------- | -------------------------------------------------------------- |
| Stack status                  | `docker compose ps`                                            |
| Tail logs (all services)      | `docker compose logs -f --tail=50`                             |
| Tail logs (one service)       | `docker compose logs -f --tail=50 prometheus`                  |
| Restart one service           | `docker compose restart nginx`                                 |
| Reload Prometheus config      | `curl -X POST http://127.0.0.1:9091/-/reload`                  |
| Reload nginx config           | `docker compose exec nginx nginx -s reload`                    |
| Pull updated images           | `docker compose pull && docker compose up -d`                  |
| Stop everything               | `docker compose down`                                          |
| Stop + wipe TSDB / Grafana DB | `docker compose down -v`  (⚠ deletes volumes)                  |

## Rotating the bearer token

1. Generate a new token on the droplet:
   `NEW=$(openssl rand -hex 32)`
2. Update `.env`: replace `PROM_BEARER_TOKEN=<old>` with the new value.
3. Re-render `nginx/nginx.conf` from the template:
   ```
   docker run --rm -e PROM_BEARER_TOKEN="$NEW" \
     -v "$PWD/nginx/nginx.conf.template:/in:ro" \
     nginx:1.27-alpine sh -c 'envsubst "\$PROM_BEARER_TOKEN" < /in' \
     > nginx/nginx.conf
   ```
4. `docker compose restart nginx`
5. Update the Pi's `/etc/prometheus/prometheus.yml` with the new token and
   `sudo systemctl restart prometheus`.

There's a brief window where one side has the new token and the other
doesn't — samples will get 401s and be retried from the WAL once both
sides match.

## Notes

- **Grafana on plain HTTP.** Port 3000 has no TLS. Anyone on the network
  path can sniff the admin login. Acceptable for now because the same
  domain-less limitation that drove the self-signed cert applies here. Fix
  by putting Grafana behind nginx too once a domain is in place.
- **Prometheus has no remote_write rate-limiting.** A misconfigured (or
  hostile) sender with the token can fill the TSDB. The 48 GB free disk is
  plenty for one Pi but worth tracking with a Grafana alert if more
  devices are added.
- **The token is in plaintext in `nginx.conf`.** That's by design — nginx
  needs to compare against it on every request. The file is mode 600 and
  the host is single-tenant.
- **SELinux is enforcing** but Docker manages its own labelling on bind
  mounts, so no extra `:z`/`:Z` flags were needed. If a future bind mount
  gets refused, that's the first thing to check.
- **No `firewalld`/`iptables`** on this droplet — the only thing
  restricting inbound is the listening ports themselves. Port `9090` is
  bearer-token-gated by nginx; `3000` is gated by the Grafana login;
  `9091` is bound to localhost so it's not on the public surface; `22` is
  SSH (key-only).
