#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh debloat-nvidia.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# debloat-nvidia.sh — purge nvidia + nouveau on Intel-iGPU-only boxes.
# Target: ThinkPad T480 (Intel UHD 620) and similar laptops without a
# discrete NVIDIA card. Saves ~500 MB and frees the iGPU from sharing
# DRM contention with an unused nouveau probe at boot.
# Idempotent; --dry-run-able; --uninstall removes the blacklist only.
#
# KEEP LINES 6-10 ABOVE WHERE THEY ARE: --help prints them with
# `sed -n '6,10p'`. Add new header text below this point only.
#
# Why a computer has drivers it can't use: installers play it safe and add
# drivers for hardware you *might* have. So a laptop with only Intel
# graphics (built into the processor, the "iGPU") still gets the NVIDIA
# driver stack, plus nouveau, the open-source driver for NVIDIA cards.
# That costs about 500 MB of disk, and a little time at every boot: nouveau
# loads and looks for a card that isn't there before giving up.
#
# How to use it:
#   bash debloat_scripts/debloat-nvidia.sh --dry-run
#   bash debloat_scripts/debloat-nvidia.sh
#   bash debloat_scripts/debloat-nvidia.sh --uninstall
# Reboot afterwards.
#
# Checking it afterwards: check-setup.sh tests exactly this. No nvidia-*
# packages, the blacklist file present, no nvidia or nouveau module loaded,
# and (if glxinfo is installed) that the Intel chip really draws the screen.
# A module still loaded right after this script is the pending reboot, not
# a failure.
#
# Exit codes:
#   0  purged, nothing to purge, reverted, or dry-run finished
#   1  an NVIDIA GPU is present (install mode only), or a required tool
#      is missing
#   2  unknown argument
#   A failing apt/sudo command also stops the script (set -e below), with
#   that command's own exit code.

# set -e: stop at the first command that fails.
# set -u: treat a typo'd (unset) variable name as an error.
# set -o pipefail: a pipe fails if any command in it fails, not just the last.
set -euo pipefail

# lspci lives in /usr/sbin on Debian; interactive bash for non-root users
# doesn't always have sbin dirs on PATH.
PATH=$PATH:/usr/sbin:/sbin

# BLACKLIST: the file that tells Linux never to load nouveau. See the
# blacklist step at the bottom for what goes in it.
BLACKLIST=/etc/modprobe.d/blacklist-nouveau.conf

# mode=install (default) purges + blacklists. --uninstall sets
# mode=uninstall: remove the blacklist only.
# dry=1 means --dry-run: print what would happen, change nothing.
# Any other argument is an error (exit 2).
mode=install; dry=0
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --dry-run)   dry=1 ;;
    -h|--help)   sed -n '6,10p' "$0"; echo "Usage: $0 [--uninstall] [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

# run CMD...: in dry-run, print "DRY  CMD" instead of running it.
# Otherwise run CMD as given.
run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
# have CMD: true if CMD is on PATH.
have(){ command -v "$1" >/dev/null; }

# Preflight: every tool the script needs must exist, or stop with exit 1.
for c in apt dpkg-query sudo awk lspci; do
  have "$c" || { echo "missing: $c" >&2; exit 1; }
done

# Hard-fail if a real NVIDIA GPU is present — purging drivers on a box
# that actually has one would drop X to llvmpipe (or hang at boot).
# llvmpipe is software rendering: the processor draws everything, slowly.
# Before touching anything, ask the hardware itself (lspci) which graphics
# devices exist. Class 03xx covers VGA + 3D + display controllers:
#   ::0300  the main display adapter (VGA)
#   ::0302  secondary 3D controllers
#   ::0380  other display controllers
# If any of them says NVIDIA, stop with exit 1. Only the install mode is
# guarded: --uninstall just deletes the blacklist, which is exactly what you
# want on a box that turns out to have an NVIDIA card. There is deliberately
# NO flag to override the install guard. If you truly want that, use apt
# directly and know what you're doing.
if [[ $mode == install ]] && lspci -nn -d ::0300 -d ::0302 -d ::0380 | grep -qi nvidia; then
  echo "error: NVIDIA GPU detected by lspci — refusing to purge drivers." >&2
  echo "       This script is for Intel-iGPU-only boxes." >&2
  exit 1
fi

# Same expand_installed as debloat-mx/kde: globs + literals → installed-only,
# so re-runs are no-ops. dpkg-query lists each match with its status; awk
# keeps only "installed". `|| true`: dpkg-query exits 1 on a never-seen
# pattern, and under pipefail + set -e that would kill the loop.
expand_installed() {
  local pat
  for pat in "$@"; do
    dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' "$pat" 2>/dev/null \
      | awk '$1 == "installed" {print $2}' || true
  done
  return 0
}

# --uninstall: delete the blacklist file and rebuild the initramfs (if
# update-initramfs exists), so nouveau may load again. It does NOT
# reinstall any driver package; do that yourself, e.g.
#   sudo apt install xserver-xorg-video-nouveau
# The split is on purpose. Undoing a config change is safe and
# predictable. Reinstalling a driver stack is a choice you should make
# yourself.
if [[ $mode == uninstall ]]; then
  run sudo rm -f "$BLACKLIST"
  have update-initramfs && run sudo update-initramfs -u
  echo "removed nouveau blacklist. Drivers themselves untouched — reinstall with apt as needed."
  exit 0
fi

# Step 1: purge the packages. present: every installed package named
# nvidia-* or libnvidia-*, plus xserver-xorg-video-nouveau. A second run
# finds nothing and says "skip" instead of erroring.
mapfile -t present < <(expand_installed 'nvidia-*' 'libnvidia-*' xserver-xorg-video-nouveau)

if (( ${#present[@]} )); then
  printf '── purging %d gpu packages ──\n' "${#present[@]}"
  run sudo apt purge --autoremove -y "${present[@]}"
else
  echo "skip: no nvidia/nouveau packages installed"
fi

# Step 2: blacklist nouveau so it doesn't load on boot. Removing the
# package isn't enough: nouveau is also built into the kernel's own driver
# collection. The file gets two lines, because they block two routes:
#   blacklist nouveau          don't load the driver by name
#   options nouveau modeset=0  don't let it set up the screen early in boot
# Overwriting is safe — contents are fixed; idempotent on re-run.
#
# Step 3: rebuild the initramfs (update-initramfs -u). The initramfs is a
# small system the kernel unpacks first, before your real disk is ready.
# It carries its OWN copy of the driver rules. Skip this and nouveau still
# loads in early boot from the old copy.
#
# Nothing here unloads a driver from the running kernel. It all takes
# effect on the next boot.
echo "── blacklisting nouveau ──"
if (( dry )); then
  printf 'DRY  write %s\n' "$BLACKLIST"
  printf 'DRY  sudo update-initramfs -u\n'
else
  sudo tee "$BLACKLIST" >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
  sudo update-initramfs -u
fi

echo "done. Reboot for the blacklist to take effect."
