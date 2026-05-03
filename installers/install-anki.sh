#!/usr/bin/env bash
# install-anki.sh — install/uninstall Anki from the official upstream tarball.
#
# Why this exists: Debian's `anki` package lags upstream by years. Anki's
# official method (since 25.07) is the "anki-launcher" tarball: a small Linux
# launcher that ships install.sh + uninstall.sh and pulls the real app on first
# run. This script just picks the newest release that has the launcher asset,
# downloads it, and hands off to Anki's own installer (which writes /usr/local).
# User data in ~/.local/share/Anki2 is never touched.
set -euo pipefail

REPO="ankitects/anki"
PREFIX="/usr/local"
# Match the upstream launcher asset for Linux. Some tags ship no binaries yet,
# so we walk recent releases until we find one with this asset.
# [.] avoids awk's `-v` escape-stripping (plain \. triggers a warning).
ASSET_RE='anki-launcher-.*-linux[.]tar[.]zst$'

DRY=0
MODE=install   # install | uninstall | reinstall
tmp=""         # scratch dir; kept at script scope so the EXIT trap can see it
trap 'rm -rf "${tmp:-}"' EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") [--reinstall|--uninstall] [--dry-run]

  (no flag)     Install latest Anki from the official tarball (system-wide).
  --reinstall   Uninstall the existing copy, then install fresh.
  --uninstall   Remove a previously-installed Anki (keeps your decks).
  --dry-run     Print every action without changing the system. Combinable.
EOF
}

# --- argument parsing ------------------------------------------------------
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
  || { echo "Missing dependency: $1 (apt install $1)" >&2; exit 1; }; }

preflight() {
  for c in curl tar sudo awk; do need "$c"; done
  # Modern tar auto-detects .zst, but confirm — fail loud if not.
  tar --help 2>&1 | grep -q -- '--zstd' \
    || { echo "tar lacks zstd support — run: sudo apt install zstd" >&2; exit 1; }
}

uninstall_anki() {
  local sh="$PREFIX/share/anki/uninstall.sh"
  if [[ -x $sh ]]; then
    echo "Running Anki's uninstaller (sudo)…"
    run sudo "$sh"
  else
    echo "No Anki install found at $PREFIX — nothing to uninstall."
  fi
}

install_anki() {
  preflight

  echo "Looking up the latest Anki release with a Linux launcher asset…"
  # Walk recent releases (newest first) and take the first download URL whose
  # filename matches ASSET_RE. Skips tags that ship no binaries.
  local url
  # NB: don't `exit` from awk here — that'd SIGPIPE curl and, with pipefail,
  # blow up the whole substitution. Use a `seen` flag to print only the first.
  url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases" \
        | awk -F'"' -v re="$ASSET_RE" \
            '/"browser_download_url":/ && $4 ~ re && !seen {print $4; seen=1}')
  [[ -n $url ]] || { echo "No matching launcher asset in recent releases." >&2; exit 1; }
  echo "Found: $url"

  # Per-run scratch dir, auto-cleaned by the script-level EXIT trap.
  tmp=$(mktemp -d)
  local file="$tmp/${url##*/}"

  echo "Downloading tarball…"
  run curl -fsSL --retry 3 -o "$file" "$url"

  echo "Extracting…"
  run tar -xaf "$file" -C "$tmp"

  # Locate the extracted dir (skip in dry-run since nothing was extracted).
  if (( DRY )); then
    printf 'DRY-RUN: cd <extracted dir> && sudo ./install.sh\n'
  else
    local dir
    dir=$(find "$tmp" -maxdepth 1 -type d -name 'anki-*' | head -n1)
    [[ -d $dir ]] || { echo "Extracted directory not found in $tmp" >&2; exit 1; }
    echo "Running Anki's installer (sudo)…"
    ( cd "$dir" && sudo ./install.sh )
  fi

  echo "Done. Launch with:  anki"
}

case "$MODE" in
  install)   install_anki ;;
  uninstall) uninstall_anki ;;
  reinstall) uninstall_anki; install_anki ;;
esac
