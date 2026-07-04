#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-ly.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-ly.sh — build & install the Ly TUI display manager from upstream
# source. Ly isn't packaged for MX/Debian here and needs a matching Zig
# toolchain to build, so this fetches a pinned Zig tarball + a pinned Ly tag
# (like utils.sh does for Go/neovim), builds, and `installexe`s to the system.
#
# After install it OFFERS to make Ly the default DM (y/N prompt): only on a
# "yes" does it disable the current display-manager + getty@tty2 and enable
# ly.service. --default / --no-default skip the prompt for non-interactive use.
#
# Override pins: LY_VERSION=1.0.3 ZIG_VERSION=0.13.0 (Ly 1.0.x needs Zig 0.13;
# v1.0.3 is the last GitHub release, newer Ly moved hosts + wants Zig 0.16).
set -euo pipefail

LY_VERSION=${LY_VERSION:-1.0.3}
ZIG_VERSION=${ZIG_VERSION:-0.13.0}
LY_REPO=https://github.com/fairyglade/ly
STAMP=/usr/local/share/ly.version   # idempotency marker; re-run = no-op

dry=0; mode=install; set_default=-1   # -1 prompt, 1 yes, 0 no
tmp=""  # script-scoped so EXIT trap can rm it
trap 'rm -rf "${tmp:-}"' EXIT

for a in "$@"; do
  case $a in
    --uninstall)  mode=uninstall ;;
    --reinstall)  mode=reinstall ;;
    --dry-run)    dry=1 ;;
    --default)    set_default=1 ;;
    --no-default) set_default=0 ;;
    -h|--help)
      echo "Usage: $0 [--reinstall|--uninstall] [--default|--no-default] [--dry-run]"
      exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# Tee STAMP through sudo, honoring --dry-run.
write_stamp() {
  if (( dry )); then printf 'DRY  write %s = %s\n' "$STAMP" "$LY_VERSION"
  else echo "$LY_VERSION" | sudo tee "$STAMP" >/dev/null; fi
}

current_dm() { basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" 2>/dev/null; }

# Under --dry-run a missing dep is a warning, not a hard fail: dry-run promises
# to print the actions it would take, so it must not abort on a box that hasn't
# installed the build toolchain/headers yet (the very box you'd dry-run on).
preflight() {
  local miss; miss() { (( dry )) && echo "warning: $1" >&2 || { echo "$1" >&2; exit 1; }; }
  for c in git curl tar sudo systemctl; do
    command -v "$c" >/dev/null || miss "missing: $c (apt install $c)"
  done
  # Zig links Ly against system PAM + XCB; build needs their dev headers.
  for p in libpam0g-dev libxcb-xkb-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || miss "missing: $p — sudo apt install $p"
  done
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) miss "unsupported arch $(uname -m) — Zig tarball name only mapped for x86_64/aarch64" ;;
  esac
}

build_install() {
  preflight
  tmp=$(mktemp -d)

  # 1. Fetch the pinned Zig toolchain (not in Debian at a usable version).
  local arch zig_dir zig
  arch=$(uname -m)
  local zurl="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${arch}-${ZIG_VERSION}.tar.xz"
  echo "Fetching Zig ${ZIG_VERSION}: $zurl"
  run curl -fsSL --retry 3 -o "$tmp/zig.tar.xz" "$zurl"
  run tar -xaf "$tmp/zig.tar.xz" -C "$tmp"
  if (( dry )); then
    zig="<zig>"
  else
    zig_dir=$(find "$tmp" -maxdepth 1 -type d -name "zig-linux-${arch}-*" | head -n1)
    [[ -d $zig_dir ]] || { echo "Zig extract dir not found in $tmp" >&2; exit 1; }
    zig=$zig_dir/zig
  fi

  # 2. Clone Ly at the pinned tag (submodules: zigini + clap).
  echo "Cloning Ly v${LY_VERSION}"
  run git clone --depth 1 --branch "v${LY_VERSION}" --recurse-submodules --shallow-submodules \
      "$LY_REPO" "$tmp/ly"

  # 3. Build as the user (surfaces compile errors loudly), then install as root.
  #    v1.0.3 has no -Dinit_system flag: `installexe` writes /usr/bin/ly +
  #    /etc/ly, and the `installsystemd` step (which dependOn's installexe)
  #    adds /usr/lib/systemd/system/ly.service. So `installsystemd` does both.
  #    The root build writes root-owned files into $tmp/.zig-cache; chown the
  #    tree back afterward so the user-mode EXIT trap can remove it.
  if (( dry )); then
    echo "DRY  ( cd $tmp/ly && $zig build )"
    echo "DRY  ( cd $tmp/ly && sudo $zig build installsystemd )"
  else
    ( cd "$tmp/ly" && "$zig" build )
    ( cd "$tmp/ly" && sudo "$zig" build installsystemd )
    sudo chown -R "$(id -u):$(id -g)" "$tmp"
  fi
  write_stamp
  echo "Ly v${LY_VERSION} installed. Config: /etc/ly/config.ini"
}

# Disable whatever DM is wired now + the tty2 getty Ly uses, then enable ly.
make_default() {
  local cur; cur=$(current_dm)
  if [[ -n $cur && $cur != ly.service ]]; then
    echo "Disabling current display manager: $cur"
    run sudo systemctl disable "$cur"
  fi
  run sudo systemctl disable getty@tty2.service   # Ly owns tty2 by default
  run sudo systemctl enable ly.service
  echo "Ly is now the default display manager. Reboot to use it."
}

# Honor --default/--no-default; otherwise prompt. No prompt under --dry-run or
# when stdin isn't a tty (assume no, warn).
maybe_make_default() {
  case $set_default in
    1) make_default; return ;;
    0) echo "Leaving current display manager in place (--no-default)."; return ;;
  esac
  if (( dry )); then echo "DRY  prompt: make Ly the default display manager?"; return; fi
  if [[ ! -t 0 ]]; then
    echo "Non-interactive shell — leaving current DM. Re-run with --default to switch." >&2
    return
  fi
  local cur ans; cur=$(current_dm)
  read -r -p "Make Ly the default display manager${cur:+ (disables $cur)}? [y/N] " ans
  [[ $ans == [yY]* ]] && make_default || echo "Left current display manager in place."
}

uninstall_ly() {
  echo "Removing Ly. Re-enable your previous display manager manually afterward."
  run sudo systemctl disable ly.service 2>/dev/null || true
  run sudo systemctl enable getty@tty2.service 2>/dev/null || true
  run sudo rm -f /usr/bin/ly /usr/lib/systemd/system/ly.service \
                 /etc/systemd/system/ly.service "$STAMP"
  run sudo rm -rf /etc/ly
  echo "Ly removed. Enable a DM (e.g. 'sudo systemctl enable sddm') before reboot."
}

case $mode in
  uninstall) uninstall_ly; exit 0 ;;
  reinstall) build_install ;;
  install)
    if [[ -f $STAMP ]] && [[ "$(cat "$STAMP" 2>/dev/null)" == "$LY_VERSION" ]]; then
      echo "Ly v${LY_VERSION} already installed (--reinstall to rebuild)."
    else
      build_install
    fi ;;
esac

maybe_make_default
