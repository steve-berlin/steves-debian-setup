#!/usr/bin/env bash
# install-lineage.sh — install QEMU/KVM, fetch an Android-x86 ISO, and
# create an 8 GB qcow2 disk for the Roblox-only "LineageOS" VM that
# `lng` (~/.local/bin/lng) launches.
#
# Why Android-x86, not literal LineageOS: LineageOS ships no official
# x86_64 image. Android-x86 is the upstream that every desktop fork
# (Bliss OS, LineageOS-x86) tracks; 9.0-r2 is its newest stable release.
# Override with LINEAGE_ISO_URL=<https://...iso> to swap in a fork build
# (Bliss OS images go in this slot when their lockdown lifts).
set -euo pipefail

VM_DIR="${LINEAGE_VM_DIR:-$HOME/lineage_vm}"
DISK="$VM_DIR/disk.qcow2"
DISK_SIZE=8G
ISO="$VM_DIR/android-x86.iso"
ISO_URL=${LINEAGE_ISO_URL:-https://sourceforge.net/projects/android-x86/files/Release%209.0/android-x86_64-9.0-r2.iso/download}
# qemu-system-gui ships the GTK display, virgl renderer (for virtio-vga-gl),
# and PulseAudio/PipeWire backends. Without it the launcher's `-display gtk`
# and `-audiodev pa` fail with "Unknown driver" — silently for audio.
# adb is used by lng's optional Roblox autostart over the hostfwd'd port
# 5555. lng degrades gracefully if it's missing, but installing it here
# saves the user a second apt round-trip.
PKGS=(qemu-system-x86 qemu-system-gui qemu-utils ovmf adb)

DRY=0
MODE=install   # install | uninstall | reinstall

usage() {
  cat <<EOF
Usage: $(basename "$0") [--reinstall|--uninstall] [--dry-run]

  (no flag)     Install QEMU+KVM, fetch ISO, create $DISK_SIZE qcow2 disk.
                Launcher tuning: 4 vCPU, 4096 MB RAM (set in ~/.local/bin/lng).
  --reinstall   Remove VM disk + ISO, then install fresh.
  --uninstall   Remove VM disk + ISO. QEMU packages are kept.
  --dry-run     Print every action without changing the system. Combinable.

Env overrides:
  LINEAGE_ISO_URL  Use a different ISO (e.g. a Bliss OS or LineageOS-x86 build).
  LINEAGE_VM_DIR   Install to a non-default directory (default: \$HOME/lineage_vm).
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

run()  { if (( DRY )); then printf 'DRY-RUN: %s\n' "$*"; else "$@"; fi; }
need() { command -v "$1" >/dev/null 2>&1 \
         || { echo "Missing dependency: $1" >&2; exit 1; }; }

preflight() {
  for c in curl sudo apt-get stat; do need "$c"; done
  [[ -e /dev/kvm ]] \
    || { echo "/dev/kvm missing — enable VT-x/AMD-V in BIOS" >&2; exit 1; }
}

install_pkgs() {
  # Skip the apt round-trip (and the sudo password prompt it triggers) if
  # every required package is already installed. Only install the gaps.
  local missing=() p
  for p in "${PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null \
      | grep -q 'install ok installed' || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    echo "QEMU/KVM packages already installed — skipping apt."
    return
  fi
  echo "Installing missing QEMU/KVM packages: ${missing[*]}"
  run sudo apt-get update
  run sudo apt-get install -y "${missing[@]}"
}

fetch_iso() {
  if [[ -s $ISO ]]; then
    echo "ISO already at $ISO — skipping download."
    return
  fi
  echo "Downloading Android-x86 ISO → $ISO  (~700 MB, follows SF mirror redirect)"
  run curl -fL --retry 3 -o "$ISO" "$ISO_URL"
}

make_disk() {
  if [[ -s $DISK ]]; then
    echo "Disk already at $DISK — skipping create."
    return
  fi
  echo "Creating $DISK_SIZE qcow2 disk → $DISK  (sparse, ~200 KB on disk until used)"
  run qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
}

uninstall() {
  echo "Removing VM data ($DISK, $ISO) — QEMU packages kept."
  run rm -f "$DISK" "$ISO"
}

install() {
  preflight
  run mkdir -p "$VM_DIR"
  install_pkgs
  # qemu-img is provided by qemu-utils; check now that packages are in.
  (( DRY )) || need qemu-img
  fetch_iso
  make_disk
  cat <<EOF

Done. Next steps:
  1. Run \`lng\` to boot the VM (ISO + blank disk).
  2. In the VM's GRUB menu pick 'Installation' (not the default 'Live').
  3. Install Android-x86 to the virtio disk (sda) — see
     ~/steves_debian_setup/lineage_vm/CLAUDE.md for the partition /
     GRUB / ext4 prompts.
  4. After install, power off. \`lng\` boots from disk on subsequent runs.
  5. Sideload the Roblox APK (Play Store is not bundled with Android-x86).
EOF
}

case "$MODE" in
  install)   install ;;
  uninstall) uninstall ;;
  reinstall) uninstall; install ;;
esac
