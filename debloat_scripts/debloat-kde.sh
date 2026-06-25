#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh debloat-kde.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# debloat-kde.sh — strip Debian/MX KDE Plasma down to a working desktop.
# See CLAUDE.md "installers/" → "debloat-kde.sh" for the full removal-group list
# and the rationale per group (Akonadi RDBMS lingering, language filter, Plasma
# config tweaks, etc.).
set -euo pipefail

dry=0; no_bluetooth=0
for a in "$@"; do
  case $a in
    --dry-run)      dry=1 ;;
    --no-bluetooth) no_bluetooth=1 ;;
    -h|--help)      echo "Usage: $0 [--dry-run] [--no-bluetooth]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

for c in apt apt-mark apt-cache dpkg-query sudo awk; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

# kde-plasma-desktop is a meta; plasma-desktop is the real package.
dpkg-query -W -f='${db:Status-Status}\n' plasma-desktop 2>/dev/null | grep -q '^installed$' \
  || { echo "error: plasma-desktop not installed — install KDE first." >&2; exit 1; }

# `|| true` is load-bearing: dpkg-query exits 1 on never-seen patterns, and with
# pipefail the awk pipe would also fail, silently killing the loop under set -e.
expand_installed() {
  local pat
  for pat in "$@"; do
    dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' "$pat" 2>/dev/null \
      | awk '$1 == "installed" {print $2}' || true
  done
  return 0
}
# Skip packages not in any enabled repo — MX repos are slimmer than Debian's.
available_only() {
  local p; for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 && printf '%s\n' "$p"; done
  return 0
}
# Echo the first of its args that's on PATH (empty if none). KF6/KF5 tools
# coexist; this picks whichever generation is installed.
firstof() {
  local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }; done
  return 0
}

