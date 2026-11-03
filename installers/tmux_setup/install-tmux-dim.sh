#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-tmux-dim.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-tmux-dim.sh — build a tmux that visibly dims the panes you are NOT
# using.
#
# THE PROBLEM
# Split a terminal into four panes and they all look equally bright. Nothing
# says which one your keyboard is talking to. You find out by typing.
# tmux has a built-in setting for this (window-style / window-active-style),
# and it half works. It can only recolour cells that use the terminal's
# DEFAULT colours. Text that sets its own colour (syntax highlighting, a
# lazygit screen, coloured logs) ignores it. So the busiest panes stay at full
# brightness, which is the opposite of helpful.
#
# THE FIX
# Build tmux from its source code with a patch applied. A patch is a small set
# of edits to the original code. This one dims every cell on its way to the
# screen, whatever colour it was. Each colour in an inactive pane loses about
# 30% of its colourfulness, and is blended 35% toward the pane's background.
# It reads as "pushed back" rather than "greyed out", and works on any
# content. There are no settings to tune: the two numbers are compiled in.
#
# WHERE IT GOES
# The system's own tmux lives at /usr/bin/tmux and belongs to apt. This build
# goes to /usr/local/bin/tmux, and both stay on the machine. On Debian
# /usr/local/bin comes earlier in the search path (PATH) than /usr/bin, so
# typing `tmux` finds the patched one. apt still owns the original, so a
# system upgrade can't overwrite the build, and uninstalling is just deleting
# one file: the distro version is right there underneath.
#
# Usage:
#   bash installers/tmux_setup/install-tmux-dim.sh              # build + install
#   bash installers/tmux_setup/install-tmux-dim.sh --dry-run    # plan only
#   bash installers/tmux_setup/install-tmux-dim.sh --reinstall  # rebuild anyway
#   bash installers/tmux_setup/install-tmux-dim.sh --uninstall  # remove
#   TMUX_VERSION=3.5a bash installers/tmux_setup/install-tmux-dim.sh   # other version
#
# Check it worked: `hash -r && tmux -V && which tmux` should show
# /usr/local/bin/tmux. Then split a pane (prefix + ") and move between panes
# (prefix + ;) to see the effect.
# Already-running tmux servers keep using the old program until you
# `tmux kill-server` or log out and back in. A running server is one process
# started from the old file; a new file on disk doesn't change it.
#
# Not what the deployed box runs: there the tmux config comes from a separate
# repo (steves-cli-setup), which dims with tmux's built-in window-style
# settings, not this patch. So this script is optional even there. It is the
# stronger version of an effect that box already has a weaker form of.
#
# Exit codes:
#   0  built and installed, already installed, uninstalled, or dry-run finished
#   1  patch file missing, download failed, or the patch no longer applies
#   2  unknown argument
set -euo pipefail

# TMUX_VERSION: which tmux release to build. Defaults to 3.5a; set it in the
#   environment to override.
# SRC_URL: where that release's source tarball is downloaded from.
# PATCH: the dim patch, found next to this script in patches/. The cd + pwd
#   turns the script's folder into a full path, so it works from any folder.
# PREFIX: install root. `make install` puts the binary in $PREFIX/bin.
# INSTALLED_BIN: the patched tmux, once installed.
# STAMP: a one-line file holding the version we installed. A re-run reads it
#   to decide whether there is anything to do.
TMUX_VERSION=${TMUX_VERSION:-3.5a}
SRC_URL="https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz"
PATCH=$(cd "$(dirname "$0")" && pwd)/patches/tmux-dim-inactive-panes.patch
PREFIX=/usr/local
INSTALLED_BIN=$PREFIX/bin/tmux
STAMP=$PREFIX/share/tmux-dim.version

# dry=1 means "print each command instead of running it".
# mode: install (default), reinstall (rebuild even if the stamp matches), or
# uninstall. Any other argument is an error and exits with code 2.
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

# run: in dry-run, print "DRY  <command>"; otherwise run it.
run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# --uninstall: delete the built program, its manual page and the stamp. The
# distro tmux at /usr/bin/tmux was never touched, so you land back on it
# straight away.
if [[ $mode == uninstall ]]; then
  # Leaves the distro tmux at /usr/bin/tmux untouched.
  run sudo rm -f "$INSTALLED_BIN" "$PREFIX/share/man/man1/tmux.1" "$STAMP"
  echo "removed patched tmux from $PREFIX (distro tmux at /usr/bin/tmux untouched)"
  exit 0
