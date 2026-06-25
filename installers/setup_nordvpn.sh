#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh setup_nordvpn.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# setup_nordvpn.sh — replace snap-installed nordvpn with the official deb,
# enroll user in nordvpn group. Idempotent.
set -euo pipefail

dry=0; mode=install
for a in "$@"; do
  case $a in
    --dry-run)   dry=1 ;;
    --uninstall) mode=uninstall ;;
    -h|--help)   echo "Usage: $0 [--dry-run] [--uninstall]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
have(){ command -v "$1" >/dev/null 2>&1; }

for c in curl sudo; do
  have "$c" || { echo "missing: $c" >&2; exit 1; }
done

if [[ $mode == uninstall ]]; then
  have nordvpn && { run sudo apt-get purge -y nordvpn; run sudo apt-get autoremove -y; } \
                || echo "nordvpn not installed."
  exit 0
fi

# Remove the snap version if present (rare).
have snap && snap list nordvpn >/dev/null 2>&1 && run sudo snap remove nordvpn

# Upstream installer is non-idempotent (re-runs the apt-source add); guard explicitly.
if have nordvpn && dpkg -s nordvpn >/dev/null 2>&1; then
  echo "nordvpn (deb) already installed — skipping installer."
elif (( dry )); then
  echo "DRY  sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)"
else
  sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
fi

if ! getent group nordvpn >/dev/null 2>&1; then
  echo "warn: nordvpn group missing — installer may have failed."
elif id -nG "$USER" | tr ' ' '\n' | grep -qx nordvpn; then
  echo "$USER already in nordvpn group."
else
  run sudo usermod -aG nordvpn "$USER"
fi

echo "Log out/in (for group change), then: nordvpn login && nordvpn connect"
