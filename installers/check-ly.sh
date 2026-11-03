#!/usr/bin/env bash
# check-ly.sh — read-only health check for the whole Ly login-screen stack.
#
# Why: when a display manager (DM, the login screen) fails, it fails at the
# worst moment. You stare at a black screen, or a login box that rejects you,
# with no terminal to look around from. Everything you would want to check is
# behind the thing that is broken. So this checks all of it now, while you
# still have a working desktop. It only reads; it never changes anything. Run
# it any time. Companion to install-ly.sh and fix-suspend-freeze.sh; same
# OK/FAIL style as check-setup.sh.
#
# How to run it:
#   bash installers/check-ly.sh
#   sudo bash installers/check-ly.sh    # also scans the system log (see the
#                                       # "Journal scan" section)
#
# Reading the output. Four kinds of line, and the difference matters:
#   [OK]    fine
#   [FAIL]  broken, and it will bite you. Only this sets the exit code.
#   [WARN]  worth knowing, not broken: old log entries, missing optional bits
#   [--]    information, not a verdict
# Warnings never fail the run, on purpose: the log scan reports the PAST, and
# seeing an old, since-fixed failure is useful, not alarming. The last line
# prints all three totals.
#
# Exit codes: 0 no [FAIL] (warnings are fine), 1 at least one [FAIL].

# Re-exec under bash if run as `sh check-ly.sh`. `sh` is dash here, and dash
# does not understand `[[`, arrays or ${var//}.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# Only -u (an unset variable is an error), not -e or pipefail. A failed check
# is the result we want to print, not a reason to stop the script.
set -u

