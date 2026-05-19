#!/usr/bin/env bash
# debloat-kde.sh — strip Debian/MX KDE Plasma down to a working desktop.
#
# Adapted from https://github.com/cl0v3r404/Debloat-KDE-Plasma-Debian
# (original by cl0v3r404, in Spanish). This version is English (US),
# idempotent, dry-run-able, and extended for a more thorough debloat
# (KDE games, edutainment, more legacy/duplicate utilities, kdepim).
#
# What it does:
#   - Holds kdeaccessibility so apt autoremove doesn't pull it out as a
#     side-effect of removing other kde-* packages.
#   - apt remove --purge of: legacy KDE apps, non-Latin/CJK input
#     methods, KDE games, KDE edutainment, duplicate/legacy utilities.
#   - Installs plasma-discover-backend-flatpak + kde-config-flatpak so
#     Discover can install Flatpaks; kde-config-plymouth for the
#     boot-splash GUI module.
#   - apt autoremove --purge to sweep the deps.
#
# Modes:
#   (no flag)   Run the debloat.
#   --dry-run   Print every apt command, mutate nothing.

set -euo pipefail

dry=0
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,22p' "$0"; echo "Usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# preflight
for c in apt apt-mark apt-cache dpkg-query sudo; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

# Bail if Plasma isn't installed — script is a no-op + footgun otherwise.
# (kde-plasma-desktop is just a metapackage; plasma-desktop is the real one.)
if ! dpkg-query -W -f='${db:Status-Status}\n' plasma-desktop 2>/dev/null \
     | grep -q '^installed$'; then
  echo "error: plasma-desktop is not installed — this script targets a" >&2
  echo "       running KDE Plasma desktop. Install KDE first, e.g.:" >&2
  echo "         sudo apt install kde-plasma-desktop" >&2
  exit 1
fi

# Filter a package list to those actually installed, so re-runs on a
# half-debloated box don't make apt bail with "package not installed".
installed_only() {
  local p
  for p in "$@"; do
    dpkg-query -W -f='${db:Status-Status}\n' "$p" 2>/dev/null \
      | grep -qx 'installed' && printf '%s\n' "$p"
  done
  return 0
}

# Same idea for apt-install: skip packages that aren't in any enabled
# repo (apt-cache show returns nonzero), avoiding hard fails on slimmer
# MX repos vs vanilla Debian.
available_only() {
  local p
  for p in "$@"; do
    apt-cache show "$p" >/dev/null 2>&1 && printf '%s\n' "$p"
  done
  return 0
}

# --- hold accessibility ---------------------------------------------------
echo "── hold kdeaccessibility ──"
if apt-cache show kdeaccessibility >/dev/null 2>&1; then
  run sudo apt-mark hold kdeaccessibility
else
  echo "skip: kdeaccessibility not in any enabled repo"
fi

# --- removals -------------------------------------------------------------

# 1. Legacy/redundant KDE apps from the upstream debloat list.
legacy=(
  konqueror konq-plugins
  akregator kmail kaddressbook korganizer kontact kleopatra kgpg
  kdepim-runtime
  kwrite xterm
  dragonplayer juk elisa
  goldendict-ng
  debian-reference-common khelpcenter
)

# 2. Image editing: GIMP is pulled in by some KDE task selections; drop
#    it here, reinstall on demand if you want it back.
images=( gimp )

# 3. Non-Latin / CJK input stacks (fcitx, fcitx5, mozc, anthy, ibus,
#    Thai terminal). Drop the lot if you don't use them — keeps the
#    input-method menu out of every Qt app's tray.
input=(
  fcitx fcitx-bin fcitx-config-common fcitx-data fcitx-frontend-all
  fcitx-module-quickphrase-editor fcitx-modules
  fcitx5 fcitx5-config-qt fcitx5-data fcitx5-modules
  mozc-data mozc-server mozc-utils-gui
  uim-mozc
  anthy anthy-common
  ibus ibus-data
  xiterm+thai
)

# 4. KDE games — pulled in by kde-standard / kdegames. Remove the meta
#    too so autoremove doesn't reinstall them next time.
games=(
  kdegames
  blinken bomber bovo granatier kajongg kanagram kapman katomic
  kbattleship kblackbox kblocks kbounce kbreakout kdiamond
  kfourinline kgoldrunner kigo killbots kiriki kjumpingcube klickety
  klines kmahjongg kmines knavalbattle knetwalk knights kollision
  kpat kreversi kshisen ksirk ksnakeduel kspaceduel ksquares
  ksudoku ktuberling kubrick lskat palapeli picmi
)

# 5. KDE edutainment — same story, pulled in by kde-standard.
edu=(
  kde-edu
  cantor kalzium kbruch kgeography khangman kig kiten klettres
  kmplot kstars ktouch kturtle kwordquiz marble minuet parley rocs step
)

# 6. Legacy/duplicate KDE utilities. Each one has a better alt: kfind
#    (Dolphin search), kompare (git diff / IDE), kget (curl/wget),
#    sweeper (Discover/cleanup CLI), k3b (rare CD burning), kjots/knotes
#    (any modern notes app), kcharselect/kruler/kcolorchooser (niche).
utils=(
  kcharselect kcolorchooser kfind kget kjots kompare knotes kruler
  ktimer sweeper k3b kbackup kolourpaint
)

to_remove=( "${legacy[@]}" "${images[@]}" "${input[@]}" \
            "${games[@]}" "${edu[@]}" "${utils[@]}" )
mapfile -t present < <(installed_only "${to_remove[@]}")

if (( ${#present[@]} == 0 )); then
  echo "── nothing to remove (already debloated) ──"
else
  printf '── removing %d packages ──\n' "${#present[@]}"
  run sudo apt remove --purge -y "${present[@]}"
fi

# --- additions ------------------------------------------------------------

echo "── installing extras (flatpak backend + plymouth GUI) ──"
extras=( plasma-discover-backend-flatpak kde-config-flatpak kde-config-plymouth )
mapfile -t extras_ok < <(available_only "${extras[@]}")
if (( ${#extras_ok[@]} )); then
  run sudo apt install -y "${extras_ok[@]}"
else
  echo "skip: none of the extras are in any enabled repo"
fi

# --- cleanup --------------------------------------------------------------

echo "── autoremove --purge ──"
run sudo apt autoremove --purge -y

cat <<'EOF'

── done ──
Reboot recommended (some KDE PIM services linger until session restart).
To bring something back:  sudo apt install <pkg>
EOF
