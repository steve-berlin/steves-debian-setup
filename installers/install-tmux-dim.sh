#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-tmux-dim.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-tmux-dim.sh — build tmux from source with the inactive-pane dim patch
# and install to /usr/local/bin (shadows the distro tmux without removing it).
# See CLAUDE.md "installers/" → "install-tmux-dim.sh" for the design notes.
set -euo pipefail

TMUX_VERSION=${TMUX_VERSION:-3.5a}
SRC_URL="https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz"
PATCH=$(cd "$(dirname "$0")" && pwd)/patches/tmux-dim-inactive-panes.patch
PREFIX=/usr/local
INSTALLED_BIN=$PREFIX/bin/tmux
STAMP=$PREFIX/share/tmux-dim.version

dry=0; mode=install
for a in "$@"; do
  case $a in
    --dry-run)   dry=1 ;;
    --reinstall) mode=reinstall ;;
    --uninstall) mode=uninstall ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--reinstall|--uninstall]"
      echo "  Builds tmux $TMUX_VERSION + dim-inactive-panes patch into $PREFIX."
      echo "  Override version: TMUX_VERSION=3.5a $0"
      exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

if [[ $mode == uninstall ]]; then
  # Leaves the distro tmux at /usr/bin/tmux untouched.
  run sudo rm -f "$INSTALLED_BIN" "$PREFIX/share/man/man1/tmux.1" "$STAMP"
  echo "removed patched tmux from $PREFIX (distro tmux at /usr/bin/tmux untouched)"
  exit 0
fi

# Preflight: patch present, build deps available, network reachable.
[[ -f $PATCH ]] || { echo "error: patch not found at $PATCH" >&2; exit 1; }

need_pkgs=()
need() { command -v "$1" >/dev/null || need_pkgs+=("$2"); }
need cc          build-essential
need make        build-essential
need pkg-config  pkg-config
need patch       patch
need curl        curl
need tar         tar
# libevent + ncurses headers — apt names; can't probe with `command -v`.
dpkg -s libevent-dev >/dev/null 2>&1   || need_pkgs+=(libevent-dev)
dpkg -s libncurses-dev >/dev/null 2>&1 || dpkg -s libncurses5-dev >/dev/null 2>&1 || need_pkgs+=(libncurses-dev)
dpkg -s bison >/dev/null 2>&1          || need_pkgs+=(bison)
if (( ${#need_pkgs[@]} )); then
  run sudo apt-get update
  run sudo apt-get install -y "${need_pkgs[@]}"
fi

# Skip rebuild if already at this version (idempotent re-run).
if [[ $mode == install && -x $INSTALLED_BIN && -f $STAMP ]] \
   && grep -qx "$TMUX_VERSION" "$STAMP"; then
  echo "patched tmux $TMUX_VERSION already installed at $INSTALLED_BIN — no-op"
  echo "(use --reinstall to force a rebuild)"
  exit 0
fi

# Build in a temp dir; cleanup on any exit.
tmp=
cleanup() { [[ -n ${tmp:-} && -d $tmp ]] && rm -rf "$tmp"; }
trap cleanup EXIT
tmp=$(mktemp -d -t tmux-dim-XXXXXX)

run cd "$tmp"
run curl -fsSL -o "tmux-${TMUX_VERSION}.tar.gz" "$SRC_URL"
run tar xf "tmux-${TMUX_VERSION}.tar.gz"
run cd "tmux-${TMUX_VERSION}"

# --dry-run sanity-checks the patch against the source tree without applying.
# Critical: a future tmux release that drifts past the hunks would otherwise
# silently produce a tmux with no dimming and no error.
if (( dry )); then
  echo "DRY  patch --dry-run -p1 -i $PATCH"
else
  patch --dry-run -p1 -i "$PATCH" >/dev/null
  patch -p1 -i "$PATCH"
fi

run ./configure --prefix="$PREFIX"
run make -j"$(nproc)"
run sudo make install
run sudo bash -c "echo $TMUX_VERSION > $STAMP"

echo "── done ── /usr/local/bin/tmux now has dim-inactive-panes ($TMUX_VERSION)."
echo "/usr/local/bin must precede /usr/bin on PATH (default on Debian)."
echo "Verify with: hash -r && tmux -V && which tmux"
