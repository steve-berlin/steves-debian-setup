#!/usr/bin/env bash
# install-ly.sh — build and install Ly, a login screen that is text instead of
# graphics, from upstream source.
#
# What a display manager is: the screen that asks for your username and
# password before the desktop appears is a display manager, or DM. It runs
# before you log in, lets you pick which desktop to start, and hands over to
# it. SDDM (KDE's) and LightDM are the usual graphical ones. Ly does the same
# job in plain text, in the terminal. It starts in a fraction of the time, uses
# almost no memory, and has famously little to go wrong.
#
# Why a build script: Ly is not in Debian's or MX's package lists. It is
# written in Zig, a young language whose compiler changes fast. So fast that
# Ly 1.0.x only builds with Zig 0.13; today's Zig would refuse. So the script
# pins both versions (like utils.sh pins Go and neovim), downloads that Zig and
# that Ly, builds, installs, and throws the compiler away.
#
# How to use it:
#   bash installers/install-ly.sh               build, install, ask about default
#   bash installers/install-ly.sh --dry-run     print the plan, change nothing
#   bash installers/install-ly.sh --reinstall   rebuild even if already there
#   bash installers/install-ly.sh --uninstall   remove it
#   bash installers/install-ly.sh --default     switch to Ly without asking
#   bash installers/install-ly.sh --no-default  install only, don't switch
# Afterwards, run the read-only health check: bash installers/check-ly.sh
#
# If logins crash shortly after the laptop wakes from sleep, that is a systemd
# bug, not Ly's: see fix-suspend-freeze.sh. An earlier fix that rewrote Ly's
# PAM config (/etc/pam.d/ly) was a misdiagnosis and got reverted.
#
# Exit codes:
#   0  installed, already installed, removed, or dry-run finished
#   1  preflight failure
#   2  unknown argument
#   A failed download, clone or build stops the script through `set -e`, with
#   that command's own exit code (not always 1).

# Re-exec under bash if run as `sh install-ly.sh`. `sh` is dash here, and dash
# does not understand the bash-only syntax below.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# -e: stop at the first failing command. -u: an unset variable is an error.
# -o pipefail: a pipe fails if any part of it fails, not only the last part.
set -euo pipefail

# The pinned pair known to work. Override either from the environment, e.g.
# `LY_VERSION=1.0.3 ZIG_VERSION=0.13.0 bash installers/install-ly.sh`.
# Ly 1.0.x needs Zig 0.13. v1.0.3 is the last release on GitHub; newer Ly moved
# to a different host and wants Zig 0.16.
LY_VERSION=${LY_VERSION:-1.0.3}
ZIG_VERSION=${ZIG_VERSION:-0.13.0}
LY_REPO=https://github.com/fairyglade/ly
# A small file recording which Ly version this script installed. Running again
# with that version already there does nothing. That also keeps an accidental
# re-run from flattening your /etc/ly/config.ini. --reinstall skips the check.
STAMP=/usr/local/share/ly.version   # idempotency marker; re-run = no-op

# dry=1 means "print, change nothing". mode is install, reinstall or uninstall.
# set_default: should Ly become the default DM? -1 = ask, 1 = yes, 0 = no.
dry=0; mode=install; set_default=-1   # -1 prompt, 1 yes, 0 no
# The temporary build folder. It lives at script level, not as a `local`: the
# EXIT trap runs after build_install returns, and under `set -u` a vanished
# local would crash it. On any exit (normal, error, Ctrl-C) the trap deletes
# the folder, Zig compiler and all.
tmp=""  # script-scoped so EXIT trap can rm it
trap 'rm -rf "${tmp:-}"' EXIT

# Read the flags. --default / --no-default answer the "make Ly the default?"
# question up front, so there is no prompt. --dry-run combines with any mode.
# Anything else is exit 2.
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

# run CMD...: in dry-run, print "DRY  CMD"; otherwise really run CMD.
run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# write_stamp: write LY_VERSION into STAMP. STAMP is in a root-owned folder,
# so it pipes through `sudo tee`. In dry-run it only prints.
write_stamp() {
  if (( dry )); then printf 'DRY  write %s = %s\n' "$STAMP" "$LY_VERSION"
  else echo "$LY_VERSION" | sudo tee "$STAMP" >/dev/null; fi
}