# --- defensive pre-step: protect the desktop from `autoremove --purge` -------
# Purging metas (kdegames/kde-edu/…) leaves their old deps "automatic"; the
# final `apt autoremove --purge` then cascades into plasma-desktop/kwin/sddm/
# dolphin and the desktop is gone next login. Fix: mark every load-bearing
# piece "manual" first (idempotent + reversible). Mark only installed ones.
echo "── protecting core KDE from autoremove cascade ──"
core=(
  plasma-desktop plasma-workspace plasma-framework
  kwin-x11 kwin-wayland kwin-common
  sddm sddm-theme-debian-breeze
  systemsettings
  kio kio-extras
  dolphin konsole kate ark
  plasma-nm plasma-pa powerdevil
  bluedevil
  kdeaccessibility
  kscreen kscreenlocker
  breeze breeze-icon-theme breeze-cursor-theme
  qt6-wayland
)
mapfile -t core_present < <(expand_installed "${core[@]}")
if (( ${#core_present[@]} )); then
  printf 'marking %d core KDE packages as manual\n' "${#core_present[@]}"
  (( dry )) && printf 'DRY  sudo apt-mark manual %s\n' "${core_present[*]}" \
            || sudo apt-mark manual "${core_present[@]}" >/dev/null
fi
# Hold kdeaccessibility specifically — historical wart: some KDE metas list it
# as a Recommends, and certain Debian versions still let autoremove drop it.
if apt-cache show kdeaccessibility >/dev/null 2>&1; then
  (( dry )) && echo "DRY  sudo apt-mark hold kdeaccessibility" \
            || sudo apt-mark hold kdeaccessibility >/dev/null
fi

# --- removals ---------------------------------------------------------------
to_remove=(
  # 1. legacy/redundant KDE apps + the full kdepim suite (so akonadi cleanup
  #    below is meaningful — kmail/korganizer/etc. anchor the PIM stack)
  konqueror konq-plugins
  akregator kmail kaddressbook korganizer kontact kleopatra kgpg kdepim-runtime
  kwrite xterm
  dragonplayer juk elisa
  goldendict-ng
  debian-reference-common khelpcenter

  # 2. image editing (reinstall on demand)
  gimp

  # 3. non-Latin / CJK input stacks (fcitx, fcitx5, mozc, anthy, ibus, Thai term)
  fcitx fcitx-bin fcitx-config-common fcitx-data fcitx-frontend-all
  fcitx-module-quickphrase-editor fcitx-modules
  fcitx5 fcitx5-config-qt fcitx5-data fcitx5-modules
  mozc-data mozc-server mozc-utils-gui uim-mozc
  anthy anthy-common ibus ibus-data xiterm+thai

  # 4. KDE games — meta + individual pkgs (drop meta or autoremove drags them back)
  kdegames
  blinken bomber bovo granatier kajongg kanagram kapman katomic
  kbattleship kblackbox kblocks kbounce kbreakout kdiamond
  kfourinline kgoldrunner kigo killbots kiriki kjumpingcube klickety
  klines kmahjongg kmines knavalbattle knetwalk knights kollision
  kpat kreversi kshisen ksirk ksnakeduel kspaceduel ksquares
  ksudoku ktuberling kubrick lskat palapeli picmi

  # 5. KDE edutainment — meta + individual pkgs
  kde-edu
  cantor kalzium kbruch kgeography khangman kig kiten klettres
  kmplot kstars ktouch kturtle kwordquiz marble minuet parley rocs step

  # 6. legacy/duplicate utilities (each has a better alt)
  kcharselect kcolorchooser kfind kget kjots kompare knotes kruler
  ktimer sweeper k3b kbackup kolourpaint

  # 7. Akonadi PIM stack — once kmail/kontact are gone, daemons + mariadb just
  #    burn RAM. autoremove leaves mariadb-server (Recommends); explicit purge.
  'akonadi-*' 'kdepim-*'
  mariadb-server mariadb-server-core default-mysql-server virtual-mysql-server

  # 8. Plasma extras — slims widget picker + KRunner menu, stops data-engine
  #    daemons. Plasma core (panel/desktop/KWin) untouched.
  plasma-widgets-addons plasma-runners-addons plasma-wallpapers-addons
  plasma-dataengines-addons kdeplasma-addons

  # 9. services + niche
  kdeconnect krdc krfb plasma-vault
  okteta kfontview kdf kup-backup
  kontrast ksystemlog kdebugsettings
  'phonon*-backend-vlc'

  # 10. cosmetic packs (Breeze is the default; Oxygen is legacy)
  plasma-workspace-wallpapers oxygen-icon-theme oxygen-sounds

  # 11. Debian doc cruft
  doc-debian 'installation-guide-*'
)
(( no_bluetooth )) && to_remove+=( bluedevil bluez bluez-obexd blueman 'libbluetooth*' )

mapfile -t present < <(expand_installed "${to_remove[@]}")
if (( ${#present[@]} == 0 )); then
  echo "── nothing to remove (already debloated) ──"
else
  printf '── removing %d packages ──\n' "${#present[@]}"
  run sudo apt purge --autoremove -y "${present[@]}"
fi

# --- language filter --------------------------------------------------------
# Drop l10n/hunspell/aspell/non-English manpages/task-*-desktop unless code is
# en or de. Keyboard layouts / xkb-data are untouched.
echo "── language filter (keep en_*/de_*, drop the rest) ──"
mapfile -t lang_cand < <(expand_installed \
  'kde-l10n-*' 'firefox-esr-l10n-*' 'thunderbird-l10n-*' \
  'hunspell-*' 'aspell-*' 'myspell-*' 'manpages-*' 'task-*-desktop')
lang_drop=()
for p in "${lang_cand[@]}"; do
  case "$p" in
    *-en|*-en-*|*english*) ;;
    *-de|*-de-*|*german*) ;;
    manpages|manpages-dev|manpages-posix|manpages-posix-dev) ;;
    *) lang_drop+=( "$p" ) ;;
  esac
done
if (( ${#lang_drop[@]} )); then
  printf '── dropping %d non-en/non-de language packages ──\n' "${#lang_drop[@]}"
  run sudo apt purge --autoremove -y "${lang_drop[@]}"
fi

echo "── /etc/locale.gen → en_US.UTF-8 + de_DE.UTF-8 ──"
if (( dry )); then
  echo "DRY  rewrite /etc/locale.gen + sudo locale-gen"
else
  sudo tee /etc/locale.gen >/dev/null <<'EOF'
en_US.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
EOF
  sudo locale-gen
fi

# --- service tweaks ---------------------------------------------------------
# Disable Baloo file indexer — keeps the libs (KDE apps link them) but stops
# the background daemon + SSD churn. Idempotent.
baloo=$(firstof balooctl6 balooctl)
if [[ -n $baloo ]]; then run "$baloo" disable || true; fi

# --- Plasma config tweaks (per-user) ----------------------------------------
# MUST NOT run under sudo or configs land in /root/.config.
KW=$(firstof kwriteconfig6 kwriteconfig5)
if [[ -n $KW ]]; then
  echo "── Plasma config tweaks ──"
  run "$KW" --file ksmserverrc --group General --key loginMode emptySession
  run "$KW" --file kdeglobals  --group KDE     --key AnimationDurationFactor 0
  # Dolphin Plugins: only set if the user hasn't already configured it —
  # overwriting unconditionally was wiping per-user plugin choices on re-run.
  KREAD=$(firstof kreadconfig6 kreadconfig5)
  if [[ -n $KREAD ]] \
     && [[ -z $("$KREAD" --file dolphinrc --group PreviewSettings --key Plugins 2>/dev/null) ]]; then
    run "$KW" --file dolphinrc --group PreviewSettings --key Plugins \
      "imagethumbnail,jpegthumbnail,svgthumbnail,exrthumbnail"
  fi
fi

# --- additions --------------------------------------------------------------
echo "── installing extras (flatpak backend + plymouth GUI) ──"
mapfile -t extras_ok < <(available_only plasma-discover-backend-flatpak kde-config-flatpak kde-config-plymouth)
(( ${#extras_ok[@]} )) && run sudo apt install -y "${extras_ok[@]}"

# --- cleanup ----------------------------------------------------------------
echo "── autoremove --purge ──"
run sudo apt autoremove --purge -y

cat <<'EOF'

── done ──
Reboot recommended — Akonadi/Baloo daemons linger until session restart.
To bring something back:  sudo apt install <pkg>
EOF
