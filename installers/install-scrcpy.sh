#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-scrcpy.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-scrcpy.sh — install scrcpy from upstream prebuilt linux-x86_64 release,
# shadowing the distro scrcpy under /usr/local. Debian's package lags upstream
# by 6-12 months and misses v3 features (virtual-display, audio, camera).
# See CLAUDE.md "installers/" → "install-scrcpy.sh" for design notes.
set -euo pipefail

REPO=Genymobile/scrcpy
PREFIX=/usr/local
SHARE=$PREFIX/share/scrcpy
BIN=$PREFIX/bin/scrcpy
MAN=$PREFIX/share/man/man1/scrcpy.1
STAMP=$PREFIX/share/scrcpy.version
ASSET_RE='scrcpy-linux-x86_64-v[0-9].*[.]tar[.]gz$'

dry=0; mode=install
tmp=""  # script-scoped so EXIT trap can rm it (gotcha shared with install-anki.sh)
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

uninstall_scrcpy() {
  run sudo rm -rf "$SHARE" "$BIN" "$MAN" "$STAMP"
  echo "Removed $PREFIX scrcpy. Distro /usr/bin/scrcpy (if any) untouched."
}

install_scrcpy() {
  for c in curl tar sudo awk sed dpkg-query; do
    command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
  done

  # Runtime deps via distro scrcpy package — its Depends covers adb, libav*,
  # libsdl2, libusb1 across Debian/MX/Ubuntu without us pinning sonames.
  if ! dpkg-query -W -f='${Status}' scrcpy 2>/dev/null | grep -q "ok installed"; then
    run sudo apt-get update
    run sudo apt-get install -y scrcpy \
      || run sudo apt-get install -y adb ffmpeg libsdl2-2.0-0 libusb-1.0-0 libv4l-0
  fi

  # Same awk pattern as install-anki.sh — don't `exit` from awk (SIGPIPE +
  # pipefail would silently wipe the substitution). Use a `seen` flag.
  local url ver
  url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases" \
        | awk -F'"' -v re="$ASSET_RE" \
            '/"browser_download_url":/ && $4 ~ re && !seen {print $4; seen=1}')
  [[ -n $url ]] || { echo "No matching scrcpy linux-x86_64 asset in recent releases." >&2; exit 1; }
  ver=$(printf '%s' "${url##*/}" | sed -E 's/.*-(v[0-9][^/]*)\.tar\.gz/\1/')
  echo "Found: $url ($ver)"

  if [[ $mode == install && -x $BIN ]] && grep -qx "$ver" "$STAMP" 2>/dev/null; then
    echo "scrcpy $ver already at $PREFIX — no-op (use --reinstall to force)"
    return 0
  fi

  tmp=$(mktemp -d)
  run curl -fsSL --retry 3 -o "$tmp/${url##*/}" "$url"
  run tar -xzf "$tmp/${url##*/}" -C "$tmp"
  (( dry )) && { echo "DRY  install extracted dir to $SHARE + wrapper $BIN + stamp $STAMP"; return 0; }

  local dir
  dir=$(find "$tmp" -maxdepth 1 -type d -name 'scrcpy-linux-x86_64-*' | head -n1)
  [[ -d $dir ]] || { echo "extracted dir not found in $tmp" >&2; exit 1; }

  sudo rm -rf "$SHARE"
  sudo mkdir -p "$SHARE" "$(dirname "$MAN")"
  sudo cp -a "$dir"/. "$SHARE/"

  # Upstream's bundled `scrcpy` does `cd "$(dirname ${0})"` then execs
  # `./scrcpy-bin` with LD_LIBRARY_PATH=$PWD. Symlinking $BIN→$SHARE/scrcpy
  # breaks that (dirname resolves to /usr/local/bin). Exec the bundled wrapper
  # at its real path so the dirname resolution lands inside $SHARE.
  sudo install -m 755 /dev/stdin "$BIN" <<EOF
#!/bin/sh
exec $SHARE/scrcpy "\$@"
EOF
  [[ -f $SHARE/scrcpy.1 ]] && sudo ln -sf "$SHARE/scrcpy.1" "$MAN"
  echo "$ver" | sudo tee "$STAMP" >/dev/null
  echo "── done ── scrcpy $ver at $PREFIX (shadows /usr/bin/scrcpy). rbxvm: 'adb connect 127.0.0.1:5555 && scrcpy'"
}

case $mode in
  install)   install_scrcpy ;;
  uninstall) uninstall_scrcpy ;;
  reinstall) uninstall_scrcpy; install_scrcpy ;;
esac