# current_dm: print the unit name of the DM that is wired up now, e.g.
# "sddm.service". display-manager.service is a symlink to the real DM's unit;
# readlink -f follows it and basename keeps the file name. Prints nothing if
# there is no such link.
current_dm() { basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" 2>/dev/null; }

# preflight (step 1): check everything the build needs before touching
# anything. Needs git, curl, tar, sudo, systemctl, two dev packages, and a
# known CPU type. A miss stops the script (exit 1).
# Under --dry-run every miss is only a "warning:" (the local `miss` helper
# decides). A dry-run promises to print its plan, and the box you would
# dry-run on is exactly the one without the build tools yet.
preflight() {
  local miss; miss() { (( dry )) && echo "warning: $1" >&2 || { echo "$1" >&2; exit 1; }; }
  for c in git curl tar sudo systemctl; do
    command -v "$c" >/dev/null || miss "missing: $c (apt install $c)"
  done
  # Zig links Ly against the system's password-checking library (PAM) and
  # keyboard library (XCB xkb). The build needs their dev headers.
  for p in libpam0g-dev libxcb-xkb-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || miss "missing: $p — sudo apt install $p"
  done
  # We only know Zig's download name for x86_64 and aarch64; refuse others.
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) miss "unsupported arch $(uname -m) — Zig tarball name only mapped for x86_64/aarch64" ;;
  esac
}

build_install() {
  preflight
  tmp=$(mktemp -d)

  # Step 2: fetch the pinned Zig compiler (Debian has no usable version) into
  # the temporary folder and unpack it. The URL uses Zig 0.13's file naming,
  # zig-linux-<arch>-<version>.tar.xz. In dry-run nothing is unpacked, so the
  # path to the compiler is just the placeholder "<zig>".
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

  # Step 3: clone Ly at the pinned tag, with its two sub-projects (git
  # submodules) zigini and clap. --depth 1 fetches only that one commit.
  echo "Cloning Ly v${LY_VERSION}"
  run git clone --depth 1 --branch "v${LY_VERSION}" --recurse-submodules --shallow-submodules \
      "$LY_REPO" "$tmp/ly"

  # Step 4: build twice, on purpose. First as you, then again as root.
  # The reason is order. Compile errors should show up before root touches
  # anything. The install step writes to absolute system paths (no DESTDIR),
  # so it needs root.
  # v1.0.3 has no -Dinit_system flag. `installexe` writes /usr/bin/ly and the
  # /etc/ly/ config folder. `installsystemd` depends on installexe and also
  # adds /usr/lib/systemd/system/ly.service, the entry that lets systemd start
  # Ly. So `installsystemd` does all the installing.
  # Side effect: the root build leaves root-owned files in $tmp/.zig-cache.
  # chown hands the folder back to you, or the EXIT trap (running as you)
  # could not delete it.
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

# make_default: turn off the DM that is wired now (unless it is Ly already),
# turn off the text login on tty2 (getty@tty2; Ly wants that console for
# itself), and enable ly.service. Takes effect after a reboot.
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

# maybe_make_default: after installing, OFFER to make Ly the default login
# screen. --default / --no-default decide without a prompt. Otherwise:
#   --dry-run          print that it would ask, ask nothing
#   stdin not a tty    (piped input, a script) assume no, and warn
#   interactive        ask: "Make Ly the default display manager (disables
#                      sddm)? [y/N]"; only y/Y... says yes
# The default is no. Silently swapping the thing that lets you log in is not
# something to do by accident.
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

# uninstall_ly: disable ly.service, put the tty2 text login back, and delete
# Ly's files: /usr/bin/ly, both ly.service copies, the stamp, and the whole
# /etc/ly folder (your config.ini goes too).
# It does NOT re-enable your old graphical DM, and says so. That is on purpose:
# guessing which DM you had and silently re-wiring it is a good way to boot to
# a black screen. Enable the one you want yourself, BEFORE rebooting. If you
# forget, log in on a text console (Ctrl+Alt+F2) and fix it there.
uninstall_ly() {
  echo "Removing Ly. Re-enable your previous display manager manually afterward."
  run sudo systemctl disable ly.service 2>/dev/null || true
  run sudo systemctl enable getty@tty2.service 2>/dev/null || true
  run sudo rm -f /usr/bin/ly /usr/lib/systemd/system/ly.service \
                 /etc/systemd/system/ly.service "$STAMP"
  run sudo rm -rf /etc/ly
  echo "Ly removed. Enable a DM (e.g. 'sudo systemctl enable sddm') before reboot."
}

# Main. Uninstall stops here (exit 0, no default-DM question). Reinstall always
# builds. Plain install builds only if STAMP is missing or holds another
# version. Then, for install and reinstall, offer the default-DM switch.
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
