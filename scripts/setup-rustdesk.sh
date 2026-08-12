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
TCC_USERS=("$CONSOLE_USER" "${VNC_USER:-vncuser}" root)

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
# Two defaults make an unattended host unusable, and together they produce
# exactly the "Connected, waiting for image" hang followed by a rotating
# one-time password:
#
#   approve-mode        defaults to asking someone at the host to click Accept.
#                       Nobody is sitting at a CI runner, so the viewer waits
#                       for an image that is never authorised.
#   verification-method defaults to a temporary password that RustDesk
#                       regenerates whenever the app restarts, invalidating
#                       whatever was printed in the log.
#
# The GUI app answers connections here and reads the console user's config, but
# some builds ship a root service that would read /var/root instead, so both are
# written to keep the two in agreement.
write_rustdesk_config() {
  local dir=$1 owner=$2
  sudo mkdir -p "$dir"

  sudo tee "$dir/RustDesk2.toml" >/dev/null <<EOF
[options]
verification-method = 'use-permanent-password'
approve-mode = 'password'
$( [ -n "$RUSTDESK_HOST" ] && printf "custom-rendezvous-server = '%s'\nrelay-server = '%s'\nkey = '%s'\n" \
     "$RUSTDESK_HOST" "$RUSTDESK_HOST" "$RUSTDESK_KEY" )
EOF
  sudo chown -R "$owner" "$dir" 2>/dev/null || true
  log "wrote unattended-access config to $dir"
}

USER_CONFIG="/Users/$CONSOLE_USER/Library/Preferences/$BUNDLE_ID"
ROOT_CONFIG="/var/root/Library/Preferences/$BUNDLE_ID"
write_rustdesk_config "$USER_CONFIG" "$CONSOLE_USER"
write_rustdesk_config "$ROOT_CONFIG" root

[ -n "$RUSTDESK_HOST" ] && log "pointing RustDesk at the self-hosted server $RUSTDESK_HOST"

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
log "starting RustDesk in ${CONSOLE_USER}'s GUI session"
as_user "$CONSOLE_USER" open -a "$APP" || warn "open -a returned non-zero"

# The background service is deliberately not started. It keeps its own config
# under /var/root with its own ID, so running it alongside the GUI app gives the
# machine two identities and the ID printed below might not be the one that
# answers. The GUI app accepts connections on its own for as long as the job
# holds the session open, which is all this needs.

log "waiting for RustDesk to register an ID"
for _ in $(seq 1 30); do
  RUSTDESK_ID=$(as_user "$CONSOLE_USER" "$BIN" --get-id 2>/dev/null | tr -d '[:space:]')
  [ -n "${RUSTDESK_ID:-}" ] && break
  sleep 5
done

[ -n "${RUSTDESK_ID:-}" ] || die "RustDesk never produced an ID -- check that the app launched"

# Set the permanent password on both instances, for the same reason the config
# is written twice. Success is judged on the console user's config, since that
# is the one the answering GUI app reads -- a password that only landed in
# root's config would still leave the app handing out one-time codes.
log "setting the unattended access password"
for _ in $(seq 1 5); do
  as_user "$CONSOLE_USER" "$BIN" --password "$RUSTDESK_PASSWORD" >/dev/null 2>&1
  sudo "$BIN" --password "$RUSTDESK_PASSWORD" >/dev/null 2>&1
  if rustdesk_password_stored "$USER_CONFIG"; then
    password_set=yes
    break
  fi
  sleep 3
done

if [ "${password_set:-no}" = yes ]; then
  log "permanent password is stored -- the rotating one-time code is not needed"
else
  warn "the permanent password does not appear in the config"
  warn "RustDesk will fall back to a one-time code that changes on restart"
  echo "::warning::RustDesk permanent password was not stored; unattended access may fail"
fi

# RustDesk rewrites its own config on startup, so confirm the unattended
# settings survived rather than assuming the file we wrote is still there.
rustdesk_options_ok() {
  sudo grep -q "approve-mode = 'password'" "$1/RustDesk2.toml" 2>/dev/null &&
  sudo grep -q "verification-method = 'use-permanent-password'" "$1/RustDesk2.toml" 2>/dev/null
}

if rustdesk_options_ok "$USER_CONFIG"; then
  log "unattended access is configured: password auth, no click-to-accept"
else
  warn "RustDesk overwrote the unattended settings on startup -- rewriting and restarting"
  write_rustdesk_config "$USER_CONFIG" "$CONSOLE_USER"
  as_user "$CONSOLE_USER" killall RustDesk >/dev/null 2>&1 || true
  sleep 3
  as_user "$CONSOLE_USER" open -a "$APP" >/dev/null 2>&1 || true
  sleep 8
  if rustdesk_options_ok "$USER_CONFIG"; then
    log "unattended access is configured after the restart"
  else
    warn "could not make the unattended settings stick"
    warn "the host will wait for a click on Accept, which nobody can give it"
    echo "::warning::RustDesk unattended access is not configured; connections will hang on 'waiting for image'"
  fi
fi

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
