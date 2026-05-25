#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-steam.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-steam.sh — install Steam from apt + non-free (Debian) or apt (Ubuntu).
# See CLAUDE.md "installers/" → "install-steam.sh" for why this exists.
set -euo pipefail

dry=0; mode=install
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --reinstall) mode=reinstall ;;
    --dry-run)   dry=1 ;;
    -h|--help)   echo "Usage: $0 [--reinstall|--uninstall] [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

for c in apt-get dpkg sudo; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

# Detect distro family → set DISTRO + PKG.
[[ -f /etc/os-release ]] || { echo "no /etc/os-release" >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *ubuntu*)      DISTRO=ubuntu; PKG=steam ;;
  *debian*|*mx*) DISTRO=debian; PKG=steam-installer ;;
  *)             DISTRO=other;  PKG=steam ;;
esac
echo "distro: $DISTRO   package: $PKG"

uninstall_steam() {
  if dpkg -s "$PKG" >/dev/null 2>&1; then
    run sudo apt-get purge -y "$PKG"
    run sudo apt-get autoremove -y
  else
    echo "$PKG not installed."
  fi
  echo "Note: ~/.steam (library, Proton, saves) preserved."
}

install_steam() {
  # On Debian, Steam lives in non-free. Add contrib + non-free + non-free-firmware
  # to every active deb/deb-src line that's missing them. Idempotent.
  if [[ $DISTRO == debian && -f /etc/apt/sources.list ]] \
     && awk '/^deb / && (!/contrib/ || !/non-free/) {bad=1} END {exit !bad}' /etc/apt/sources.list; then
    echo "Adding contrib + non-free + non-free-firmware to /etc/apt/sources.list…"
    run sudo cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)"
    run sudo sed -i -E '/^deb(-src)? /{
      /contrib/!s/$/ contrib/
      /non-free-firmware/!s/$/ non-free-firmware/
      /non-free([^-]|$)/!s/$/ non-free/
    }' /etc/apt/sources.list
  fi

  if dpkg --print-foreign-architectures | grep -qx i386; then
    echo "i386 already enabled."
  else
    run sudo dpkg --add-architecture i386
  fi

  run sudo apt-get update
  if ! run sudo apt-get install -y "$PKG"; then
    # Debian sometimes packages it as `steam` too; Ubuntu sometimes as `steam-installer`.
    local alt
    [[ $PKG == steam-installer ]] && alt=steam || alt=steam-installer
    echo "  → $PKG failed; trying $alt…"
    run sudo apt-get install -y "$alt"
  fi

  echo "Done. Launch via 'stm' (sets perf profile + registers /games/steam library)."
}

case $mode in
  install)   install_steam ;;
  uninstall) uninstall_steam ;;
  reinstall) uninstall_steam; install_steam ;;
esac
