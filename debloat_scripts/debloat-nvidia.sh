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

set -euo pipefail

# lspci lives in /usr/sbin on Debian; interactive bash for non-root users
# doesn't always have sbin dirs on PATH.
PATH=$PATH:/usr/sbin:/sbin

BLACKLIST=/etc/modprobe.d/blacklist-nouveau.conf

mode=install; dry=0
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --dry-run)   dry=1 ;;
    -h|--help)   sed -n '6,10p' "$0"; echo "Usage: $0 [--uninstall] [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
have(){ command -v "$1" >/dev/null; }

for c in apt dpkg-query sudo awk lspci; do
  have "$c" || { echo "missing: $c" >&2; exit 1; }
done

# Hard-fail if a real NVIDIA GPU is present — purging drivers on a box
# that actually has one would drop X to llvmpipe (or hang at boot).
# Class 03xx covers VGA + 3D + display controllers.
if lspci -nn -d ::0300 -d ::0302 -d ::0380 | grep -qi nvidia; then
  echo "error: NVIDIA GPU detected by lspci — refusing to purge drivers." >&2
  echo "       This script is for Intel-iGPU-only boxes." >&2
  exit 1
fi

# Same expand_installed pattern as debloat-mx.sh / debloat-kde.sh:
# accepts globs + literals, filters down to currently-installed only,
# so re-runs are no-ops.
expand_installed() {
  local pat
  for pat in "$@"; do
    dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' "$pat" 2>/dev/null \
      | awk '$1 == "installed" {print $2}' || true
  done
  return 0
}

if [[ $mode == uninstall ]]; then
  run sudo rm -f "$BLACKLIST"
  have update-initramfs && run sudo update-initramfs -u
  echo "removed nouveau blacklist. Drivers themselves untouched — reinstall with apt as needed."
  exit 0
fi

mapfile -t present < <(expand_installed 'nvidia-*' 'libnvidia-*' xserver-xorg-video-nouveau)

if (( ${#present[@]} )); then
  printf '── purging %d gpu packages ──\n' "${#present[@]}"
  run sudo apt purge --autoremove -y "${present[@]}"
else
  echo "skip: no nvidia/nouveau packages installed"
fi

# Blacklist nouveau so it doesn't load on boot. Overwriting is safe —
# contents are fixed; idempotent on re-run.
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
