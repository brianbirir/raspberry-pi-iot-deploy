#!/usr/bin/env bash
#
# Deploy the DHT11 reader + Prometheus agent + node_exporter to the Pi.
#
# Idempotent — re-run anytime the tracked files change.
#
# What it does:
#   0. ensure_iot_bot: checks for the iot_bot user on the Pi; if missing
#      (or sudo isn't passwordless), bootstraps it via $PI_BOOTSTRAP_USER
#      (useradd, sudo group, NOPASSWD sudoers.d, authorize local pubkey).
#   1. Installs apt packages (prometheus, prometheus-node-exporter,
#      python3-serial, python3-prometheus-client).
#   2. Adds iot_bot to the dialout group (for /dev/ttyACM0 access).
#   3. Fetches PROM_BEARER_TOKEN (env override, otherwise from the
#      droplet's ~/monitoring/.env), renders prometheus.yml locally,
#      ships it to the Pi.
#   4. Installs the dht-reader systemd unit + env file, the Prometheus
#      defaults file, and the rendered prometheus.yml.
#   5. Enables + (re)starts dht-reader, prometheus, prometheus-node-exporter.
#
# Overrides via env vars:
#   PI_HOST              default: 192.168.100.8
#   PI_BOOTSTRAP_USER    default: pi (used only if iot_bot doesn't exist
#                                     yet; needs sudo or root on the Pi)
#   DROPLET_HOST         default: iot_bot@167.99.251.176  (token source)
#   PROM_BEARER_TOKEN    if set, skips fetching from the droplet
#
# Flags:
#   --skip-bootstrap   skip the iot_bot ensure step
#   --skip-apt         skip the apt install step (packages already present)

set -euo pipefail

PI_HOST="${PI_HOST:-192.168.100.8}"
PI_BOOTSTRAP_USER="${PI_BOOTSTRAP_USER:-pi}"
DROPLET_HOST="${DROPLET_HOST:-iot_bot@167.99.251.176}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SKIP_APT=0
SKIP_BOOTSTRAP=0
for arg in "$@"; do
  case "$arg" in
    --skip-apt) SKIP_APT=1 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }

for cmd in ssh scp envsubst; do
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
  ensure_iot_bot "$PI_HOST" "sudo" "$PI_BOOTSTRAP_USER"
fi

# All remaining steps run as iot_bot, which now has passwordless sudo.
PI_HOST="iot_bot@$PI_HOST"

log "Resolving PROM_BEARER_TOKEN"
if [[ -z "${PROM_BEARER_TOKEN:-}" ]]; then
  PROM_BEARER_TOKEN="$(
    ssh "$DROPLET_HOST" 'grep ^PROM_BEARER_TOKEN= ~/monitoring/.env | cut -d= -f2-' \
      | tr -d '"' | tr -d "'" | tr -d '\r\n'
  )"
fi
[[ -n "$PROM_BEARER_TOKEN" ]] || { echo "ERROR: PROM_BEARER_TOKEN empty" >&2; exit 1; }
export PROM_BEARER_TOKEN
echo "token length: ${#PROM_BEARER_TOKEN}"

log "Rendering prometheus.yml with token"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
chmod 700 "$STAGE"
envsubst < "$REPO_ROOT/configs/prometheus/prometheus.yml" > "$STAGE/prometheus.yml"
chmod 600 "$STAGE/prometheus.yml"

log "Validating rendered prometheus.yml locally"
# Use the droplet's promtool — Pi may not have it on PATH when run via env
ssh "$DROPLET_HOST" 'docker run -i --rm prom/prometheus:v3.1.0 promtool check config /dev/stdin' \
  < "$STAGE/prometheus.yml" || {
    echo "ERROR: rendered prometheus.yml is invalid" >&2; exit 1; }

log "Staging files on Pi"
scp -q "$REPO_ROOT/src/read_dht.py" \
       "$REPO_ROOT/configs/systemd/dht-reader.service" \
       "$REPO_ROOT/configs/systemd/dht-reader.default" \
       "$REPO_ROOT/configs/prometheus/prometheus.defaults" \
       "$REPO_ROOT/configs/prometheus/prometheus-node-exporter.defaults" \
       "$STAGE/prometheus.yml" \
       "$PI_HOST:/tmp/"
unset PROM_BEARER_TOKEN

log "Installing on Pi"
ssh "$PI_HOST" "SKIP_APT=$SKIP_APT bash -s" <<'REMOTE'
set -euo pipefail

if (( SKIP_APT == 0 )); then
  echo "==> apt: prometheus, prometheus-node-exporter, python3-serial, python3-prometheus-client"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    prometheus prometheus-node-exporter \
    python3-serial python3-prometheus-client
fi

echo "==> usermod -aG dialout iot_bot"
sudo usermod -aG dialout iot_bot

echo "==> Installing DHT reader (script + unit + env-file)"
install -m 0755 /tmp/read_dht.py /home/iot_bot/read_dht.py
sudo install -m 0644 -o root -g root /tmp/dht-reader.service /etc/systemd/system/dht-reader.service
sudo install -m 0644 -o root -g root /tmp/dht-reader.default /etc/default/dht-reader

echo "==> Installing Prometheus agent (prometheus.yml + defaults + WAL dir)"
sudo install -d -o prometheus -g prometheus /var/lib/prometheus/agent
sudo install -m 0640 -o root -g prometheus /tmp/prometheus.yml /etc/prometheus/prometheus.yml
sudo install -m 0644 -o root -g root /tmp/prometheus.defaults /etc/default/prometheus
sudo install -m 0644 -o root -g root /tmp/prometheus-node-exporter.defaults /etc/default/prometheus-node-exporter

echo "==> Validating installed config"
sudo promtool check config /etc/prometheus/prometheus.yml

echo "==> daemon-reload + enable + restart services"
sudo systemctl daemon-reload
sudo systemctl enable --now dht-reader prometheus prometheus-node-exporter
sudo systemctl restart dht-reader prometheus prometheus-node-exporter

echo "==> Cleaning up staging files"
rm -f /tmp/read_dht.py /tmp/dht-reader.service /tmp/dht-reader.default \
      /tmp/prometheus.yml /tmp/prometheus.defaults /tmp/prometheus-node-exporter.defaults

echo "==> Service status"
systemctl is-active dht-reader prometheus prometheus-node-exporter
REMOTE

log "Smoke-test from local"
sleep 5
ssh "$PI_HOST" '
  echo "--- DHT exporter ---"
  curl -s http://127.0.0.1:9101/metrics | grep ^dht_ | head -5
  echo "--- Prom targets ---"
  curl -s http://127.0.0.1:9090/api/v1/targets \
    | python3 -c "import sys,json; [print(t[\"labels\"], t[\"health\"]) for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"]]"
'

log "Done. Plug in the Arduino and confirm samples appear on the droplet Prom:"
echo "  ssh $DROPLET_HOST 'curl -s \"http://127.0.0.1:9091/api/v1/query?query=dht_temperature_celsius%7Binstance%3D%22raspberrypi%22%7D\" | python3 -m json.tool'"
