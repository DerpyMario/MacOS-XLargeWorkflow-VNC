#!/usr/bin/env bash
# setup-vnc.sh <VNC_USER_PASSWORD> <VNC_PASSWORD>
#
# Creates the desktop account, turns on Apple Screen Sharing / Remote Management
# and applies the permission fixes that keep the remote screen from coming up black.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=scripts/common.sh
source ./common.sh

USER_PASSWORD=${1:?VNC_USER_PASSWORD is required}
VNC_PASSWORD=${2:-}
VNC_USER=${VNC_USER:-vncuser}
VNC_ALWAYS_CONSOLE=${VNC_ALWAYS_CONSOLE:-yes}
# legacy = plain Screen Sharing, security type 2, works with any viewer.
# ard    = Remote Management, Apple-only security types 30/33/35.
VNC_AUTH_MODE=${VNC_AUTH_MODE:-legacy}
# Hand the console session to $VNC_USER instead of leaving it with the runner
# account. See switch_console_to() for why this is not the default.
DESKTOP_USER_CONSOLE=${DESKTOP_USER_CONSOLE:-no}

KICKSTART=${KICKSTART:-/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart}

log "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) on $(uname -m)"
log "console session is owned by $(console_user)"
sip_disabled && log "SIP is disabled -- permission grants will stick" \
             || warn "SIP is enabled -- some permission grants may be rejected"

# Spotlight indexing eats a whole core on a machine we only want for pixels.
sudo mdutil -i off -a >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Desktop account
# ---------------------------------------------------------------------------
ensure_desktop_user "$VNC_USER" "$USER_PASSWORD"

# Optionally hand the console session to the desktop account, so the desktop
# served over VNC belongs to it rather than to the runner account.
if [ "$DESKTOP_USER_CONSOLE" = yes ]; then
  switch_console_to "$VNC_USER" "$USER_PASSWORD" || \
    warn "continuing with $(console_user) on the console"
fi

# ---------------------------------------------------------------------------
# Screen Sharing permissions
# ---------------------------------------------------------------------------
TCC_USERS=("$(console_user)" "$VNC_USER")

log "granting screen capture permission to the sharing agents"
for client in \
  /System/Library/CoreServices/RemoteManagement/ARDAgent.app \
  /usr/libexec/screensharingd \
  /System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/MacOS/AppleVNCServer
do
  tcc_grant_all kTCCServiceScreenCapture "$client" 1
done
for bundle in com.apple.RemoteDesktopAgent com.apple.screensharing.agent com.apple.screensharing; do
  tcc_grant_all kTCCServiceScreenCapture "$bundle" 0
  tcc_grant_all kTCCServiceAccessibility "$bundle" 0
  tcc_grant_all kTCCServicePostEvent "$bundle" 0
done
restart_tccd

# ---------------------------------------------------------------------------
# Choose which authentication the server offers
# ---------------------------------------------------------------------------
# Remote Management (ARD) advertises Apple's proprietary security types 30/33/35.
# Viewers that only partly implement them do not fall back -- RealVNC Viewer
# aborts the handshake with "key length too large" before it ever asks for a
# password. Plain Screen Sharing with the legacy VNC password advertises
# security type 2, which every viewer understands, so that is the default.
# Set VNC_AUTH_MODE=ard to get the full ARD feature set back.
if [ "$VNC_AUTH_MODE" = legacy ]; then
  log "using plain Screen Sharing with legacy VNC auth (cross-platform viewers)"
  sudo "$KICKSTART" -deactivate -configure -access -off >/dev/null 2>&1 || true
  sudo defaults write /Library/Preferences/com.apple.RemoteManagement \
    VNCLegacyConnectionsEnabled -bool true 2>/dev/null || true

  # The access group only exists when access is restricted; when it does, an
  # account that is not a member gets authenticated and then disconnected.
  if sudo dseditgroup -o read com.apple.access_screensharing >/dev/null 2>&1; then
    sudo dseditgroup -o edit -a "$VNC_USER" -t user com.apple.access_screensharing >/dev/null 2>&1 || true
    log "added $VNC_USER to com.apple.access_screensharing"
  fi
else
  log "enabling Remote Management for all users with full privileges"
  sudo "$KICKSTART" -configure -allowAccessFor -allUsers -privs -all
  sudo "$KICKSTART" -activate -configure -access -on

  sudo defaults write /Library/Preferences/com.apple.RemoteManagement ARD_AllLocalUsers -bool true 2>/dev/null || true
  sudo defaults write /Library/Preferences/com.apple.RemoteManagement ARD_AllLocalUsersPrivs -int -1073741569 2>/dev/null || true