# Counters for passed, failed and warned checks, and the printers that bump
# them. ok = green [OK], bad = red [FAIL], warn = yellow [WARN], info = blue
# [--] (counts nothing), hdr = bold section title. have CMD: is CMD on PATH?
# pkg NAME: is the Debian package NAME installed?
P=0; F=0; W=0
ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; P=$((P+1)); }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; F=$((F+1)); }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; W=$((W+1)); }
info() { printf '\033[1;34m[--]\033[0m   %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
pkg()  { dpkg -s "$1" >/dev/null 2>&1; }

# Ly's config file.
CONF=/etc/ly/config.ini
# Ly's PAM file. PAM is the part of Linux that decides if a password is
# accepted (see the "PAM stack" section).
PAM=/etc/pam.d/ly
# The version file install-ly.sh writes after a build.
STAMP=/usr/local/share/ly.version
# The four sleep services fix-suspend-freeze.sh puts a drop-in on, and the
# systemd setting that drop-in turns off.
SLEEP_SERVICES=(systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate)
FREEZE_VAR=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS

# cfg <key>: print the value of a config.ini key. Takes the first `key = ...`
# line, then strips the key, any trailing "# comment" and trailing spaces.
# Prints nothing if config.ini can't be read or has no such key.
cfg() {
  [[ -r $CONF ]] || return 0
  local v; v=$(grep -E "^\s*$1\s*=" "$CONF" 2>/dev/null | head -1 | sed -E "s/^\s*$1\s*=\s*//; s/\s*#.*$//; s/\s+$//")
  echo "$v"
}

# Find the folder that holds PAM modules (pam_*.so files) once, by looking for
# pam_unix.so under /lib and /usr/lib. Empty if not found.
PAM_SEC=$(dirname "$(find /lib /usr/lib -name pam_unix.so 2>/dev/null | head -1)" 2>/dev/null)

# ---------------------------------------------------------------------------
# Binary & version: is /usr/bin/ly there and runnable, what version does it
# report, and does that match the stamp install-ly.sh left behind? A mismatch
# means Ly was installed some other way: not fatal, just worth knowing.
hdr "Binary & version"
if [[ -x /usr/bin/ly ]]; then
  ok "bin  /usr/bin/ly (executable)"
  # Quirk: `ly --version` prints to stderr (the error channel), not stdout.
  # So 2>&1 captures both; grep keeps the first x.y.z it finds.
  ver=$(/usr/bin/ly --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)   # --version prints to stderr
  [[ -n $ver ]] && ok "ly --version → $ver" || warn "ly --version produced no version string"
  if [[ -r $STAMP ]]; then
    st=$(cat "$STAMP" 2>/dev/null)
    [[ -n $ver && $st == "$ver" ]] && ok "version stamp matches ($st)" \
      || warn "stamp $STAMP='$st' != running ly '$ver'"
  else
    warn "no version stamp $STAMP (installed outside install-ly.sh?)"
  fi
else
  bad "bin  /usr/bin/ly missing or not executable — Ly not installed"
fi

# ---------------------------------------------------------------------------
# Config & setup scripts: config.ini must be readable. The two scripts Ly uses
# to really launch a session must be executable: xsetup.sh for X11, wsetup.sh
# for Wayland. If one is not, the login succeeds and then nothing starts.
hdr "Config & setup scripts"
if [[ -r $CONF ]]; then
  ok "file $CONF"
  for s in /etc/ly/xsetup.sh /etc/ly/wsetup.sh; do
    [[ -x $s ]] && ok "exec $s" || bad "$s missing/not-executable (X/Wayland session launch relies on it)"
  done
  # The "save file" is how Ly remembers which user and session you picked
  # last (default /etc/ly/save). Ly runs as root and writes it as root, so
  # only the folder's existence matters, not whether you can write to it.
  save=$(cfg save_file); save=${save:-/etc/ly/save}
  savedir=$(dirname "$save")
  [[ -d $savedir ]] && ok "save dir present ($savedir)" \
    || warn "save dir $savedir missing — last-user/session won't persist"
else
  bad "file $CONF missing — Ly falls back to compiled defaults"
fi

# ---------------------------------------------------------------------------
hdr "Config-referenced commands"
# Config-referenced commands: config.ini names other programs, like the X
# server, xauth, mcookie, the terminal reset commands, and shutdown/restart.
# If one of those is not installed, Ly fails at login with no useful message.
# So read each setting and check the program is really there.
#
# ckcmd <config-key> [--optional]: unset or "null" -> [--]. Otherwise take the
# first word (the program; drop args like "-a now"). A full path (/...) must
# be executable; a bare name must be on PATH. Missing -> [FAIL]. --optional
# turns a missing full path into [WARN]; a bare name not on PATH is still a
# [FAIL] even with --optional.
ckcmd() {  # ckcmd <config-key> [--optional]
  local key=$1 opt=${2:-} val bin; val=$(cfg "$key")
  [[ -z $val || $val == null ]] && { info "$key = (unset)"; return; }
  bin=${val%% *}   # first token; strip args like "-a now"
  if [[ $bin == /* ]]; then
    [[ -x $bin ]] && ok "$key → $bin" || { [[ $opt == --optional ]] && warn "$key → $bin missing" || bad "$key → $bin missing/not-executable"; }
  else
    have "$bin" && ok "$key → $bin (PATH)" || bad "$key → $bin not on PATH"
  fi
}
ckcmd x_cmd
ckcmd xauth_cmd
ckcmd mcookie_cmd
ckcmd term_reset_cmd
ckcmd term_restore_cursor_cmd
ckcmd shutdown_cmd
ckcmd restart_cmd
ckcmd sleep_cmd --optional

# ---------------------------------------------------------------------------
# Login sessions available: a DM with nothing to launch is a dead end. Count
# the .desktop files in the X11 and Wayland session folders (from config.ini's
# xsessions / waylandsessions, else /usr/share/xsessions and
# /usr/share/waylandsessions). An empty or missing folder is a [WARN].
hdr "Login sessions available"
for pair in "xsessions:X11" "waylandsessions:Wayland"; do
  key=${pair%%:*}; label=${pair##*:}
  dir=$(cfg "$key"); dir=${dir:-/usr/share/${key%s}s}
  if [[ -d $dir ]]; then
    n=$(find "$dir" -maxdepth 1 -name '*.desktop' 2>/dev/null | wc -l)
    (( n > 0 )) && ok "$label sessions: $n in $dir" || warn "$label: $dir has no .desktop entries"
  else
    warn "$label session dir $dir missing"
  fi
done

# ---------------------------------------------------------------------------
# systemd service wiring, four things: does ly.service exist; is Ly the
# current default DM (display-manager.service links to it); is it enabled at
# boot; and is a text login (getty) also enabled on Ly's console (config's
# tty, default 2)? That last one is a [WARN], not a [FAIL]: ly.service
# declares a Conflicts so systemd won't run both. But two things fighting for
# one console is a race worth removing, not trusting. It is only checked when
# Ly is the default DM.
hdr "systemd service wiring"
if systemctl cat ly.service >/dev/null 2>&1; then
  ok "unit ly.service present"
  dm=$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" 2>/dev/null)
  [[ $dm == ly.service ]] && ok "ly is the active display-manager.service" \
    || info "display-manager.service → ${dm:-<none>} (Ly not the default DM)"
  systemctl is-enabled ly.service >/dev/null 2>&1 && ok "ly.service enabled" \
    || info "ly.service not enabled (fine if another DM is default)"
  tty=$(cfg tty); tty=${tty:-2}
  if systemctl is-enabled "getty@tty${tty}.service" >/dev/null 2>&1 && [[ $dm == ly.service ]]; then
    warn "getty@tty${tty}.service enabled while Ly owns tty${tty} — disable it (ly.service Conflicts it, but leave nothing to race)"
  else
    ok "no getty enabled on Ly's tty${tty}"
  fi
else
  bad "unit ly.service not found (installsystemd step never ran?)"
fi

# ---------------------------------------------------------------------------
hdr "PAM stack ($PAM)"
if [[ -r $PAM ]]; then
  ok "file $PAM"
  # PAM: each service gets a file listing which modules to ask, and files can
  # include one another. Follow /etc/pam.d/ly into its includes and check two
  # things: every included file exists, and every module named is really
  # installed. A module listed but missing on disk means logins fail outright.
  # mods collects "type|module" pairs; miss_inc=1 once an include is missing.
  mods=(); miss_inc=0
  # scan_pam <file>: read the file line by line, skipping blanks and comments.
  # An include line calls scan_pam on the included file, so includes inside
  # includes are followed too. Any other line adds each pam_*.so it names.
  scan_pam() {  # scan_pam <file>
    local f=$1 line ctrl tok
    [[ -r $f ]] || return 1
    while read -r line; do
      [[ -z $line || $line == \#* ]] && continue
      # forms: "@include X" | "type include X" | "type ctrl pam_x.so args"
      read -r a b c _ <<<"$line"
      if [[ $a == @include ]]; then
        [[ -r /etc/pam.d/$b ]] && scan_pam "/etc/pam.d/$b" || { bad "  @include $b → /etc/pam.d/$b missing"; miss_inc=1; }
      elif [[ $b == include ]]; then
        [[ -r /etc/pam.d/$c ]] && scan_pam "/etc/pam.d/$c" || { bad "  include $c → /etc/pam.d/$c missing"; miss_inc=1; }
      else
        for tok in $line; do [[ $tok == pam_*.so ]] && mods+=("${a}|${tok}"); done
      fi
    done < "$f"
  }
  scan_pam "$PAM"
  (( miss_inc == 0 )) && ok "all PAM includes resolve"
  # Check each module once (seen remembers which). A line whose type (first
  # field, stored as ctrl) starts with "-" marks the module optional: PAM skips
  # it quietly if absent, so that is [--], not [FAIL].
  declare -A seen=()
  for entry in "${mods[@]}"; do
    ctrl=${entry%%|*}; m=${entry##*|}
    [[ -n ${seen[$m]:-} ]] && continue; seen[$m]=1
    if [[ -n $PAM_SEC && -e $PAM_SEC/$m ]]; then
      ok "  module $m"
    elif [[ $ctrl == -* ]]; then
      info "  module $m absent (optional '-' line — skipped at runtime)"
    else
      bad "  module $m NOT found in $PAM_SEC — login will fail"
    fi
  done
else
  # No /etc/pam.d/ly at all: PAM falls back to a default that denies
  # everything, which shows up as "Can't authenticate user".
  bad "file $PAM missing — PAM falls back to /etc/pam.d/other (deny) → 'Can't authenticate user'"
fi

# ---------------------------------------------------------------------------
# logind / XDG_RUNTIME_DIR: a chain that must hold all the way, checked link
# by link. systemd is running as PID 1 (/run/systemd/system exists);
# systemd-logind is active; libpam-systemd is installed and pam_systemd.so is
# present; your runtime folder /run/user/<your id> is owned by you.
# Why: logging in creates a session, the session creates that folder, and the
# desktop puts its sockets in it. Break any link and you get "Can't open
# Wayland socket", which looks like a graphics problem and is not.
# The folder missing right now is only a [WARN]: it is made at login and
# removed when your last session ends.
# Note: under sudo, USER is root and id -u is 0, so this checks root's folder.
hdr "logind / XDG_RUNTIME_DIR prerequisites"
[[ -d /run/systemd/system ]] && ok "systemd is PID 1" || bad "systemd is NOT PID 1 — pam_systemd can't create the runtime dir"
systemctl is-active systemd-logind >/dev/null 2>&1 && ok "systemd-logind active" || bad "systemd-logind not active"
pkg libpam-systemd && ok "pkg libpam-systemd" || bad "libpam-systemd missing — no pam_systemd → no /run/user/<uid> → Wayland socket/lockfile errors"
[[ -n $PAM_SEC && -e $PAM_SEC/pam_systemd.so ]] && ok "module pam_systemd.so present" || bad "pam_systemd.so not found"
rd=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if [[ -d $rd ]]; then
  owner=$(stat -c %U "$rd" 2>/dev/null)
  [[ $owner == "$USER" ]] && ok "runtime dir $rd owned by $USER" \
    || bad "runtime dir $rd owned by '$owner', not $USER (the classic Ly Wayland breakage)"
else
  warn "runtime dir $rd absent right now (created at login by pam_systemd)"
fi

# ---------------------------------------------------------------------------
# Suspend/resume freeze fix: is fix-suspend-freeze.sh's drop-in active on all
# four sleep services? That rules the "login crashes after waking from sleep"
# bug in or out without reproducing it. A service whose Environment does not
# set the var to false, 0 or no gets a [WARN].
# The var only exists from systemd 256. Older systemd has no such bug, and
# the check says so. We look for the var's name inside the systemd-sleep
# binary. Capture into a variable first: `strings | grep -q` would SIGPIPE
# strings under a pipefail caller and read as "not found".
hdr "Suspend/resume freeze fix (fix-suspend-freeze.sh)"
syms=$(strings /usr/lib/systemd/systemd-sleep 2>/dev/null || true)
if [[ $syms == *"$FREEZE_VAR"* ]]; then
  ok "systemd-sleep honors \$$FREEZE_VAR (>= systemd 256)"
  missing_dropin=0
  for svc in "${SLEEP_SERVICES[@]}"; do
    env=$(systemctl show "$svc.service" -p Environment 2>/dev/null)
    [[ $env == *"${FREEZE_VAR}=false"* || $env == *"${FREEZE_VAR}=0"* || $env == *"${FREEZE_VAR}=no"* ]] \
      && ok "  $svc: freeze disabled" || { warn "  $svc: user-session freeze still ENABLED — logins can race the resume thaw"; missing_dropin=1; }
  done
  (( missing_dropin )) && warn "run installers/fix-suspend-freeze.sh to close the post-resume login race"
else
  info "systemd < 256 (or no systemd-sleep) — freeze bug doesn't apply"
fi

# ---------------------------------------------------------------------------
# Journal scan: the system log (journal) is the only record of a failure that
# happened while you had no desktop. Count each kind of error over the last 30
# days, with the time of the newest one. All hits are [WARN] by design; they
# describe the past. "3 hits, newest ~two weeks ago" right after a fix is how
# you confirm the fix worked.
# Reading the system log needs permission. JR is the reader command, tried in
# this order: passwordless sudo; membership in group adm or systemd-journal;
# asking for a sudo password if stdin is a terminal. None works -> one [WARN]
# telling you to re-run with sudo, and the section is skipped.
hdr "Journal scan — past Ly failures"
JR=""
if sudo -n true 2>/dev/null; then JR="sudo journalctl"
elif id -nG | tr ' ' '\n' | grep -qxE 'adm|systemd-journal'; then JR="journalctl"
elif [[ -t 0 ]] && sudo -v 2>/dev/null; then JR="sudo journalctl"
fi
if [[ -z $JR ]]; then
  warn "journal scan skipped — re-run with sudo (or join group systemd-journal) to check for past crashes"
else
  # scanj <label> <extended-regex>: count matching journal lines (last 30
  # days). None -> [OK]. Some -> [WARN] with the count and the first 16
  # characters (the timestamp) of the newest line.
  scanj() {
    local label=$1 re=$2 out cnt last
    out=$($JR --no-pager --since "-30 days" 2>/dev/null | grep -aE "$re" || true)
    cnt=$(printf '%s' "$out" | grep -c . || true)
    if (( cnt == 0 )); then ok "$label: none in last 30d"; else
      last=$(printf '%s\n' "$out" | tail -1 | cut -c1-16)
      warn "$label: $cnt hit(s), newest ~$last"
    fi
  }
  scanj "session-scope freeze (the suspend bug)" "Cannot start frozen unit session|for unit 'session-[0-9]+\.scope' failed with 'frozen'"
  scanj "pam_systemd create-session failures"     "pam_systemd\(.*\): Failed to create session"
  scanj "Wayland socket / lockfile errors"        "[Uu]nable to open lockfile|[Cc]an.t open Wayland socket|error opening wayland"
  scanj "PAM auth failures"                        "pam_unix\(ly:auth\).*authentication failure|Can.t authenticate"
  # Only real crashes: core dumps and kills. A normal DM stop logs status=15
  # (SIGTERM). That is a clean shutdown, not a crash, so it is not counted.
  scanj "ly.service crashes (core-dump/killed)"    "ly\.service:.*(core-dump|code=dumped|code=killed)"
  info "detail: ${JR} -u ly.service   (or add --since '-7 days')"
fi

# ---------------------------------------------------------------------------
# Build headers, last and least: the two dev packages needed to REBUILD Ly.
# Missing ones are [WARN]; you only need them for install-ly.sh --reinstall.
hdr "Build headers (only needed to rebuild/--reinstall)"
for p in libpam0g-dev libxcb-xkb-dev; do
  pkg "$p" && ok "pkg $p" || warn "pkg $p missing (needed only to rebuild Ly)"
done

# ---------------------------------------------------------------------------
# Totals, then the exit code: 0 only if nothing failed.
echo
printf '\033[1mPassed: %d  Failed: %d  Warnings: %d\033[0m\n' "$P" "$F" "$W"
[[ $F -eq 0 ]]