fi

# Step 1 (preflight): the patch file must exist, and the build tools must be
# there. There is no separate network check; a failed download stops the
# script later (exit 1).
[[ -f $PATCH ]] || { echo "error: patch not found at $PATCH" >&2; exit 1; }

# need_pkgs collects the apt packages that are missing.
# need PROGRAM PACKAGE: if PROGRAM is not on PATH, add PACKAGE to the list.
# cc is the C compiler; build-essential provides it and make.
need_pkgs=()
need() { command -v "$1" >/dev/null || need_pkgs+=("$2"); }
need cc          build-essential
need make        build-essential
need pkg-config  pkg-config
need patch       patch
need curl        curl
need tar         tar
# libevent + ncurses headers — apt names; can't probe with `command -v`.
# So ask dpkg whether each package is installed. Either libncurses-dev or the
# older libncurses5-dev counts. bison (a code generator tmux's build uses) is
# checked the same way.
dpkg -s libevent-dev >/dev/null 2>&1   || need_pkgs+=(libevent-dev)
dpkg -s libncurses-dev >/dev/null 2>&1 || dpkg -s libncurses5-dev >/dev/null 2>&1 || need_pkgs+=(libncurses-dev)
dpkg -s bison >/dev/null 2>&1          || need_pkgs+=(bison)
# apt-install only what is missing. (A package may appear twice in the list,
# e.g. build-essential; apt doesn't mind.)
if (( ${#need_pkgs[@]} )); then
  run sudo apt-get update
  run sudo apt-get install -y "${need_pkgs[@]}"
fi

# Step 2: skip everything if this version is already built. A plain run with
# the binary present and a stamp that says exactly $TMUX_VERSION does
# nothing. --reinstall skips this check and rebuilds.
if [[ $mode == install && -x $INSTALLED_BIN && -f $STAMP ]] \
   && grep -qx "$TMUX_VERSION" "$STAMP"; then
  echo "patched tmux $TMUX_VERSION already installed at $INSTALLED_BIN — no-op"
  echo "(use --reinstall to force a rebuild)"
  exit 0
fi

# Step 3: download the source into a temporary folder. The EXIT trap deletes
# that folder when the script ends, whatever happens. tmp starts empty so
# cleanup() is safe even if the script dies before mktemp runs. (The folder
# is made, and removed, even under --dry-run.)
tmp=
cleanup() { [[ -n ${tmp:-} && -d $tmp ]] && rm -rf "$tmp"; }
trap cleanup EXIT
tmp=$(mktemp -d -t tmux-dim-XXXXXX)

run cd "$tmp"
run curl -fsSL -o "tmux-${TMUX_VERSION}.tar.gz" "$SRC_URL"
run tar xf "tmux-${TMUX_VERSION}.tar.gz"
run cd "tmux-${TMUX_VERSION}"

# Step 4: test the patch before applying it. `patch --dry-run` first, then
# for real. This matters more than it sounds. A future tmux release could
# move the code the patch expects. Then `patch` would apply what it could and
# skip the rest. You'd get a tmux that builds fine, installs fine, and dims
# nothing, with no error anywhere. The dry run turns that into an immediate,
# loud failure (set -e stops the script, exit 1). -p1 strips the first folder
# name from the paths inside the patch.
if (( dry )); then
  echo "DRY  patch --dry-run -p1 -i $PATCH"
else
  patch --dry-run -p1 -i "$PATCH" >/dev/null
  patch -p1 -i "$PATCH"
fi

# Step 5: build and install, then write the version stamp.
# make -j"$(nproc)" compiles on every CPU core at once.
run ./configure --prefix="$PREFIX"
run make -j"$(nproc)"
run sudo make install
run sudo bash -c "echo $TMUX_VERSION > $STAMP"

echo "── done ── /usr/local/bin/tmux now has dim-inactive-panes ($TMUX_VERSION)."
echo "/usr/local/bin must precede /usr/bin on PATH (default on Debian)."
echo "Verify with: hash -r && tmux -V && which tmux"