fi

# Force incoming sessions onto the real console instead of a virtual display.
# The console is the one session with a framebuffer the window server is
# already drawing into; a virtual session on a headless Mac is where the
# classic black screen comes from.
if [ "$VNC_ALWAYS_CONSOLE" = yes ]; then
  log "pinning VNC sessions to the console display"
  sudo defaults write /Library/Preferences/com.apple.RemoteManagement VNCAlwaysStartOnConsole -bool true 2>/dev/null || true
else
  sudo defaults write /Library/Preferences/com.apple.RemoteManagement VNCAlwaysStartOnConsole -bool false 2>/dev/null || true
fi

if [ -n "$VNC_PASSWORD" ]; then
  log "enabling the legacy VNC password"
  if [ ${#VNC_PASSWORD} -gt 8 ]; then
    warn "the VNC protocol only carries 8 characters -- only the first 8 of VNC_PASSWORD count"
  fi
  # Supported directly on recent releases...
  if ! sudo "$KICKSTART" -configure -clientopts -setvnclegacy -vnclegacy yes \
        -setvncpw -vncpw "$VNC_PASSWORD" >/dev/null 2>&1; then
    sudo "$KICKSTART" -configure -clientopts -setvnclegacy -vnclegacy yes >/dev/null 2>&1 || true
  fi
  # ...and written by hand as a fallback, because the CLI has dropped and
  # regained -setvncpw across releases. The obfuscation is a fixed XOR key.
  # http://hints.macworld.com/article.php?story=20071103011608872
  printf '%s' "$VNC_PASSWORD" | perl -we '
    BEGIN { @k = unpack "C*", pack "H*", "1734516E8BA8C5E2FF1C39567390ADCA" }
    $_ = <>; chomp;
    s/^(.{8}).*/$1/;
    @p = unpack "C*", $_;
    foreach (@k) { printf "%02X", $_ ^ (shift @p || 0) }
    print "\n"' | sudo tee /Library/Preferences/com.apple.VNCSettings.txt >/dev/null
  sudo chmod 600 /Library/Preferences/com.apple.VNCSettings.txt
else
  warn "no VNC_PASSWORD given -- only system-account logins will work"
fi

log "starting the screen sharing daemon"
# The daemon reads VNCLegacyConnectionsEnabled and the password file at start,
# so it has to come up after both are in place.
sudo launchctl enable system/com.apple.screensharing >/dev/null 2>&1 || true
sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
if [ "$VNC_AUTH_MODE" = legacy ]; then
  sudo launchctl kickstart -k system/com.apple.screensharing >/dev/null 2>&1 || true
else
  sudo "$KICKSTART" -restart -agent -console
  sudo "$KICKSTART" -activate
fi

keep_display_awake "$(console_user)"

# ---------------------------------------------------------------------------
# Verify the listener is actually up
# ---------------------------------------------------------------------------
log "waiting for the VNC listener on port 5900"
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 5900 >/dev/null 2>&1; then
    log "port 5900 is accepting connections"
    listening=yes
    break
  fi
  sleep 2
done

if [ "${listening:-no}" != yes ]; then
  warn "nothing is listening on 5900 -- dumping state for diagnosis"
  sudo lsof -nP -iTCP:5900 2>/dev/null || true
  sudo launchctl print system/com.apple.screensharing 2>/dev/null | head -20 || true
  die "screen sharing failed to start"
fi

probe_screen /tmp/screen-probe.png || \
  warn "the screen probe did not look healthy -- see the troubleshooting notes in the README"

# ---------------------------------------------------------------------------
# Report which authentication the server ended up offering
# ---------------------------------------------------------------------------
# Whether a given viewer can connect is decided entirely by this list, so it is
# worth knowing now rather than from a client-side protocol error later.
if command -v python3 >/dev/null 2>&1; then
  log "checking which authentication types the server offers"
  python3 ./rfb-probe.py 127.0.0.1 5900
  case $? in
    0) log "cross-platform viewers (RealVNC, TigerVNC, Remmina) can authenticate" ;;
    1) warn "only Apple authentication is on offer"
       warn "viewers such as RealVNC will fail with a protocol error"
       warn "set the VNC_PASSWORD secret, or use Apple Screen Sharing as the client"
       echo "::warning::VNC server is not offering legacy auth; RealVNC-style viewers will fail" ;;
    *) warn "could not determine the offered authentication types" ;;
  esac
else
  warn "python3 not available -- skipping the authentication check"
fi

log "VNC is ready for user '$VNC_USER'"
