#!/usr/bin/env bash
# setup-rustdesk.sh <RUSTDESK_PASSWORD>
#
# Installs RustDesk, pre-approves the permissions it needs and starts it in the
# console GUI session. Prints the connection ID.
#
# Optional environment:
#   RUSTDESK_HOST  self-hosted rendezvous/relay server
#   RUSTDESK_KEY   public key for the self-hosted server

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=scripts/common.sh
source ./common.sh

RUSTDESK_PASSWORD=${1:?RUSTDESK_PASSWORD is required}
RUSTDESK_HOST=${RUSTDESK_HOST:-}
RUSTDESK_KEY=${RUSTDESK_KEY:-}

APP=/Applications/RustDesk.app
BIN="$APP/Contents/MacOS/rustdesk"
BUNDLE_ID=com.carriez.RustDesk
CONSOLE_USER=$(console_user)

log "installing RustDesk"
if [ ! -d "$APP" ]; then
  brew install --cask rustdesk || die "brew could not install RustDesk"
fi
[ -x "$BIN" ] || die "RustDesk installed but $BIN is missing"

# Gatekeeper will refuse to launch a downloaded bundle unattended.
sudo xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
# This is the whole black-screen story for RustDesk: without Screen Recording
# it connects, authenticates and streams an empty frame. Nothing prompts on a
# headless runner, so the consent has to be written ahead of time.
TCC_USERS=("$CONSOLE_USER" "${VNC_USER:-vncuser}")

log "pre-approving Screen Recording, Accessibility and input monitoring"
for service in kTCCServiceScreenCapture kTCCServiceAccessibility \
               kTCCServicePostEvent kTCCServiceListenEvent; do
  tcc_grant_all "$service" "$BUNDLE_ID" 0
  tcc_grant_all "$service" "$BIN" 1
done
restart_tccd

keep_display_awake "$CONSOLE_USER"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONFIG_DIR="/Users/$CONSOLE_USER/Library/Preferences/$BUNDLE_ID"
sudo -u "$CONSOLE_USER" mkdir -p "$CONFIG_DIR"

if [ -n "$RUSTDESK_HOST" ]; then
  log "pointing RustDesk at the self-hosted server $RUSTDESK_HOST"
  sudo -u "$CONSOLE_USER" tee "$CONFIG_DIR/RustDesk2.toml" >/dev/null <<EOF
[options]
custom-rendezvous-server = '$RUSTDESK_HOST'
relay-server = '$RUSTDESK_HOST'
key = '$RUSTDESK_KEY'
EOF
fi

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
log "starting RustDesk in ${CONSOLE_USER}'s GUI session"
as_user "$CONSOLE_USER" open -a "$APP" || warn "open -a returned non-zero"

log "waiting for RustDesk to register an ID"
for _ in $(seq 1 30); do
  RUSTDESK_ID=$(as_user "$CONSOLE_USER" "$BIN" --get-id 2>/dev/null | tr -d '[:space:]')
  [ -n "${RUSTDESK_ID:-}" ] && break
  sleep 5
done

[ -n "${RUSTDESK_ID:-}" ] || die "RustDesk never produced an ID -- check that the app launched"

log "setting the unattended access password"
for _ in $(seq 1 5); do
  if as_user "$CONSOLE_USER" "$BIN" --password "$RUSTDESK_PASSWORD" >/dev/null 2>&1; then
    password_set=yes
    break
  fi
  sleep 3
done
[ "${password_set:-no}" = yes ] || warn "could not set the permanent password -- connect with the one-time code shown in the app"

probe_screen /tmp/rustdesk-probe.png || \
  warn "the screen probe did not look healthy -- see the troubleshooting notes in the README"

log "RustDesk ID: $RUSTDESK_ID"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "rustdesk_id=$RUSTDESK_ID" >> "$GITHUB_OUTPUT"
fi
summary "### RustDesk"
summary ""
summary "| | |"
summary "|---|---|"
summary "| ID | \`$RUSTDESK_ID\` |"
summary "| Password | the \`RUSTDESK_PASSWORD\` secret |"
summary ""
