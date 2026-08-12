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

# The code requirement blob tccd matches a client against. Entries carrying a
# NULL csreq are the first thing tccd distrusts, so compute the real one.
csreq_hex() {
  local target=$1 requirement tmp hex
  requirement=$(codesign -d -r- "$target" 2>&1 | sed -n 's/^designated => //p')
  [ -n "$requirement" ] || return 1
  tmp=$(mktemp)
  printf '%s' "$requirement" | csreq -r- -b "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  hex=$(xxd -p "$tmp" | tr -d '\n')
  rm -f "$tmp"
  [ -n "$hex" ] || return 1
  printf '%s' "$hex"
}

# tcc_verify <db-path> <service> <client>
#
# Reads the grant back. A write that reports success can still leave nothing
# behind, so this is what decides whether a permission is really in place.
tcc_verify() {
  local db=$1 service=$2 client=$3 value
  sudo test -f "$db" || return 1
  value=$(sudo sqlite3 "$db" \
    "SELECT auth_value FROM access WHERE service='$service' AND client='$client' LIMIT 1;" 2>/dev/null)
  [ "$value" = 2 ] && return 0
  # Pre-Big Sur schema stores the same thing in `allowed`.
  value=$(sudo sqlite3 "$db" \
    "SELECT allowed FROM access WHERE service='$service' AND client='$client' LIMIT 1;" 2>/dev/null)
  [ "$value" = 1 ]
}

