#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-anki.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-anki.sh — install Anki from upstream "anki-launcher" tarball.
# See CLAUDE.md "installers/" → "install-anki.sh" for the two non-obvious gotchas
# (don't `exit` from awk; don't `local tmp` referenced by EXIT trap).
set -euo pipefail

REPO=ankitects/anki
PREFIX=/usr/local
ASSET_RE='anki-launcher-.*-linux[.]tar[.]zst$'

dry=0; mode=install
tmp=""  # script-scoped so EXIT trap can rm it
trap 'rm -rf "${tmp:-}"' EXIT

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

uninstall_anki() {
  local sh=$PREFIX/share/anki/uninstall.sh
  if [[ -x $sh ]]; then run sudo "$sh"; else echo "No Anki at $PREFIX."; fi
}

install_anki() {
  for c in curl tar sudo awk; do
    command -v "$c" >/dev/null || { echo "missing: $c (apt install $c)" >&2; exit 1; }
  done
  tar --help 2>&1 | grep -q -- '--zstd' \
    || { echo "tar lacks zstd — sudo apt install zstd" >&2; exit 1; }

  # Walk recent releases newest-first and take the first asset URL matching
  # ASSET_RE. Don't `exit` from awk — pipefail + SIGPIPE on curl would silently
  # wipe the substitution. Use a `seen` flag instead.
  local url
  url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases" \
        | awk -F'"' -v re="$ASSET_RE" \
            '/"browser_download_url":/ && $4 ~ re && !seen {print $4; seen=1}')
  [[ -n $url ]] || { echo "No matching launcher asset in recent releases." >&2; exit 1; }
  echo "Found: $url"

  tmp=$(mktemp -d)
  local file=$tmp/${url##*/}
  run curl -fsSL --retry 3 -o "$file" "$url"
  run tar -xaf "$file" -C "$tmp"

  if (( dry )); then
    echo "DRY  cd <extracted dir> && sudo ./install.sh"
  else
    local dir
    dir=$(find "$tmp" -maxdepth 1 -type d -name 'anki-*' | head -n1)
    [[ -d $dir ]] || { echo "extracted dir not found in $tmp" >&2; exit 1; }
    ( cd "$dir" && sudo ./install.sh )
  fi
  echo "Done. Launch with: anki"
}

case $mode in
  install)   install_anki ;;
  uninstall) uninstall_anki ;;
  reinstall) uninstall_anki; install_anki ;;
esac
