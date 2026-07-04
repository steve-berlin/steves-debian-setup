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
# It also overwrites Ly's upstream /etc/pam.d/ly (four `include login` lines)
# with a Debian/MX-appropriate PAM stack modeled on Debian's own sddm file.
# Upstream's `include login` pulls getty-oriented modules and, critically, does
# not reliably run pam_systemd in Ly's session — so logind never creates
# /run/user/<uid>, XDG_RUNTIME_DIR stays root's /run/user/0, and Wayland
# sessions die with "Can't open Wayland socket" / "Unable to open lockfile"
# while auth quirks surface as "Can't authenticate user". The replacement
# stack always reaches common-session (→ pam_systemd → XDG_RUNTIME_DIR).
#
# Override pins: LY_VERSION=1.0.3 ZIG_VERSION=0.13.0 (Ly 1.0.x needs Zig 0.13;
# v1.0.3 is the last GitHub release, newer Ly moved hosts + wants Zig 0.16).
set -euo pipefail

LY_VERSION=${LY_VERSION:-1.0.3}
ZIG_VERSION=${ZIG_VERSION:-0.13.0}
LY_REPO=https://github.com/fairyglade/ly
STAMP=/usr/local/share/ly.version   # idempotency marker; re-run = no-op
PAM_FILE=/etc/pam.d/ly              # rewritten with a Debian-appropriate stack

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
  # pam_systemd (from libpam-systemd) is what creates /run/user/<uid> and sets
  # XDG_RUNTIME_DIR at login. Ly's whole Wayland-socket/lockfile failure mode
  # hinges on it running in the session; normally the desktop pulls it, but
  # check explicitly since the corrected PAM stack is useless without it.
  dpkg -s libpam-systemd >/dev/null 2>&1 || \
    miss "missing: libpam-systemd — sudo apt install libpam-systemd (XDG_RUNTIME_DIR / Wayland)"
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

# Overwrite Ly's upstream /etc/pam.d/ly with a Debian/MX-appropriate stack.
# Runs on every install/reinstall (idempotent — same bytes each time), so it
# also repairs boxes where an older run left the upstream `include login` file
# in place even when the build step is skipped by the version stamp.
install_pam() {
  echo "Writing Debian-appropriate PAM stack: $PAM_FILE"
  if (( dry )); then
    printf 'DRY  write %s (clean auth via common-auth + pam_systemd session)\n' "$PAM_FILE"
    return
  fi
  # Mirrors Debian's own display-manager PAM (sddm): clean auth through
  # common-auth, and a session that always reaches common-session so
  # pam_systemd runs and XDG_RUNTIME_DIR (/run/user/<uid>) is set up. The
  # keyring/kwallet lines are '-'-prefixed: skipped silently if the module
  # isn't installed. pam_succeed_if blocks root GUI login, per DM convention.
  sudo tee "$PAM_FILE" >/dev/null <<'EOF'
#%PAM-1.0
# Ly display manager — Debian/MX PAM stack (installed by install-ly.sh).
#
# Replaces Ly upstream's default (four `include login` lines). On Debian,
# /etc/pam.d/login is getty-oriented and does not reliably run pam_systemd in
# Ly's session; without it logind never creates /run/user/<uid> and
# XDG_RUNTIME_DIR stays root's /run/user/0, so Wayland sessions fail with
# "Can't open Wayland socket" / "Unable to open lockfile" and auth quirks show
# up as "Can't authenticate user". Modeled on Debian's vetted sddm PAM.
auth       requisite    pam_nologin.so
auth       required     pam_succeed_if.so user != root quiet_success
@include common-auth
-auth      optional     pam_gnome_keyring.so
-auth      optional     pam_kwallet5.so

@include common-account

session    required     pam_limits.so
session    required     pam_loginuid.so
@include common-session
-session   optional     pam_gnome_keyring.so auto_start
-session   optional     pam_kwallet5.so auto_start
session    required     pam_env.so readenv=1
session    required     pam_env.so readenv=1 envfile=/etc/default/locale

@include common-password
EOF
  sudo chmod 0644 "$PAM_FILE"
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
                 /etc/systemd/system/ly.service "$PAM_FILE" "$STAMP"
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

# Always (re)assert the corrected PAM stack — cheap, idempotent, and repairs an
# already-installed box whose build step was skipped by the version stamp.
install_pam

maybe_make_default
