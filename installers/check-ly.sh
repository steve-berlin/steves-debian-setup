#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh check-ly.sh` — uses `[[`, arrays, ${var//}.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# check-ly.sh — read-only health check for the whole Ly display-manager stack.
# Mutates nothing. Surfaces every known Ly failure mode up front so a broken
# login is diagnosed here instead of at a black screen. Companion to
# install-ly.sh + fix-suspend-freeze.sh; mirrors check-setup.sh's OK/FAIL style.
#
# Exit 0 if no FAILs. WARN never fails the run (advisory / historical).
# Journal scan needs to read the system journal — run with sudo (or be in the
# `systemd-journal`/`adm` group) for it; without that it degrades to a WARN.
set -u

P=0; F=0; W=0
ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; P=$((P+1)); }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; F=$((F+1)); }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; W=$((W+1)); }
info() { printf '\033[1;34m[--]\033[0m   %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
pkg()  { dpkg -s "$1" >/dev/null 2>&1; }

CONF=/etc/ly/config.ini
PAM=/etc/pam.d/ly
STAMP=/usr/local/share/ly.version
SLEEP_SERVICES=(systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate)
FREEZE_VAR=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS

# cfg <key> — echo the value of a config.ini key, inline-comment + ws stripped.
cfg() {
  [[ -r $CONF ]] || return 0
  local v; v=$(grep -E "^\s*$1\s*=" "$CONF" 2>/dev/null | head -1 | sed -E "s/^\s*$1\s*=\s*//; s/\s*#.*$//; s/\s+$//")
  echo "$v"
}

# Locate the PAM module dir (pam_unix.so lives there) once.
PAM_SEC=$(dirname "$(find /lib /usr/lib -name pam_unix.so 2>/dev/null | head -1)" 2>/dev/null)

# ---------------------------------------------------------------------------
hdr "Binary & version"
if [[ -x /usr/bin/ly ]]; then
  ok "bin  /usr/bin/ly (executable)"
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
hdr "Config & setup scripts"
if [[ -r $CONF ]]; then
  ok "file $CONF"
  for s in /etc/ly/xsetup.sh /etc/ly/wsetup.sh; do
    [[ -x $s ]] && ok "exec $s" || bad "$s missing/not-executable (X/Wayland session launch relies on it)"
  done
  # Ly writes save_file as root at login (the DM runs as root), so only the
  # dir's existence matters — not user-writability.
  save=$(cfg save_file); save=${save:-/etc/ly/save}
  savedir=$(dirname "$save")
  [[ -d $savedir ]] && ok "save dir present ($savedir)" \
    || warn "save dir $savedir missing — last-user/session won't persist"
else
  bad "file $CONF missing — Ly falls back to compiled defaults"
fi

# ---------------------------------------------------------------------------
hdr "Config-referenced commands"
# A missing binary named in config.ini is a real, silent Ly failure at login.
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
  # Resolve include targets and referenced modules (one level into includes).
  mods=(); miss_inc=0
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
  # Verify each referenced module exists; a '-'-prefixed control means optional.
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
  bad "file $PAM missing — PAM falls back to /etc/pam.d/other (deny) → 'Can't authenticate user'"
fi

# ---------------------------------------------------------------------------
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
hdr "Suspend/resume freeze fix (fix-suspend-freeze.sh)"
# The var only exists from systemd 256; grep the binary (capture to a var — a
# `strings | grep -q` would SIGPIPE strings under a pipefail caller).
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
hdr "Journal scan — past Ly failures"
# Needs system-journal read. Pick a reader or degrade to WARN.
JR=""
if sudo -n true 2>/dev/null; then JR="sudo journalctl"
elif id -nG | tr ' ' '\n' | grep -qxE 'adm|systemd-journal'; then JR="journalctl"
elif [[ -t 0 ]] && sudo -v 2>/dev/null; then JR="sudo journalctl"
fi
if [[ -z $JR ]]; then
  warn "journal scan skipped — re-run with sudo (or join group systemd-journal) to check for past crashes"
else
  # scanj <label> <extended-regex> — count matches (last 30 days) + newest line.
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
  # Only real crashes — not the status=15 SIGTERM that a normal DM stop produces.
  scanj "ly.service crashes (core-dump/killed)"    "ly\.service:.*(core-dump|code=dumped|code=killed)"
  info "detail: ${JR} -u ly.service   (or add --since '-7 days')"
fi

# ---------------------------------------------------------------------------
hdr "Build headers (only needed to rebuild/--reinstall)"
for p in libpam0g-dev libxcb-xkb-dev; do
  pkg "$p" && ok "pkg $p" || warn "pkg $p missing (needed only to rebuild Ly)"
done

# ---------------------------------------------------------------------------
echo
printf '\033[1mPassed: %d  Failed: %d  Warnings: %d\033[0m\n' "$P" "$F" "$W"
[[ $F -eq 0 ]]
