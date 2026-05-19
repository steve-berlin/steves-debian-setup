#!/usr/bin/env bash
# debloat-xfce.sh — strip XFCE from a Debian/MX box. Use this AFTER
# switching to a different DE (KDE/LXQt/GNOME); running it from inside
# XFCE will kill your live session.
#
# Parallel to debloat-mx.sh and debloat-kde.sh. Idempotent, dry-run-able,
# hard-fails if XFCE is the active session or if XFCE isn't installed.
#
# What it removes (every group filtered through `expand_installed` so
# re-runs are no-ops):
#   - xfce4 meta + task-xfce-desktop                  (Debian task pkg)
#   - core session/wm/panel: xfwm4, xfdesktop4, xfconf, xfce4-session,
#     xfce4-settings, xfce4-panel, xfce4-notifyd, xfce4-appfinder,
#     xfce4-power-manager
#   - 'xfce4-*' wildcard for all XFCE panel plugins + goodies
#   - 'libxfce4*' libraries
#   - file manager: thunar + 'thunar-*' plugins
#   - bundled apps: mousepad (editor), ristretto (image viewer),
#     parole (media player), orage (calendar), xfce4-terminal,
#     xfce4-screenshooter, xfce4-taskmanager
#   - xubuntu artwork if installed
#
# Modes:
#   (no flag)   Run the debloat.
#   --dry-run   Print every apt command, mutate nothing.

set -euo pipefail

dry=0
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,25p' "$0"; echo "Usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# preflight
for c in apt apt-cache dpkg-query sudo awk; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

# Must NOT be running XFCE — removing it mid-session kills the desktop.
# $XDG_CURRENT_DESKTOP is set by every modern session manager; on XFCE
# it's "XFCE". Match case-insensitively to be safe against future renames.
desk="${XDG_CURRENT_DESKTOP:-}"
shopt -s nocasematch
if [[ "$desk" == *xfce* ]]; then
  shopt -u nocasematch
  echo "error: XFCE is the active session (\$XDG_CURRENT_DESKTOP=$desk)." >&2
  echo "       Removing XFCE packages now will kill the live desktop." >&2
  echo "       Log into KDE/LXQt/GNOME and re-run from there." >&2
  exit 1
fi
shopt -u nocasematch

# XFCE must actually be installed (otherwise there's nothing to do, and
# a silent "0 packages" exit looks like the script broke).
if ! dpkg-query -W -f='${db:Status-Status}\n' xfwm4 2>/dev/null | grep -q '^installed$'; then
  echo "error: xfwm4 is not installed — XFCE doesn't appear to be on this system." >&2
  exit 1
fi

# expand_installed PAT [PAT ...] — print each installed package matching
# the given dpkg-query selectors. Accepts shell globs and literal names.
# The trailing `|| true` is load-bearing: dpkg-query exits 1 on a totally
# unknown package (one never installed on this box), and with pipefail
# the awk pipe also exits nonzero, which under set -e silently kills the
# loop after the first unknown selector. `|| true` lets the loop
# continue across every pattern.
expand_installed() {
  local pat
  for pat in "$@"; do
    dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' "$pat" 2>/dev/null \
      | awk '$1 == "installed" {print $2}' || true
  done
  return 0
}

# --- removal groups -------------------------------------------------------

# 1. XFCE metas + the Debian task package. Removing these flags every
#    XFCE component as autoremove-eligible.
metas=( xfce4 task-xfce-desktop xfce4-goodies )

# 2. Core session / window manager / panel. Listed explicitly so the
#    purge stops on a hard error if any are unexpectedly held.
core=(
  xfwm4 xfdesktop4 xfconf
  xfce4-session xfce4-settings xfce4-panel xfce4-notifyd
  xfce4-appfinder xfce4-power-manager
)

# 3. Wildcards for the long tail of panel plugins, goodies, libraries.
#    These catch xfce4-clipman-plugin, xfce4-pulseaudio-plugin,
#    xfce4-whiskermenu-plugin, xfce4-statusnotifier-plugin, the genmon /
#    sensors / fsguard / netload / weather plugins, etc., plus the
#    libxfce4* runtime libs.
wildcards=(
  'xfce4-*'
  'libxfce4*'
  'thunar-*'
)

# 4. Bundled XFCE apps that don't match the xfce4-* prefix.
apps=(
  thunar
  mousepad ristretto parole orage
)

# 5. Xubuntu artwork (no-op on Debian/MX; covered just in case).
xubuntu=( 'xubuntu-*' )

to_remove=(
  "${metas[@]}" "${core[@]}" "${wildcards[@]}" "${apps[@]}" "${xubuntu[@]}"
)

mapfile -t present < <(expand_installed "${to_remove[@]}")

if (( ${#present[@]} == 0 )); then
  echo "── nothing to remove (already debloated) ──"
else
  printf '── removing %d XFCE packages ──\n' "${#present[@]}"
  run sudo apt purge --autoremove -y "${present[@]}"
fi

# --- final sweep ----------------------------------------------------------

echo "── autoremove --purge ──"
run sudo apt autoremove --purge -y

cat <<'EOF'

── done ──
XFCE is gone. To bring it back:  sudo apt install xfce4
EOF
