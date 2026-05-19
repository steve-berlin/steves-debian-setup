#!/usr/bin/env bash
# debloat-mx.sh — strip an MX Linux install of bundled apps you don't want.
#
# Parallel to debloat-kde.sh. Idempotent, --dry-run-able, hard-fails on
# non-MX systems. Removes MX-specific bloat (one-time welcome screens,
# the MX updater + GUI package installer, MX settings GUIs that
# duplicate XFCE Settings, MX network/Samba helpers, MX theme/sound
# packs, mx-comp-mgr, mx-viewer "MX browser", mx-flash, mx-codecs)
# plus bundled heavyweights (gimp, vlc, libreoffice, strawberry, etc.)
# and all CD/DVD burning/ripping apps.
#
# Mx-* tools the script DOES NOT touch (still useful): mx-tools,
# mx-snapshot, mx-cleanup, mx-tweak, mx-repo-manager, mx-iso-dump,
# mx-software-defaults, mx-default-settings, mx-keyring.
#
# Mx-* tools NOT removed by default (uncomment in the `optional` array
# to include): mx-conky, mxlive-usb-maker, mx-remastercc, mx-installer.
#
# Modes:
#   (no flag)      Run the debloat with the default removal groups.
#   --dry-run      Print every apt command, mutate nothing.
#   --intel-only   ALSO purge nvidia-*/libnvidia-*/nouveau and blacklist
#                  the nouveau kernel module. Matches the old utils.sh
#                  step 14 behaviour for Intel-iGPU-only laptops.

set -euo pipefail

dry=0
intel_only=0
for a in "$@"; do
  case $a in
    --dry-run)    dry=1 ;;
    --intel-only) intel_only=1 ;;
    -h|--help)    sed -n '2,24p' "$0"; echo "Usage: $0 [--dry-run] [--intel-only]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# preflight
for c in apt apt-cache dpkg-query sudo awk; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

# Bail if this isn't MX. /etc/mx-version is the canonical MX marker;
# survives a desktop switch (MX-XFCE → MX-KDE etc.) because it's tied
# to the base, not the session.
if [[ ! -f /etc/mx-version ]]; then
  echo "error: /etc/mx-version not found — this script targets MX Linux." >&2
  echo "       Refusing to run on what looks like vanilla Debian or another distro." >&2
  exit 1
fi

# expand_installed PAT [PAT ...] — print each installed package matching
# the given dpkg-query selectors. Accepts shell globs ('foo-*') and
# literal names. The trailing `|| true` is load-bearing: dpkg-query
# exits 1 on a totally unknown package (one never installed on this
# box), and with pipefail the awk pipe also fails, which under set -e
# silently kills the loop after the first unknown selector. `|| true`
# lets every pattern run.
expand_installed() {
  local pat
  for pat in "$@"; do
    dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' "$pat" 2>/dev/null \
      | awk '$1 == "installed" {print $2}' || true
  done
  return 0
}

# --- removal groups -------------------------------------------------------

# 1. MX one-time welcome/tour — useful once on first boot, never after.
mx_onetime=( mx-welcome mx-tour )

# 2. MX misc bloat the user already nukes by hand: updater notifier,
#    GUI package installer (apt + Discover cover it), the mx-viewer
#    WebKit "MX browser" (firefox-esr stays), Flash installer (dead
#    tech), one-shot codec installer.
mx_misc=(
  mx-updater
  'mx-packageinstaller*'
  mx-viewer
  mx-flash
  mx-codecs
)

# 3. MX settings GUIs that duplicate XFCE Settings panels.
mx_settings=(
  mx-keyboard mx-locale mx-date-time mx-user mx-menu-editor
  'mx-system-keyboard*'
)

# 4. MX network/sharing/service helpers — niche, rarely opened.
mx_network=(
  mx-rsync mx-samba-config mx-find-shares
  mx-network-assistant mx-service-manager
)

# 5. MX theme/sound packs + quick-info.
mx_themes=(
  mx-artwork mx-faenza-icons
  mx-select-sound mx-system-sounds
  mx-quick-system-info
)

# 6. mx-comp-mgr (XFCE compositor switcher). Becomes irrelevant once
#    you switch to KDE (KWin handles compositing internally).
mx_compositor=( mx-comp-mgr )

# 7. Bundled heavyweights from the old utils.sh step 14 (the user does
#    want these gone). vlc and libreoffice are handled via wildcard
#    below to catch their plugin/locale subpackages too.
heavy=( gimp strawberry gmtp deb-installer qpdfview catfish lo-main-helper )

# 8. All CD/DVD apps (per user: "safe to delete"). Optical media is
#    dead on modern hardware; libdvd-pkg and friends are autoremove
#    fodder once these go.
optical=(
  xfburn asunder
  brasero 'brasero-*'
  k3b 'k3b-*' 'libk3b*'
  xcdroast gnomebaker mybashburn
)

# 9. Wildcards for app families that ship many subpackages.
wildcards=( 'libreoffice-*' vlc 'vlc-*' 'gimp*' )

# (Opt-in. Uncomment any you want gone.)
optional=(
  # mx-conky          # only if you don't run Conky
  # mxlive-usb-maker  # mx-iso-dump covers the same use
  # mx-remastercc     # only useful when remastering the ISO
  # mx-installer      # only useful for an OS reinstall
)

to_remove=(
  "${mx_onetime[@]}" "${mx_misc[@]}" "${mx_settings[@]}" "${mx_network[@]}"
  "${mx_themes[@]}" "${mx_compositor[@]}" "${heavy[@]}" "${optical[@]}"
  "${wildcards[@]}" "${optional[@]}"
)

mapfile -t present < <(expand_installed "${to_remove[@]}")

if (( ${#present[@]} == 0 )); then
  echo "── nothing to remove (already debloated) ──"
else
  printf '── removing %d packages ──\n' "${#present[@]}"
  run sudo apt purge --autoremove -y "${present[@]}"
fi

# --- --intel-only: nvidia + nouveau purge --------------------------------

if (( intel_only )); then
  echo "── --intel-only: purging nvidia + nouveau ──"
  mapfile -t gpu_present < <(expand_installed 'nvidia-*' 'libnvidia-*' xserver-xorg-video-nouveau)
  if (( ${#gpu_present[@]} )); then
    run sudo apt purge --autoremove -y "${gpu_present[@]}"
  else
    echo "skip: no nvidia/nouveau packages installed"
  fi

  # Blacklist nouveau so it doesn't load on boot. Idempotent: overwrite
  # is fine; the file's contents are fixed.
  echo "── blacklisting nouveau ──"
  if (( dry )); then
    printf 'DRY  write /etc/modprobe.d/blacklist-nouveau.conf\n'
    printf 'DRY  sudo update-initramfs -u\n'
  else
    sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    sudo update-initramfs -u
  fi
fi

# --- final sweep ----------------------------------------------------------

echo "── autoremove --purge ──"
run sudo apt autoremove --purge -y

cat <<'EOF'

── done ──
To bring something back:  sudo apt install <pkg>
EOF
