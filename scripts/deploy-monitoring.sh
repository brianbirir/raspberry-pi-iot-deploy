#!/usr/bin/env bash
#
# Deploy the Prometheus + nginx + Grafana docker-compose stack to the
# monitoring droplet.
#
# Idempotent — re-run anytime the tracked configs change.
#
# What it does:
#   0. ensure_iot_bot: checks for the iot_bot user on the droplet; if
#      missing (or sudo isn't passwordless), bootstraps it via
#      $DROPLET_BOOTSTRAP_USER (useradd, wheel group, NOPASSWD
#      sudoers.d, authorize local pubkey).
#   1. Pre-flight: ~/monitoring/.env + TLS cert exist.
#   2. scp tracked configs.
#   3. Re-render nginx/nginx.conf from template via envsubst in a
#      throwaway nginx container.
#   4. docker compose config -q && docker compose up -d.
#   5. Reload nginx + Prometheus in place (unless --no-reload).
#
# Prereqs (one-time per droplet — see doc/monitoring-server.md):
#   - ~iot_bot/monitoring/{prometheus,nginx/certs}  directories exist
#   - ~iot_bot/monitoring/.env                      filled in
#   - ~iot_bot/monitoring/nginx/certs/server.{crt,key}  present
#   - docker + docker compose installed on the droplet
#
# Overrides via env vars:
#   DROPLET_HOST             default: 167.99.251.176
#   DROPLET_BOOTSTRAP_USER   default: root (used only if iot_bot doesn't
#                                       exist yet)
#   DROPLET_DIR              default: /home/iot_bot/monitoring
#
# Flags:
#   --skip-bootstrap   skip the iot_bot ensure step
#   --no-reload        apply files + `docker compose up -d` but skip the
#                      nginx + Prometheus runtime reloads.

set -euo pipefail

DROPLET_HOST="${DROPLET_HOST:-167.99.251.176}"
DROPLET_BOOTSTRAP_USER="${DROPLET_BOOTSTRAP_USER:-root}"
DROPLET_DIR="${DROPLET_DIR:-/home/iot_bot/monitoring}"
# Strip a user@ prefix if someone overrode DROPLET_HOST with one.
DROPLET_HOST="${DROPLET_HOST#*@}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/configs/monitoring"

RELOAD=1
SKIP_BOOTSTRAP=0
for arg in "$@"; do
  case "$arg" in
    --no-reload) RELOAD=0 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }

for cmd in ssh scp; do
  command -v "$cmd" >/dev/null || { echo "missing: $cmd" >&2; exit 1; }
done

# Ensure iot_bot exists on $1 with passwordless sudo and our pubkey.
# Idempotent. Args: host, sudo_group (sudo|wheel), bootstrap_user.
ensure_iot_bot() {
  local host="$1" sudo_group="$2" bootstrap_user="$3"

  if ssh -o BatchMode=yes -o ConnectTimeout=5 \
         -o StrictHostKeyChecking=accept-new \
         "iot_bot@$host" 'sudo -n true' >/dev/null 2>&1; then
    log "iot_bot on $host: present with passwordless sudo, skipping bootstrap"
    return 0
  fi

  log "iot_bot on $host: bootstrapping via $bootstrap_user@$host"
  local pubkey=""
  if command -v ssh-add >/dev/null; then
    pubkey=$(ssh-add -L 2>/dev/null | head -1 || true)
  fi
  if [[ -z "$pubkey" ]]; then
    for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
      [[ -r "$k" ]] && { pubkey=$(cat "$k"); break; }
    done
  fi
  [[ -n "$pubkey" ]] || {
    echo "ERROR: no local SSH pubkey found (tried ssh-agent and ~/.ssh/*.pub)" >&2
    exit 1
  }

  ssh -t -o StrictHostKeyChecking=accept-new "$bootstrap_user@$host" \
    "SUDO_GROUP=$sudo_group PUBKEY='$pubkey' bash -s" <<'REMOTE'
set -euo pipefail
[[ $(id -u) == 0 ]] && SUDO="" || SUDO="sudo"

if id -u iot_bot >/dev/null 2>&1; then
  echo "iot_bot exists; ensuring sudo group + NOPASSWD + key are configured"
else
  echo "creating iot_bot"
  $SUDO useradd -m -s /bin/bash iot_bot
fi

$SUDO usermod -aG "$SUDO_GROUP" iot_bot

echo "iot_bot ALL=(ALL) NOPASSWD:ALL" \
  | $SUDO tee /etc/sudoers.d/90-iot_bot-nopasswd >/dev/null
$SUDO chmod 0440 /etc/sudoers.d/90-iot_bot-nopasswd
$SUDO visudo -cf /etc/sudoers.d/90-iot_bot-nopasswd

$SUDO install -d -o iot_bot -g iot_bot -m 0700 /home/iot_bot/.ssh
$SUDO touch /home/iot_bot/.ssh/authorized_keys
$SUDO chown iot_bot:iot_bot /home/iot_bot/.ssh/authorized_keys
$SUDO chmod 0600 /home/iot_bot/.ssh/authorized_keys
if ! $SUDO grep -qxF "$PUBKEY" /home/iot_bot/.ssh/authorized_keys 2>/dev/null; then
  echo "$PUBKEY" | $SUDO tee -a /home/iot_bot/.ssh/authorized_keys >/dev/null
fi
REMOTE

  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 \
           "iot_bot@$host" 'sudo -n true' >/dev/null 2>&1; then
    echo "ERROR: post-bootstrap SSH/sudo check failed for iot_bot@$host" >&2
    exit 1
  fi
  log "iot_bot on $host: bootstrap complete"
}

if (( SKIP_BOOTSTRAP == 0 )); then
  ensure_iot_bot "$DROPLET_HOST" "wheel" "$DROPLET_BOOTSTRAP_USER"
fi

# All remaining steps run as iot_bot, which now has passwordless sudo.
DROPLET_HOST="iot_bot@$DROPLET_HOST"

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
