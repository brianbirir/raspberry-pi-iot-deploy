#!/usr/bin/env bash
#
# Deploy the Prometheus + nginx + Grafana docker-compose stack to the
# monitoring droplet.
#
# Idempotent — re-run anytime the tracked configs change.
#
# Prereqs (one-time per droplet):
#   - ~iot_bot/monitoring/{prometheus,nginx/certs}  directories exist
#   - ~iot_bot/monitoring/.env                      filled in
#   - ~iot_bot/monitoring/nginx/certs/server.{crt,key}  present
#   - docker + docker compose installed on the droplet
# See doc/monitoring-server.md for the bootstrap procedure.
#
# Overrides via env vars:
#   DROPLET_HOST  default: iot_bot@167.99.251.176
#   DROPLET_DIR   default: /home/iot_bot/monitoring
#
# Flags:
#   --no-reload   apply files + `docker compose up -d` but skip the
#                 nginx + Prometheus runtime reloads.

set -euo pipefail

DROPLET_HOST="${DROPLET_HOST:-iot_bot@167.99.251.176}"
DROPLET_DIR="${DROPLET_DIR:-/home/iot_bot/monitoring}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/configs/monitoring"

RELOAD=1
for arg in "$@"; do
  case "$arg" in
    --no-reload) RELOAD=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }

for cmd in ssh scp; do
  command -v "$cmd" >/dev/null || { echo "missing: $cmd" >&2; exit 1; }
done

log "Pre-flight: droplet has $DROPLET_DIR/.env"
if ! ssh "$DROPLET_HOST" "test -r $DROPLET_DIR/.env"; then
  cat >&2 <<EOF
ERROR: $DROPLET_DIR/.env missing or unreadable on the droplet.

For a fresh droplet:
  scp $SRC_DIR/.env.example $DROPLET_HOST:$DROPLET_DIR/.env
  ssh $DROPLET_HOST 'chmod 600 $DROPLET_DIR/.env'
  ssh $DROPLET_HOST '\$EDITOR $DROPLET_DIR/.env'   # fill in real values

See doc/monitoring-server.md "First-time bootstrap" for the full setup
(directories, cert, etc.).
EOF
  exit 1
fi

log "Pre-flight: nginx TLS cert + key present"
ssh "$DROPLET_HOST" "test -r $DROPLET_DIR/nginx/certs/server.crt && test -r $DROPLET_DIR/nginx/certs/server.key" \
  || { echo "ERROR: nginx/certs/server.{crt,key} missing on droplet"; exit 1; }

log "Staging tracked files on droplet"
scp -q "$SRC_DIR/docker-compose.yml" \
       "$DROPLET_HOST:$DROPLET_DIR/docker-compose.yml"
scp -q "$SRC_DIR/prometheus/prometheus.yml" \
       "$DROPLET_HOST:$DROPLET_DIR/prometheus/prometheus.yml"
scp -q "$SRC_DIR/nginx/nginx.conf.template" \
       "$DROPLET_HOST:$DROPLET_DIR/nginx/nginx.conf.template"

log "Rendering nginx/nginx.conf from template (token from .env)"
ssh "$DROPLET_HOST" bash -s "$DROPLET_DIR" <<'REMOTE'
set -euo pipefail
DROPLET_DIR="$1"
cd "$DROPLET_DIR"
set -a; . ./.env; set +a
[[ -n "${PROM_BEARER_TOKEN:-}" ]] || { echo "PROM_BEARER_TOKEN empty in .env" >&2; exit 1; }
docker run --rm -e PROM_BEARER_TOKEN \
  -v "$PWD/nginx/nginx.conf.template:/in:ro" \
  nginx:1.27-alpine sh -c 'envsubst "\$PROM_BEARER_TOKEN" < /in' \
  > nginx/nginx.conf
chmod 600 nginx/nginx.conf
REMOTE

log "Validating docker-compose.yml"
ssh "$DROPLET_HOST" "cd $DROPLET_DIR && docker compose config -q"

log "Applying: docker compose up -d (pull + recreate as needed)"
ssh "$DROPLET_HOST" "cd $DROPLET_DIR && docker compose up -d"

if (( RELOAD )); then
  log "Reloading nginx in-place"
  ssh "$DROPLET_HOST" "cd $DROPLET_DIR && docker compose exec -T nginx nginx -s reload || true"
  log "Reloading Prometheus"
  ssh "$DROPLET_HOST" "curl -sS -o /dev/null -w 'prometheus reload: %{http_code}\n' -X POST http://127.0.0.1:9091/-/reload"
fi

log "Verifying"
ssh "$DROPLET_HOST" "cd $DROPLET_DIR && docker compose ps"
ssh "$DROPLET_HOST" "curl -sk -o /dev/null -w 'public /healthz: %{http_code}\n' https://127.0.0.1:9090/healthz"

log "Done."
