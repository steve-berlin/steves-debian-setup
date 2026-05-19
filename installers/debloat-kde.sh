#!/usr/bin/env bash
# debloat-kde.sh — strip Debian/MX KDE Plasma down to a working desktop.
#
# Adapted from https://github.com/cl0v3r404/Debloat-KDE-Plasma-Debian
# (original by cl0v3r404, in Spanish). This version is English (US),
# idempotent, dry-run-able, and substantially extended.
#
# What it does:
#   - Holds kdeaccessibility so apt autoremove doesn't pull it out as a
#     side-effect of removing other kde-* packages.
#   - apt purge of: legacy KDE apps, non-Latin/CJK input methods, KDE
#     games + games meta, KDE edutainment + edu meta, duplicate/legacy
#     utilities, the entire Akonadi PIM stack (left orphaned once kmail
#     /korganizer/etc. are gone — explicit purge stops mariadb-server
#     and akonadiserver from lingering as a Recommends), Plasma extra
#     widgets/runners/wallpapers/data-engines (slims the widget picker
#     and stops the background data-engine daemons), and niche services
#     /apps (kdeconnect, krdc/krfb VNC, plasma-vault, okteta, kfontview,
#     kdf, kup-backup, kontrast, ksystemlog, kdebugsettings, the vlc
#     phonon backends).
#   - Disables the Baloo file indexer (keeps the libs so KDE apps that
#     link against it still build, just stops the background daemon
#     and the CPU/SSD churn).
#   - Strips cosmetic packs (plasma-workspace-wallpapers,
#     oxygen-icon-theme, oxygen-sounds) and Debian doc cruft
#     (doc-debian, installation-guide-*).
#   - Drops every l10n / hunspell / aspell / manpages-*-l10n / task-*-
#     desktop package whose language code isn't en or de (keeps en_*
#     and de_* variants). Keyboard layouts are untouched.
#   - Rewrites /etc/locale.gen to en_US.UTF-8 + de_DE.UTF-8 only and
#     reruns locale-gen.
#   - Plasma config tweaks (per-user, via kwriteconfig6):
#       * ksmserverrc loginMode=emptySession   (no session restore →
#                                               saves 50-100 MB at login)
#       * kdeglobals AnimationDurationFactor=0 (instant transitions)
#       * dolphinrc Plugins=image-only         (no video/PDF thumbnail
#                                               daemon spawns)
#   - Installs plasma-discover-backend-flatpak + kde-config-flatpak so
#     Discover can install Flatpaks; kde-config-plymouth for the boot-
#     splash GUI module.
#   - apt autoremove --purge to sweep the orphaned deps.
#
# Modes:
#   (no flag)        Run the debloat with default removals.
#   --dry-run        Print every command, mutate nothing.
#   --no-bluetooth   ALSO purge bluedevil/bluez/blueman. Opt-in because
#                    most laptops have BT hardware worth keeping.

set -euo pipefail

dry=0
no_bluetooth=0
for a in "$@"; do
  case $a in
    --dry-run)      dry=1 ;;
    --no-bluetooth) no_bluetooth=1 ;;
    -h|--help)      sed -n '2,48p' "$0"; echo "Usage: $0 [--dry-run] [--no-bluetooth]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# preflight
for c in apt apt-mark apt-cache dpkg-query sudo awk; do
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

# 1. Legacy/redundant KDE apps from the upstream debloat list + the rest
#    of the kdepim suite (so the akonadi cleanup below is meaningful).
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

# 7. Akonadi PIM stack — once kmail/korganizer/kontact/etc. are gone,
#    the akonadi daemons and mysql/mariadb backend just burn RAM. apt
#    autoremove will catch most of these, but mariadb-server is often
#    pulled as a Recommends and lingers. Explicit purge stops that.
akonadi=(
  'akonadi-*'
  'kdepim-*'
  mariadb-server mariadb-server-core
  default-mysql-server virtual-mysql-server
)

# 8. Plasma extras — addon packs from kde-standard. Removing them slims
#    the widget picker, the runner menu, and stops the background data-
#    engine daemons. Plasma itself (panel/desktop/window manager) is
#    untouched.
plasma_addons=(
  plasma-widgets-addons plasma-runners-addons
  plasma-wallpapers-addons plasma-dataengines-addons
  kdeplasma-addons
)

# 9. Services + niche apps that ship with kde-standard but most users
#    never open. kdeconnect is the controversial one — if you sync a
#    phone, reinstall with `sudo apt install kdeconnect`. krdc/krfb
#    are VNC client/server. plasma-vault is encrypted-folder support.
#    phonon4qt[56]-backend-vlc is dead weight once vlc itself is gone.
services_niche=(
  kdeconnect
  krdc krfb
  plasma-vault
  okteta kfontview kdf kup-backup
  kontrast ksystemlog kdebugsettings
  'phonon*-backend-vlc'
)

# 10. Cosmetic packs — Breeze is the default icon theme / sound theme
#     in Plasma, so the Oxygen alternates and the bundled wallpaper
#     pack are pure disk overhead. ~150 MB total.
cosmetics=(
  plasma-workspace-wallpapers
  oxygen-icon-theme
  oxygen-sounds
)

