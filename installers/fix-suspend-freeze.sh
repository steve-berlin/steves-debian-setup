#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh fix-suspend-freeze.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# fix-suspend-freeze.sh — stop logins from crashing right after the laptop
# wakes up.
#
# THE SYMPTOM
# You close the lid, open it later, and type your password. Instead of a
# desktop you get thrown back to the login screen, often with "Can't
# authenticate user". Try again straight away and it usually works. It feels
# random. It is not random, and your password is fine.
#
# WHAT IS ACTUALLY HAPPENING
# systemd is the program that starts and looks after everything else. From
# version 256, when the machine goes to sleep, systemd-sleep FREEZES user.slice
# first. user.slice is the group that holds all your programs. Freezing means
# "stop, stay exactly as you are". It keeps things from half-running while the
# hardware powers down. On wake-up, systemd thaws (unfreezes) them.
#
# That thaw takes a moment. On this T480 the login screen (greeter or getty)
# already accepts your password during that moment. Then pam_systemd tries to
# create your new session. A session lives in a "scope" inside user.slice, and
# user.slice is still frozen. So the scope cannot start, and you see:
#
#   systemd[1]: Cannot start frozen unit session-N.scope - Session N of User …
#   ly[…]:      pam_systemd(ly:session): Failed to create session:
#               Job NNNN for unit 'session-N.scope' failed with 'frozen'
#
# Then it topples over in order. No session scope means no logind session.
# No logind session means no /run/user/<uid> folder. That folder is where the
# desktop keeps its sockets. So the Wayland session dies with "Can't open
# Wayland socket" or "Unable to open lockfile". The login screen reports the
# only thing it can see: "Can't authenticate user".
#
# It only bites when your login lands inside the un-thawed window of a
# suspend/resume. Hence "crashes after a few logins". This is a systemd
# regression, not a Ly bug. A plain text-console getty `login` hits it too.
#
# THE FIX
# systemd-sleep (256+) honors a documented switch that means "don't freeze
# user sessions when sleeping": SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false.
# If nothing is ever frozen, there is no thaw, and no race to lose.
#
# Is it safe to skip the freeze? The freeze exists to stop programs racing the
# hardware while it powers down. Skipping it is a documented, supported option.
# On a laptop the practical effect is nil: programs already have to cope with
# time jumping forward across a suspend. You trade a theoretical race during
# suspend for a real one you are hitting on resume.
#
# Usage:
#   bash installers/fix-suspend-freeze.sh              # apply
#   bash installers/fix-suspend-freeze.sh --dry-run    # print the plan, change nothing
#   bash installers/fix-suspend-freeze.sh --reinstall  # same as a plain run
#   bash installers/fix-suspend-freeze.sh --uninstall  # undo
# No reboot needed. It reloads systemd's config; the setting applies to the
# next suspend.
#
# Checking that it worked:
#   systemctl show systemd-suspend.service -p Environment
# should mention SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false. Then suspend, wake
# up, and run:
#   journalctl -b | grep -i 'unfrozen\|frozen'
# You want "User sessions remain unfrozen on explicit request", and no new
# 'frozen' errors.
#
# Exit codes:
#   0  applied, removed, or dry-run finished
#   1  not a systemd machine, no sudo, or systemd too old
#   2  unknown argument
set -euo pipefail

# DROPIN is the file name of our add-on config. A "drop-in" is a small file in
# <service>.service.d/ that overrides one setting of a service without editing
# the service file itself.
# SERVICES lists all four ways the machine can sleep:
#   systemd-suspend                  sleep to RAM
#   systemd-hibernate                sleep to disk
#   systemd-hybrid-sleep             both at once
#   systemd-suspend-then-hibernate   sleep now, hibernate later
# All four get the drop-in. Otherwise the bug comes back the day you hibernate
# instead of suspending.
DROPIN=no-freeze-user-sessions.conf
SERVICES=(systemd-suspend systemd-hibernate systemd-hybrid-sleep systemd-suspend-then-hibernate)

# dry=1 means "print what would happen, change nothing".
# mode is install (default), reinstall or uninstall.
# --reinstall is the same as a plain run: writing the same file twice changes
# nothing. It exists so every installer in this repo takes the same flags.
# Any other argument is an error and exits with code 2.
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

# preflight: check the box can use the fix before writing anything.
# miss() handles one problem. Normally it prints the message and exits 1.
# Under --dry-run it only prints "warning: ..." and carries on, so you can
# still see the plan on a machine you haven't finished setting up (same idea
# as install-ly.sh). Only install runs preflight; uninstall does not.
preflight() {
  local miss; miss() { (( dry )) && echo "warning: $1" >&2 || { echo "$1" >&2; exit 1; }; }
  command -v systemctl >/dev/null || miss "missing: systemctl — not a systemd box, nothing to fix"
  command -v sudo >/dev/null || miss "missing: sudo"
  # Why check the systemd version so carefully? The setting only exists in
  # systemd 256 and newer. On an older systemd the drop-in would be written
  # fine, be completely ignored, and logins would keep crashing while
  # everything looked correctly set up. So search the actual systemd-sleep
  # program on disk for the setting's name. If the name isn't in there, this
  # systemd doesn't know the setting: stop and say so, rather than leave a
  # silent no-op.
  local sleep_bin=/usr/lib/systemd/systemd-sleep
  if [[ -e $sleep_bin ]]; then
    # `strings` prints the readable text inside a program file. Capture it
    # into a variable rather than `strings | grep -q`. Under
    # `set -o pipefail`, grep -q closes the pipe at the first match, strings
    # gets SIGPIPE, and the whole pipeline reports failure: a false negative.
    # (Same trap install-anki.sh calls out.)
    local syms; syms=$(strings "$sleep_bin" 2>/dev/null || true)
    [[ $syms == *SYSTEMD_SLEEP_FREEZE_USER_SESSIONS* ]] \
      || miss "this systemd's systemd-sleep does not honor SYSTEMD_SLEEP_FREEZE_USER_SESSIONS (need >= 256)"
  else
    miss "missing: $sleep_bin"
  fi
}

# install_dropins: for each sleep service, create
# /etc/systemd/system/<svc>.service.d/ and write the drop-in into it. The
# drop-in sets the variable in the service's environment, so systemd-sleep
# sees it. Then `systemctl daemon-reload` makes systemd re-read its config.
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

# uninstall_dropins: delete our drop-in from each service. Then remove the
# .service.d folder only if it is now empty (rmdir refuses a non-empty
# folder), so another tool's drop-ins are left alone. Then daemon-reload.
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
