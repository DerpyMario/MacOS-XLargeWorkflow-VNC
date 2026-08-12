#!/usr/bin/env bash
# Shared helpers for the remote desktop workflow.
# Sourced by setup-vnc.sh, setup-rustdesk.sh and ngrok.sh -- not meant to be run directly.

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

SYSTEM_TCC="/Library/Application Support/com.apple.TCC/TCC.db"

# Users whose per-user consent database should be seeded alongside the system
# one. Callers overwrite this before calling tcc_grant_all.
TCC_USERS=()

# The user that owns the physical console (the GUI session the runner boots into).
console_user() { stat -f%Su /dev/console 2>/dev/null || echo root; }

# Run a command inside a user's GUI (Aqua) session rather than in the CI shell.
# Anything that has to touch the window server -- launching an app, taking a
# screenshot -- has to go through this or it silently does nothing.
as_user() {
  local user=$1; shift
  local uid
  uid=$(id -u "$user" 2>/dev/null) || return 1
  sudo launchctl asuser "$uid" sudo -u "$user" "$@"
}

sip_disabled() { csrutil status 2>/dev/null | grep -qi disabled; }

# tcc_grant <db-path> <service> <client> <client-type>
#
# Pre-approves a TCC permission by writing straight into the consent database.
# macOS never shows a permission prompt on a headless CI box, and an unanswered
# Screen Recording prompt is exactly what a black remote screen looks like, so
# the grant has to be there before the capturing process starts.
#
# The `access` table has gained and lost columns across macOS releases, so the
# INSERT is built from whatever columns this machine actually has.
tcc_grant() {
  local db=$1 service=$2 client=$3 client_type=${4:-0}
  local now cols=() vals=() name
  now=$(date +%s)

  sudo test -f "$db" || return 0

  while IFS='|' read -r _ name _; do
    case $name in
      service)                         cols+=(service);                         vals+=("'$service'") ;;
      client)                          cols+=(client);                          vals+=("'$client'") ;;
      client_type)                     cols+=(client_type);                     vals+=("$client_type") ;;
      auth_value)                      cols+=(auth_value);                      vals+=(2) ;;   # 2 = allowed
      auth_reason)                     cols+=(auth_reason);                     vals+=(2) ;;   # 2 = set by user
      auth_version)                    cols+=(auth_version);                    vals+=(1) ;;
      allowed)                         cols+=(allowed);                         vals+=(1) ;;   # pre-Big Sur schema
      prompt_count)                    cols+=(prompt_count);                    vals+=(1) ;;
      indirect_object_identifier_type) cols+=(indirect_object_identifier_type); vals+=(0) ;;
      indirect_object_identifier)      cols+=(indirect_object_identifier);      vals+=("'UNUSED'") ;;
      flags)                           cols+=(flags);                           vals+=(0) ;;
      last_modified)                   cols+=(last_modified);                   vals+=("$now") ;;
      boot_uuid)                       cols+=(boot_uuid);                       vals+=("'UNUSED'") ;;
      last_reminded)                   cols+=(last_reminded);                   vals+=("$now") ;;
    esac
  done < <(sudo sqlite3 "$db" "PRAGMA table_info(access);" 2>/dev/null)

  [ ${#cols[@]} -gt 0 ] || { warn "could not read TCC schema from $db"; return 0; }

  local col_list val_list
  col_list=$(IFS=,; echo "${cols[*]}")
  val_list=$(IFS=,; echo "${vals[*]}")

  if sudo sqlite3 "$db" \
      "INSERT OR REPLACE INTO access ($col_list) VALUES ($val_list);" 2>/dev/null; then
    log "granted $service to $client"
  else
    warn "could not grant $service to $client in $db"
    sip_disabled || warn "System Integrity Protection is enabled -- TCC writes are blocked"
  fi
}

# Grant a service to a client in the system database and in every user database
# we care about. Screen Recording and Accessibility are system-scoped, but
# seeding the per-user databases too costs nothing and covers older layouts.
tcc_grant_all() {
  local service=$1 client=$2 client_type=${3:-0} user
  tcc_grant "$SYSTEM_TCC" "$service" "$client" "$client_type"
  for user in "${TCC_USERS[@]:-}"; do
    [ -n "$user" ] || continue
    local home
    home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [ -n "$home" ] || continue
    tcc_grant "$home/Library/Application Support/com.apple.TCC/TCC.db" \
      "$service" "$client" "$client_type"
  done
}

# tccd caches its decisions in memory, so a database written behind its back is
# only picked up after the daemon restarts.
restart_tccd() {
  log "restarting tccd so the new grants are picked up"
  sudo launchctl kickstart -k system/com.apple.tccd >/dev/null 2>&1 || true
  local uid
  uid=$(id -u "$(console_user)" 2>/dev/null) || return 0
  sudo launchctl kickstart -k "gui/$uid/com.apple.tccd" >/dev/null 2>&1 || true
}

# Everything that makes a Mac blank its own display, turned off.
# A sleeping display or an engaged screen saver is served to the remote client
# as a black rectangle, which is indistinguishable from a broken capture.
keep_display_awake() {
  local user=${1:-$(console_user)}

  log "disabling sleep, display sleep and the screen saver"
  sudo pmset -a displaysleep 0 sleep 0 disksleep 0 >/dev/null 2>&1 || true
  sudo pmset -a disablesleep 1 >/dev/null 2>&1 || true

  sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime -int 0 2>/dev/null || true
  if id "$user" >/dev/null 2>&1; then
    sudo -u "$user" defaults -currentHost write com.apple.screensaver idleTime -int 0 2>/dev/null || true
    sudo -u "$user" defaults write com.apple.screensaver askForPassword -int 0 2>/dev/null || true
  fi

  # If the saver is already up, nothing above dismisses it.
  sudo killall ScreenSaverEngine >/dev/null 2>&1 || true

  # Belt and braces: hold a power assertion for the life of the job.
  if ! pgrep -qx caffeinate; then
    sudo nohup caffeinate -dimsu >/dev/null 2>&1 &
    log "caffeinate is holding the machine awake"
  fi
}

# A brand new account lands in Setup Assistant on first login: a near-empty
# screen that reads as "black screen" over VNC. Pre-answering it drops the
# session straight onto a desktop.
skip_setup_assistant() {
  local user=$1 home version
  home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [ -n "$home" ] || return 0
  version=$(sw_vers -productVersion)

  log "pre-answering Setup Assistant for $user"
  local key
  for key in DidSeeCloudSetup DidSeeSiriSetup DidSeePrivacy DidSeeAppearanceSetup \
             DidSeeTrueTonePrivacy DidSeeAccessibility DidSeeApplePaySetup \
             DidSeeAppStore DidSeeTouchIDSetup DidSeeScreenTime DidSeeSyncSetup2; do
    sudo -u "$user" defaults write com.apple.SetupAssistant "$key" -bool true 2>/dev/null || true
  done
  sudo -u "$user" defaults write com.apple.SetupAssistant LastSeenCloudProductVersion -string "$version" 2>/dev/null || true
  sudo -u "$user" defaults write com.apple.SetupAssistant LastSeenBuddyBuildVersion -string "$(sw_vers -buildVersion)" 2>/dev/null || true

  # Skip the "your computer restarted" / first-run dialogs too.
  sudo -u "$user" defaults write com.apple.loginwindow TALLogoutSavesState -bool false 2>/dev/null || true
  sudo touch /var/db/.AppleSetupDone 2>/dev/null || true
}

# Prove the window server is actually producing pixels. An all-black frame
# compresses to almost nothing, so the file size is a usable smoke test even
# without an image library on the box.
probe_screen() {
  local out=${1:-/tmp/screen-probe.png}
  local user
  user=$(console_user)

  log "capturing a screenshot as $user to verify the framebuffer"
  if ! as_user "$user" /usr/sbin/screencapture -x -t png "$out" 2>/dev/null; then
    warn "screencapture failed -- the capturing process has no Screen Recording permission"
    return 1
  fi
  [ -f "$out" ] || { warn "screencapture produced no file"; return 1; }

  sudo chmod 644 "$out" 2>/dev/null || true
  local bytes dims
  bytes=$(stat -f%z "$out")
  dims=$(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')
  log "screenshot: ${dims:-unknown }px, ${bytes} bytes"

  if [ "$bytes" -lt 30000 ]; then
    warn "screenshot is suspiciously small -- the display is probably blank"
    return 1
  fi
  log "framebuffer is producing a real image"
}

# True when RustDesk has stored a non-empty permanent password in <dir>.
# The value is obfuscated on disk, so all we can check is that one is present:
# an empty or absent field means RustDesk is still handing out one-time codes.
rustdesk_password_stored() {
  local config="$1/RustDesk.toml"
  sudo test -f "$config" || return 1
  sudo grep -Eq "^password[[:space:]]*=[[:space:]]*'.+'" "$config"
}

# Append a line to the run summary when we are inside GitHub Actions.
summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
}
