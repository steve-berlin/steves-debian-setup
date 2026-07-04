#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh fix-suspend-freeze.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# fix-suspend-freeze.sh — stop logins from crashing right after resume.
#
# systemd 256+ freezes user.slice (via systemd-sleep) when entering sleep and
# thaws it on resume. On this T480 the greeter/getty accepts a login in the
# brief window before user.slice is thawed, so pam_systemd's attempt to create
# the session scope loses the race:
#
#   systemd[1]: Cannot start frozen unit session-N.scope - Session N of User …
#   ly[…]:      pam_systemd(ly:session): Failed to create session:
#               Job NNNN for unit 'session-N.scope' failed with 'frozen'
#
# A failed session scope means no logind session → no /run/user/<uid> set up →
# the Wayland session then dies with "Can't open Wayland socket" / "Unable to
# open lockfile", and the whole thing reads as "Can't authenticate user". It is
# intermittent ("crashes after a few logins") because it only bites when a login
# lands inside the un-thawed window of a suspend/resume cycle. NOTE: this is a
# systemd regression, not a Ly bug — plain getty `login` hits it too.
#
# Fix: set SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false (honored by systemd-sleep,
# added in systemd 256) via a drop-in on every sleep service, so user.slice is
# never frozen and there is no thaw to race. Documented workaround; the freeze
# was added to avoid processes racing during suspend, harmless to skip here.
set -euo pipefail

DROPIN=no-freeze-user-sessions.conf
SERVICES=(systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate)

dry=0; mode=install
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --reinstall) mode=reinstall ;;   # same as install (idempotent), for parity
    --dry-run)   dry=1 ;;
    -h|--help)
      echo "Usage: $0 [--reinstall|--uninstall] [--dry-run]"
      exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

# Under --dry-run a missing dep is a warning, not a hard fail (see install-ly.sh).
preflight() {
  local miss; miss() { (( dry )) && echo "warning: $1" >&2 || { echo "$1" >&2; exit 1; }; }
  command -v systemctl >/dev/null || miss "missing: systemctl — not a systemd box, nothing to fix"
  command -v sudo >/dev/null || miss "missing: sudo"
  # The var only exists from systemd 256. Grep the actual binary so we fail loud
  # on an older systemd where this drop-in would be a silent no-op.
  local sleep_bin=/usr/lib/systemd/systemd-sleep
  if [[ -e $sleep_bin ]]; then
    # Capture into a var rather than `strings | grep -q`: under `set -o pipefail`
    # grep -q closes the pipe on first match, SIGPIPEs strings, and the pipeline
    # reports failure — a false negative. (Same trap install-anki.sh calls out.)
    local syms; syms=$(strings "$sleep_bin" 2>/dev/null || true)
    [[ $syms == *SYSTEMD_SLEEP_FREEZE_USER_SESSIONS* ]] \
      || miss "this systemd's systemd-sleep does not honor SYSTEMD_SLEEP_FREEZE_USER_SESSIONS (need >= 256)"
  else
    miss "missing: $sleep_bin"
  fi
}

install_dropins() {
  preflight
  local content='[Service]
# systemd 256+ freezes user.slice on sleep; a login racing the thaw on resume
# fails with "Cannot start frozen unit session-N.scope". Skip the freeze.
Environment="SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false"'
  for svc in "${SERVICES[@]}"; do
    local dir="/etc/systemd/system/${svc}.service.d"
    local path="$dir/$DROPIN"
    if (( dry )); then
      printf 'DRY  write %s\n' "$path"
      continue
    fi
    sudo install -d -m 0755 "$dir"
    printf '%s\n' "$content" | sudo tee "$path" >/dev/null
  done
  if (( dry )); then echo "DRY  sudo systemctl daemon-reload"; else sudo systemctl daemon-reload; fi
  echo "Done. Takes effect on the next suspend/resume — no reboot needed."
}

uninstall_dropins() {
  for svc in "${SERVICES[@]}"; do
    local dir="/etc/systemd/system/${svc}.service.d"
    local path="$dir/$DROPIN"
    if (( dry )); then printf 'DRY  rm %s (+ rmdir %s if empty)\n' "$path" "$dir"; continue; fi
    sudo rm -f "$path"
    sudo rmdir "$dir" 2>/dev/null || true   # only if we created it and it's now empty
  done
  if (( dry )); then echo "DRY  sudo systemctl daemon-reload"; else sudo systemctl daemon-reload; fi
  echo "Reverted — systemd will freeze user sessions on sleep again."
}

case $mode in
  uninstall)        uninstall_dropins ;;
  install|reinstall) install_dropins ;;
esac
