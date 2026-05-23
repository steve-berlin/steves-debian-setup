#!/usr/bin/env bash
# setup_nordvpn.sh — replace any snap-installed nordvpn with the official
# deb-repo build and enroll the user in the nordvpn group.
#
# Idempotent: re-running on an already-installed deb-version is a no-op.
# --dry-run prints actions, mutates nothing. --uninstall removes the deb.

set -euo pipefail

dry=0; mode=install
for a in "$@"; do
  case $a in
    --dry-run)   dry=1 ;;
    --uninstall) mode=uninstall ;;
    -h|--help)   sed -n '2,6p' "$0"; echo "Usage: $0 [--dry-run] [--uninstall]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# preflight
for c in curl sudo; do
  have "$c" || { echo "missing: $c" >&2; exit 1; }
done

if [[ $mode == uninstall ]]; then
  if have nordvpn; then
    run sudo apt-get purge -y nordvpn
    run sudo apt-get autoremove -y
  else
    echo "nordvpn not installed — nothing to remove."
  fi
  exit 0
fi

# 1. Remove the snap version if present. `snap` itself may not be installed
#    on a fresh MX box; only the rare snap-converted user needs this.
if have snap && snap list nordvpn >/dev/null 2>&1; then
  run sudo snap remove nordvpn
fi

# 2. Run the official installer only if the deb-version isn't already on
#    PATH. The upstream installer is non-idempotent in places (re-runs the
#    apt-source add) so guard explicitly.
if have nordvpn && dpkg -s nordvpn >/dev/null 2>&1; then
  echo "nordvpn (deb) already installed — skipping installer."
else
  if (( dry )); then
    printf 'DRY  sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)\n'
  else
    sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
  fi
fi

# 3. Add the user to the nordvpn group. Idempotent — usermod -aG on an
#    already-member is a no-op.
if getent group nordvpn >/dev/null 2>&1; then
  if id -nG "$USER" | tr ' ' '\n' | grep -qx nordvpn; then
    echo "$USER already in nordvpn group."
  else
    run sudo usermod -aG nordvpn "$USER"
  fi
else
  echo "warn: nordvpn group missing — installer may have failed."
fi

echo "Log out/in (for the group change), then: nordvpn login && nordvpn connect"