# tcc_grant <db-path> <service> <client> <client-type> [csreq-hex]
#
# Pre-approves a TCC permission by writing straight into the consent database.
# macOS never shows a permission prompt on a headless CI box, and an unanswered
# Screen Recording prompt is exactly what a black remote screen looks like, so
# the grant has to be there before the capturing process starts.
#
# The `access` table has gained and lost columns across macOS releases, so the
# INSERT is built from whatever columns this machine actually has.
#
# Returns non-zero when the grant is not readable afterwards, which is the
# normal outcome while SIP is enabled: the database is protected from root, so
# no amount of privilege makes the write stick.
tcc_grant() {
  local db=$1 service=$2 client=$3 client_type=${4:-0} csreq=${5:-}
  local now cols=() vals=() name
  now=$(date +%s)

  sudo test -f "$db" || return 1

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
      csreq)   [ -n "$csreq" ] && { cols+=(csreq); vals+=("X'$csreq'"); } ;;
    esac
  done < <(sudo sqlite3 "$db" "PRAGMA table_info(access);" 2>/dev/null)

  [ ${#cols[@]} -gt 0 ] || { warn "could not read TCC schema from $db"; return 1; }

  local col_list val_list
  col_list=$(IFS=,; echo "${cols[*]}")
  val_list=$(IFS=,; echo "${vals[*]}")

  sudo sqlite3 "$db" \
    "INSERT OR REPLACE INTO access ($col_list) VALUES ($val_list);" 2>/dev/null

  if tcc_verify "$db" "$service" "$client"; then
    log "granted $service to $client"
    return 0
  fi
  return 1
}

# Grant a service to a client in the system database and in every user database
# we care about. Screen Recording and Accessibility are system-scoped, but
# seeding the per-user databases too costs nothing and covers older layouts.
# Returns zero when at least one database ended up holding the grant.
tcc_grant_all() {
  local service=$1 client=$2 client_type=${3:-0} csreq=${4:-} user granted=1
  tcc_grant "$SYSTEM_TCC" "$service" "$client" "$client_type" "$csreq" && granted=0
  for user in "${TCC_USERS[@]:-}"; do
    [ -n "$user" ] || continue
    local home
    home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [ -n "$home" ] || continue
    tcc_grant "$home/Library/Application Support/com.apple.TCC/TCC.db" \
      "$service" "$client" "$client_type" "$csreq" && granted=0
  done
  return $granted
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
  local user=${2:-}
  [ -n "$user" ] || user=$(console_user)

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

# ensure_desktop_user <user> <password> [full name]
#
# Creates the admin account the remote desktop runs as. The runner account
# cannot be reused: it holds a SecureToken, so macOS refuses to reset its
# password without the old one and there is no credential to hand to a client.
ensure_desktop_user() {
  local user=$1 password=$2 fullname=${3:-VNC User}

  if id "$user" >/dev/null 2>&1; then
    log "user $user already exists"
  else
    log "creating admin account $user"
    # Output is captured rather than piped so the password can be scrubbed
    # without building a regex out of it.
    local out
    if out=$(sudo sysadminctl -addUser "$user" \
          -fullName "$fullname" \
          -password "$password" \
          -home "/Users/$user" \
          -shell /bin/zsh \
          -admin 2>&1); then
      echo "${out//"$password"/***}"
    else
      echo "${out//"$password"/***}"
      warn "sysadminctl failed, falling back to dscl"
    fi

    if ! id "$user" >/dev/null 2>&1; then
      sudo dscl . -create "/Users/$user"
      sudo dscl . -create "/Users/$user" UserShell /bin/zsh
      sudo dscl . -create "/Users/$user" RealName "$fullname"
      sudo dscl . -create "/Users/$user" UniqueID 1001
      sudo dscl . -create "/Users/$user" PrimaryGroupID 20
      sudo dscl . -create "/Users/$user" NFSHomeDirectory "/Users/$user"
      sudo dscl . -passwd "/Users/$user" "$password"
    fi
  fi

  # Admin rights are what let the account approve system prompts and control
  # the screen once connected.
  sudo dseditgroup -o edit -a "$user" -t user admin >/dev/null 2>&1 || true
  sudo createhomedir -c -u "$user" >/dev/null 2>&1 || true

  # A password that does not authenticate is another way to get a "black"
  # screen: the server accepts the connection then sits on a login window.
  if sudo dscl . -authonly "$user" "$password" >/dev/null 2>&1; then
    log "verified $user can authenticate and is an admin"
  else
    die "$user cannot authenticate with the supplied password -- check the VNC_USER_PASSWORD secret"
  fi

  skip_setup_assistant "$user"
}

# True when the user owns a GUI (Aqua) session. Without one there is no window
# server to capture, so a screen sharing tool started as that user has nothing
# to send.
user_has_gui_session() {
  local uid
  uid=$(id -u "$1" 2>/dev/null) || return 1
  sudo launchctl print "gui/$uid" >/dev/null 2>&1
}

# Configure automatic login for a user. macOS obfuscates /etc/kcpassword with a
# fixed XOR key rather than encrypting it.
enable_autologin() {
  local user=$1 password=$2
  log "configuring automatic login for $user"
  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$user"
  sudo defaults delete /Library/Preferences/com.apple.loginwindow DisableFDEAutoLogin >/dev/null 2>&1 || true

  # Password arrives on stdin so it never appears in the process list.
  printf '%s' "$password" | perl -we '
    my @k = (0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F);
    local $/;
    my $p = <STDIN>;
    $p =~ s/\n\z//;
    $p .= "\0" x (12 - (length($p) % 12));
    binmode STDOUT;
    for my $i (0 .. length($p) - 1) {
      print chr(ord(substr($p, $i, 1)) ^ $k[$i % 11]);
    }' | sudo tee /etc/kcpassword >/dev/null
  sudo chown root:wheel /etc/kcpassword 2>/dev/null || true
  sudo chmod 600 /etc/kcpassword
}

CGSESSION=${CGSESSION:-"/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"}

disable_autologin() {
  sudo defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser >/dev/null 2>&1 || true
  sudo rm -f /etc/kcpassword
}

# Park the console at the macOS login window so a viewer can log in by hand.
#
# This is fast user switching's "Login Window..." action, not a logout: the
# current session is suspended and keeps running in the background, so the
# Actions agent living in it survives. The login window is a real GUI session
# with a window server behind it, so it screen-shares like any desktop.
show_login_window() {
  local current
  current=$(console_user)

  # Automatic login would immediately log someone back in and skip the very
  # screen we are trying to reach.
  log "disabling automatic login so the machine stops at the login window"
  disable_autologin

  # Show the user list rather than a blank name field, so the account is
  # visible and one click away.
  sudo defaults write /Library/Preferences/com.apple.loginwindow SHOWFULLNAME -bool false >/dev/null 2>&1 || true

  if [ "$current" = root ]; then
    log "console is already at the login window"
    return 0
  fi

  if sudo test ! -x "$CGSESSION"; then
    warn "CGSession is missing, cannot reach the login window without a logout"
    return 1
  fi

  log "suspending ${current}'s session to reveal the login window"
  as_user "$current" "$CGSESSION" -suspend || warn "CGSession -suspend returned non-zero"

  local waited=0 owner
  while [ "$waited" -lt 60 ]; do
    sleep 3
    waited=$((waited + 3))
    owner=$(console_user)
    if [ "$owner" = root ]; then
      log "login window is on the console after ${waited}s"
      return 0
    fi
  done

  warn "console is still owned by $(console_user) -- the login window did not appear"
  return 1
}

# Hand the console session to <user> by restarting loginwindow, which re-reads
# the autologin settings when it comes back up.
#
# This logs out whoever currently holds the console. On a hosted runner that is
# the account the job itself runs under, so if the Actions agent lives in that
# GUI session the job dies with it -- which is why this is opt-in.
switch_console_to() {
  local user=$1 password=$2
  local before
  before=$(console_user)

  if [ "$before" = "$user" ]; then
    log "$user already owns the console session"
    return 0
  fi

  enable_autologin "$user" "$password"

  log "restarting loginwindow to hand the console from $before to $user"
  sudo killall loginwindow >/dev/null 2>&1 || true

  local waited=0
  while [ "$waited" -lt 90 ]; do
    sleep 5
    waited=$((waited + 5))
    if [ "$(console_user)" = "$user" ]; then
      log "$user now owns the console session after ${waited}s"
      # The desktop needs a moment to finish drawing before anything captures it.
      sleep 10
      return 0
    fi
  done

  warn "console session is still owned by $(console_user) after ${waited}s"
  return 1
}

# Append a line to the run summary when we are inside GitHub Actions.
summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
}
