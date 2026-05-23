#!/usr/bin/env bash
#
# Deploy the DHT11 reader + Prometheus agent + node_exporter to the Pi.
#
# Idempotent — re-run anytime the tracked files change.
#
# What it does:
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
# sudo on the Pi requires a password. This script uses `ssh -t` so you
# can type it interactively when prompted (once, the sudo session is
# cached for the remaining commands in the same shell).
#
# Overrides via env vars:
#   PI_HOST            default: iot_bot@192.168.100.8
#   DROPLET_HOST       default: iot_bot@167.99.251.176  (token source)
#   PROM_BEARER_TOKEN  if set, skips fetching from the droplet
#
# Flags:
#   --skip-apt   skip the apt install step (packages already present)

set -euo pipefail

PI_HOST="${PI_HOST:-iot_bot@192.168.100.8}"
DROPLET_HOST="${DROPLET_HOST:-iot_bot@167.99.251.176}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SKIP_APT=0
for arg in "$@"; do
  case "$arg" in
    --skip-apt) SKIP_APT=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }

for cmd in ssh scp envsubst; do
  command -v "$cmd" >/dev/null || { echo "missing: $cmd" >&2; exit 1; }
done

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

log "Installing on Pi (sudo will prompt for password)"
ssh -t "$PI_HOST" "SKIP_APT=$SKIP_APT bash -s" <<'REMOTE'
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
