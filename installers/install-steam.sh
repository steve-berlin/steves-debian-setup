#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-steam.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-steam.sh — install/uninstall Steam from the official apt package.
#
# Why this exists: Steam ships its own deb but it lives in `non-free` (Debian)
# and pulls in 32-bit libraries via the i386 architecture. New users hit the
# same three errors every time: i386 not enabled, contrib/non-free not in
# sources, package name differs between Debian (steam-installer) and Ubuntu
# (steam). This script does those three things and nothing else.
#
# It does NOT touch ~/.steam/.../libraryfolders.vdf — the `stm` launcher
# registers /games/steam on first run, idempotently, and only when Steam
# isn't already running.
set -euo pipefail

DRY=0
MODE=install   # install | uninstall | reinstall

usage() {
  cat <<EOF
Usage: $(basename "$0") [--reinstall|--uninstall] [--dry-run]

  (no flag)     Install Steam (adds i386, contrib/non-free if Debian, then apt).
  --reinstall   Purge existing Steam package, then install fresh. Keeps ~/.steam.
  --uninstall   Purge Steam. Keeps ~/.steam (your library + Proton + saves).
  --dry-run     Print every action without changing the system. Combinable.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) MODE=uninstall ;;
    --reinstall) MODE=reinstall ;;
    --dry-run)   DRY=1 ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Unknown flag: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# run <cmd...> — execute, or just print in dry-run mode.
run() { if (( DRY )); then printf 'DRY-RUN: %s\n' "$*"; else "$@"; fi; }

# need <cmd> — bail if a required tool is missing.
need() { command -v "$1" >/dev/null 2>&1 \
  || { echo "Missing dependency: $1" >&2; exit 1; }; }

# Detect the distro family. Sets DISTRO=debian|ubuntu|other and PKG=steam-installer|steam.
detect_distro() {
  [[ -f /etc/os-release ]] || { echo "no /etc/os-release — can't detect distro" >&2; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *ubuntu*)        DISTRO=ubuntu; PKG=steam ;;
    *debian*|*mx*)   DISTRO=debian; PKG=steam-installer ;;
    *)               DISTRO=other;  PKG=steam ;;  # best effort
  esac
}

preflight() {
  for c in apt-get dpkg sudo; do need "$c"; done
}

# On Debian, Steam lives in non-free. Add the components if missing.
# Idempotent: only edits sources.list when the components aren't already there.
ensure_debian_components() {
  [[ $DISTRO == debian ]] || return 0
  local sources=/etc/apt/sources.list
  [[ -f $sources ]] || { echo "no $sources — non-standard install, edit by hand" >&2; return 0; }
  # If every active deb line already has contrib + non-free, we're done.
  if awk '/^deb / && (!/contrib/ || !/non-free/) {bad=1} END {exit !bad}' "$sources"; then
    echo "Adding contrib + non-free + non-free-firmware to $sources…"
    run sudo cp -a "$sources" "${sources}.bak.$(date +%s)"
    # Append the components to every active "deb " / "deb-src " line that's
    # missing them. -E is portable BSD/GNU; \1 captures the existing line.
    run sudo sed -i -E '/^deb(-src)? /{
      /contrib/!s/$/ contrib/
      /non-free-firmware/!s/$/ non-free-firmware/
      /non-free([^-]|$)/!s/$/ non-free/
    }' "$sources"
  else
    echo "contrib + non-free already enabled."
  fi
}

ensure_i386() {
  if dpkg --print-foreign-architectures | grep -qx i386; then
    echo "i386 architecture already enabled."
  else
    echo "Enabling i386 architecture (needed for 32-bit games, Proton, runtime)…"
    run sudo dpkg --add-architecture i386
  fi
}

uninstall_steam() {
  detect_distro
  if dpkg -s "$PKG" >/dev/null 2>&1; then
    echo "Purging $PKG (sudo)…"
    run sudo apt-get purge -y "$PKG"
    run sudo apt-get autoremove -y
  else
    echo "$PKG not installed — nothing to uninstall."
  fi
  echo "Note: ~/.steam (library, Proton, saves) is preserved."
  echo "      Delete it manually if you want a truly clean slate."
}

install_steam() {
  preflight
  detect_distro
  echo "Distro family: $DISTRO   Package: $PKG"

  ensure_debian_components
  ensure_i386
  echo "Updating apt index…"
  run sudo apt-get update

  if dpkg -s "$PKG" >/dev/null 2>&1; then
    echo "$PKG already installed — apt-get install will upgrade if newer."
  fi
  echo "Installing $PKG (sudo)…"
  if ! run sudo apt-get install -y "$PKG"; then
    # Fallback: Debian sometimes packages it as `steam` too, Ubuntu sometimes as `steam-installer`.
    local alt
    [[ $PKG == steam-installer ]] && alt=steam || alt=steam-installer
    echo "  → $PKG failed; trying $alt as fallback…"
    run sudo apt-get install -y "$alt"
  fi

  echo
  echo "Done. First launch: run 'stm' (the launcher in ../launchers/)."
  echo "      stm will register /games/steam as a Steam library on first run."
  echo "      Then in Steam: Settings → Storage → set /games/steam as default."
}

case "$MODE" in
  install)   install_steam ;;
  uninstall) uninstall_steam ;;
  reinstall) uninstall_steam; install_steam ;;
esac
