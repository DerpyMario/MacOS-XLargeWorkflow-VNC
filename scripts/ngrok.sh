#!/usr/bin/env bash
# ngrok.sh <NGROK_AUTH_TOKEN> [REGION] [PORT]
#
# Installs ngrok, opens a TCP tunnel to the local VNC port and reports the
# public address on stdout, in the job summary and as a step output.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=scripts/common.sh
source ./common.sh

NGROK_AUTH_TOKEN=${1:?NGROK_AUTH_TOKEN is required}
REGION=${2:-us}
PORT=${3:-5900}
LOG=${NGROK_LOG:-/tmp/ngrok.log}

if ! command -v ngrok >/dev/null 2>&1; then
  log "installing ngrok"
  if ! brew install --cask ngrok >/dev/null 2>&1; then
    warn "the cask failed, downloading the binary directly"
    case "$(uname -m)" in
      arm64) arch=arm64 ;;
      *)     arch=amd64 ;;
    esac
    curl -fsSL -o /tmp/ngrok.zip \
      "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-${arch}.zip" \
      || die "could not download ngrok"
    sudo unzip -o /tmp/ngrok.zip -d /usr/local/bin >/dev/null || die "could not unpack ngrok"
    sudo chmod +x /usr/local/bin/ngrok
  fi
fi
command -v jq >/dev/null 2>&1 || brew install jq >/dev/null 2>&1 || true

log "ngrok $(ngrok version 2>/dev/null | head -1)"
ngrok config add-authtoken "$NGROK_AUTH_TOKEN" >/dev/null 2>&1 \
  || ngrok authtoken "$NGROK_AUTH_TOKEN" >/dev/null 2>&1 \
  || die "ngrok rejected the auth token"

log "opening a TCP tunnel to port $PORT in region $REGION"
nohup ngrok tcp "$PORT" --region "$REGION" --log stdout --log-format logfmt \
  >"$LOG" 2>&1 &

log "waiting for the tunnel to come up"
for _ in $(seq 1 30); do
  TUNNEL=$(curl -fsS http://127.0.0.1:4040/api/tunnels 2>/dev/null \
    | jq -r '.tunnels[0].public_url // empty' 2>/dev/null)
  [ -n "${TUNNEL:-}" ] && break
  sleep 2
done

if [ -z "${TUNNEL:-}" ]; then
  warn "the ngrok API never reported a tunnel -- last 40 log lines follow"
  tail -40 "$LOG" 2>/dev/null || true
  die "ngrok failed to establish a tunnel"
fi

# tcp://6.tcp.ngrok.io:14521 -> host + port
ADDRESS=${TUNNEL#tcp://}
HOST=${ADDRESS%:*}
TUNNEL_PORT=${ADDRESS##*:}

log "tunnel is up: $ADDRESS"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "address=$ADDRESS"
    echo "host=$HOST"
    echo "port=$TUNNEL_PORT"
    echo "vnc_url=vnc://$ADDRESS"
  } >> "$GITHUB_OUTPUT"
fi

summary "### VNC over ngrok"
summary ""
summary "| | |"
summary "|---|---|"
summary "| Address | \`$ADDRESS\` |"
summary "| Screen Sharing / RealVNC | \`vnc://$ADDRESS\` |"
summary "| Username | \`${VNC_USER:-vncuser}\` (with the \`VNC_USER_PASSWORD\` secret) |"
summary "| VNC-only password | the \`VNC_PASSWORD\` secret |"
summary ""