# 11. Debian doc cruft — the installation guide stays around after the
#     OS is on disk, and doc-debian is rarely opened. man pages stay
#     (kept manpages, manpages-dev below in the language filter).
debian_docs=(
  doc-debian
  'installation-guide-*'
)

# 12. Bluetooth (opt-in via --no-bluetooth). Most laptops have BT
#     hardware worth keeping for headsets/peripherals; only nuke if
#     you're certain you won't use it.
bluetooth=( bluedevil bluez bluez-obexd blueman 'libbluetooth*' )

to_remove=(
  "${legacy[@]}" "${images[@]}" "${input[@]}"
  "${games[@]}" "${edu[@]}" "${utils[@]}"
  "${akonadi[@]}" "${plasma_addons[@]}" "${services_niche[@]}"
  "${cosmetics[@]}" "${debian_docs[@]}"
)
(( no_bluetooth )) && to_remove+=( "${bluetooth[@]}" )

mapfile -t present < <(expand_installed "${to_remove[@]}")

if (( ${#present[@]} == 0 )); then
  echo "── nothing to remove (already debloated) ──"
else
  printf '── removing %d packages ──\n' "${#present[@]}"
  run sudo apt purge --autoremove -y "${present[@]}"
fi

# --- language filter ------------------------------------------------------

# Drop every l10n / hunspell / aspell / non-English manpages / Debian
# language-task package whose code isn't en or de. Keyboard layouts
# (kxkbrc / xkb-data) are untouched — this only touches system-wide
# *language packs*, not input methods.
echo "── language filter (keep en_*/de_*, drop the rest) ──"
mapfile -t lang_cand < <(expand_installed \
  'kde-l10n-*' \
  'firefox-esr-l10n-*' 'thunderbird-l10n-*' \
  'hunspell-*' 'aspell-*' 'myspell-*' \
  'manpages-*' 'task-*-desktop')
lang_drop=()
for p in "${lang_cand[@]}"; do
  case "$p" in
    *-en|*-en-*|*english*) ;;                                     # keep English
    *-de|*-de-*|*german*) ;;                                      # keep German
    manpages|manpages-dev|manpages-posix|manpages-posix-dev) ;;   # base = English
    *) lang_drop+=( "$p" ) ;;
  esac
done
if (( ${#lang_drop[@]} )); then
  printf '── dropping %d non-en/non-de language packages ──\n' "${#lang_drop[@]}"
  run sudo apt purge --autoremove -y "${lang_drop[@]}"
else
  echo "skip: no non-en/non-de language packages installed"
fi

# /etc/locale.gen → en_US.UTF-8 + de_DE.UTF-8 only, then regenerate.
echo "── /etc/locale.gen → en_US.UTF-8 + de_DE.UTF-8 ──"
if (( dry )); then
  printf 'DRY  rewrite /etc/locale.gen + sudo locale-gen\n'
else
  sudo tee /etc/locale.gen >/dev/null <<'EOF'
en_US.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
EOF
  sudo locale-gen
fi

# --- service tweaks -------------------------------------------------------

# Disable the Baloo file indexer. Keeps the libs (KDE apps link against
# them) but stops the background daemon — recovers ~5-15% CPU on a busy
# session and ends the SSD churn. Idempotent: balooctl disable on an
# already-disabled index is a no-op.
echo "── disable baloo file indexer ──"
if command -v balooctl6 >/dev/null 2>&1; then
  run balooctl6 disable || true
elif command -v balooctl >/dev/null 2>&1; then
  run balooctl disable || true
else
  echo "skip: no balooctl found (baloo not installed?)"
fi

# --- Plasma config tweaks (per-user, via kwriteconfig) -------------------

# These edit ~/.config/* for the invoking user. Don't run this script
# under sudo or the configs land in /root/.config. All reversible from
# System Settings if you want any back.
echo "── Plasma config tweaks ──"
KW=""
command -v kwriteconfig6 >/dev/null 2>&1 && KW=kwriteconfig6
[[ -z $KW ]] && command -v kwriteconfig5 >/dev/null 2>&1 && KW=kwriteconfig5
if [[ -n $KW ]]; then
  # Empty session at every login (no restore of last session's apps).
  run "$KW" --file ksmserverrc --group General --key loginMode emptySession
  # Animations fire instantly (still visible, just 0-duration).
  run "$KW" --file kdeglobals --group KDE --key AnimationDurationFactor 0
  # Dolphin: keep image thumbnails, kill video/PDF/audio thumbnailers
  # (those spawn ffmpegthumbs / poppler / taglib on every folder browse).
  run "$KW" --file dolphinrc --group PreviewSettings --key Plugins \
    "imagethumbnail,jpegthumbnail,svgthumbnail,exrthumbnail"
else
  echo "skip: no kwriteconfig6/5 on PATH"
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
Reboot recommended — Akonadi/Baloo daemons linger until session restart.
To bring something back:  sudo apt install <pkg>
EOF
