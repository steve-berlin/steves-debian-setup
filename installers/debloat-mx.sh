#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh debloat-mx.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# debloat-mx.sh — strip an MX Linux install of bundled apps.
# See CLAUDE.md "installers/" → "debloat-mx.sh" for the removal-group rationale.
# For nvidia/nouveau purge use the sibling `debloat-nvidia.sh`.

set -euo pipefail

dry=0
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    -h|--help) echo "Usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

for c in apt apt-cache dpkg-query sudo awk; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

# /etc/mx-version is the canonical MX marker; survives a desktop switch.
[[ -f /etc/mx-version ]] || { echo "error: not MX Linux (no /etc/mx-version)" >&2; exit 1; }

# `|| true` is load-bearing: dpkg-query exits 1 on a never-seen package, and
# with pipefail the awk pipe fails too — set -e would silently kill the loop.
expand_installed() {
  local pat
  for pat in "$@"; do
    dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' "$pat" 2>/dev/null \
      | awk '$1 == "installed" {print $2}' || true
  done
  return 0
}

# Removal groups. Opt-ins (commented) at the bottom.
to_remove=(
  # 1. one-time welcome/tour
  mx-welcome mx-tour
  # 2. MX misc bloat: updater, GUI pkg installer, mx-viewer "MX browser",
  #    dead Flash installer, one-shot codec installer.
  mx-updater 'mx-packageinstaller*' mx-viewer mx-flash mx-codecs
  # 3. settings GUIs that duplicate XFCE Settings panels
  mx-keyboard mx-locale mx-date-time mx-user mx-menu-editor 'mx-system-keyboard*'
  # 4. niche network/sharing helpers
  mx-rsync mx-samba-config mx-find-shares mx-network-assistant mx-service-manager
  # 5. theme/sound packs + quick-info
  mx-artwork mx-faenza-icons mx-select-sound mx-system-sounds mx-quick-system-info
  # 6. mx-comp-mgr — irrelevant once you switch to KDE (KWin handles compositing)
  mx-comp-mgr
  # 7. bundled heavyweights from the old utils.sh step 14
  gimp strawberry gmtp deb-installer qpdfview catfish lo-main-helper
  # 8. CD/DVD burning/ripping — dead tech on modern hardware
  xfburn asunder brasero 'brasero-*' k3b 'k3b-*' 'libk3b*' xcdroast gnomebaker mybashburn
  # 9. wildcards
  'libreoffice-*' vlc 'vlc-*' 'gimp*'
  # Opt-in (uncomment any you want gone):
  # mx-conky          # only if you don't run Conky
  # mxlive-usb-maker  # mx-iso-dump covers the same use
  # mx-remastercc     # only useful when remastering the ISO
  # mx-installer      # only useful for an OS reinstall
)

mapfile -t present < <(expand_installed "${to_remove[@]}")
if (( ${#present[@]} == 0 )); then
  echo "── nothing to remove (already debloated) ──"
else
  printf '── removing %d packages ──\n' "${#present[@]}"
  run sudo apt purge --autoremove -y "${present[@]}"
fi

echo "── autoremove --purge ──"
run sudo apt autoremove --purge -y

cat <<'EOF'

── done ──
To bring something back:  sudo apt install <pkg>
For nvidia + nouveau purge: run ./debloat-nvidia.sh
EOF
