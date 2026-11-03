#!/usr/bin/env bash
# This script uses bash-only features. If you start it as
# `sh debloat-kde.sh`, sh is not bash and BASH_VERSION is empty, so the
# script starts itself again under bash, with the same arguments.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# debloat-kde.sh — strip a Debian/MX KDE Plasma desktop down to the parts
# you actually use.
#
# This is the largest and most dangerous of the three debloat scripts. Read
# all the comments before you run it. Per-group notes live in
# debloat_scripts/CLAUDE.md.
#
# Words to know first:
#   package      one installable piece of software, handled by apt.
#   meta-package a package that installs nothing itself. It only exists to
#                pull in a group of other packages.
#   manual       apt's mark for "you asked for this package".
#   automatic    apt's mark for "something else needed this package".
#   autoremove   apt deletes every automatic package nothing needs any more.
#
# How to use it (as your normal user, NOT with sudo — see the Plasma
# settings step below; the script calls sudo itself where needed):
#   bash debloat_scripts/debloat-kde.sh --dry-run       read this output first
#   bash debloat_scripts/debloat-kde.sh
#   bash debloat_scripts/debloat-kde.sh --no-bluetooth  also remove Bluetooth
# Then reboot.
#
# There is no --uninstall. To bring something back: sudo apt install <name>.
# There is no single "undo", because the script does several unrelated
# kinds of thing.
#
# Exit codes:
#   0  finished, nothing to remove, or dry-run finished
#   1  Plasma isn't installed, or a required tool is missing
#   2  unknown argument
#   A failing apt/sudo command also stops the script (set -e below), with
#   that command's own exit code.
#
# set -e: stop at the first command that fails.
# set -u: treat a typo'd (unset) variable name as an error.
# set -o pipefail: a pipe fails if any command in it fails, not just the last.
set -euo pipefail

# dry=1 means --dry-run: print what would happen, change nothing.
# no_bluetooth=1 means --no-bluetooth: add the Bluetooth stack to the
# removal list. It is off by default, since most laptops want Bluetooth.
# Any other argument is an error (exit 2).
dry=0; no_bluetooth=0
for a in "$@"; do
  case $a in
    --dry-run)      dry=1 ;;
    --no-bluetooth) no_bluetooth=1 ;;
    -h|--help)      echo "Usage: $0 [--dry-run] [--no-bluetooth]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

# run CMD...: in dry-run, print "DRY  CMD" instead of running it.
# Otherwise run CMD as given.
run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# Preflight: every tool the script needs must exist, or stop with exit 1.
for c in apt apt-mark apt-cache dpkg-query sudo awk; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

# Refuse to run unless plasma-desktop is installed. That is the real
# package; kde-plasma-desktop is only a meta that points to it. If it is
# missing, you are on the wrong machine. Exit 1.
dpkg-query -W -f='${db:Status-Status}\n' plasma-desktop 2>/dev/null | grep -q '^installed$' \
  || { echo "error: plasma-desktop not installed — install KDE first." >&2; exit 1; }

# expand_installed NAME_OR_GLOB...: print one line per package that is
# installed right now. Takes plain names and patterns like 'akonadi-*'.
# dpkg-query lists each match with its status; awk keeps only the ones
# whose status is "installed". Handing patterns straight to apt would error
# on packages that are not there. With this, a second run finds nothing.
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
# available_only NAME...: print only the names apt can find in an enabled
# repo (apt-cache show succeeds). MX repos are slimmer than Debian's, and
# asking apt to install a missing package would abort the whole run.
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
# This is the single most important step in the file.
#
# The problem: remove a meta-package (kdegames, kde-edu, ...) and everything
# it pulled in becomes automatic and unneeded. If a load-bearing piece of
# the desktop was only ever pulled in by that meta, the final
# `apt autoremove --purge` deletes it too: plasma-desktop, kwin, sddm,
# dolphin ... and the desktop is gone at the next login. Prior versions of
# this script did exactly that.
#
# The fix: mark every load-bearing piece "manual" first. Then it is no
# longer "just a leftover", and autoremove won't touch it.
# It marks only packages that are installed. Safe to run twice. Undo one
# with: apt-mark auto <name>.
echo "── protecting core KDE from autoremove cascade ──"
# core: the load-bearing list. Plasma desktop + workspace, KWin (the window
# manager), SDDM (the login screen) + its theme, System Settings, KIO (file
# access), Dolphin, Konsole, Kate, Ark, the network/audio/power applets,
# Bluetooth applet, accessibility, screen setup + screen locker, the
# Breeze theme, and Qt's Wayland support.
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
# core_present: the part of core that is installed right now.
mapfile -t core_present < <(expand_installed "${core[@]}")
if (( ${#core_present[@]} )); then
  printf 'marking %d core KDE packages as manual\n' "${#core_present[@]}"
  (( dry )) && printf 'DRY  sudo apt-mark manual %s\n' "${core_present[*]}" \
            || sudo apt-mark manual "${core_present[@]}" >/dev/null
fi
# Hold kdeaccessibility specifically — historical wart: some KDE metas list it
# as a Recommends, and certain Debian versions still let autoremove drop it.
# "Hold" means apt will not remove or upgrade it. The hold stays after the
# script ends; release it with: sudo apt-mark unhold kdeaccessibility.
if apt-cache show kdeaccessibility >/dev/null 2>&1; then
  (( dry )) && echo "DRY  sudo apt-mark hold kdeaccessibility" \
            || sudo apt-mark hold kdeaccessibility >/dev/null
fi

# --- removals ---------------------------------------------------------------
# to_remove: names and patterns to purge, in 11 groups. A pattern in quotes
# (like 'akonadi-*') is passed to dpkg-query as-is, not expanded by bash.
to_remove=(
  # 1. legacy/redundant KDE apps + the full kdepim suite (so akonadi cleanup
  #    below is meaningful — kmail/korganizer/etc. anchor the PIM stack).
  #    Konqueror, Akregator, KMail, KOrganizer, KAddressBook, Kontact,
  #    Kleopatra, KGpg, KWrite, xterm, three media players, GoldenDict,
  #    the Debian reference and KHelpCenter.
  konqueror konq-plugins
  akregator kmail kaddressbook korganizer kontact kleopatra kgpg kdepim-runtime
  kwrite xterm
  dragonplayer juk elisa
  goldendict-ng
  debian-reference-common khelpcenter

  # 2. image editing (reinstall on demand)
  gimp

  # 3. non-Latin / CJK input stacks (fcitx, fcitx5, mozc, anthy, ibus, Thai term)
  #    These matter if you type Japanese, Chinese, Korean or Thai.
  #    IF YOU DO, delete this group before running.
  fcitx fcitx-bin fcitx-config-common fcitx-data fcitx-frontend-all
  fcitx-module-quickphrase-editor fcitx-modules
  fcitx5 fcitx5-config-qt fcitx5-data fcitx5-modules
  mozc-data mozc-server mozc-utils-gui uim-mozc
  anthy anthy-common ibus ibus-data xiterm+thai

  # 4. KDE games — the meta + all 41 individual games. Both, because if the
  #    meta stays, autoremove would pull the games back in later.
  kdegames
  blinken bomber bovo granatier kajongg kanagram kapman katomic
  kbattleship kblackbox kblocks kbounce kbreakout kdiamond
  kfourinline kgoldrunner kigo killbots kiriki kjumpingcube klickety
  klines kmahjongg kmines knavalbattle knetwalk knights kollision
  kpat kreversi kshisen ksirk ksnakeduel kspaceduel ksquares
  ksudoku ktuberling kubrick lskat palapeli picmi

  # 5. KDE edutainment — meta + individual pkgs (same pattern as games)
  kde-edu
  cantor kalzium kbruch kgeography khangman kig kiten klettres
  kmplot kstars ktouch kturtle kwordquiz marble minuet parley rocs step

  # 6. legacy/duplicate utilities (each has a better modern alternative)
  kcharselect kcolorchooser kfind kget kjots kompare knotes kruler
  ktimer sweeper k3b kbackup kolourpaint

  # 7. Akonadi PIM stack. Akonadi is the background service behind KDE's
  #    mail, calendar and contacts. It stores its data in a real database
  #    server, MariaDB, which it pulls in as a "Recommends" package.
  #    autoremove does not remove Recommends. So once kmail/kontact are
  #    gone, a whole database server stays installed and running, serving
  #    data nobody reads. That is why mariadb-server is named here.
  'akonadi-*' 'kdepim-*'
  mariadb-server mariadb-server-core default-mysql-server virtual-mysql-server

  # 8. Plasma "addons": extra widgets, extra KRunner search plugins, extra
  #    wallpapers, extra background data engines. Removing them slims the
  #    widget picker + KRunner menu and stops some background daemons.
  #    Plasma core (panel/desktop/KWin) untouched.
  plasma-widgets-addons plasma-runners-addons plasma-wallpapers-addons
  plasma-dataengines-addons kdeplasma-addons

  # 9. services you probably don't use: KDE Connect, remote desktop client
  #    (krdc) + server (krfb), Plasma Vault, a hex editor (okteta), a font
  #    viewer, a disk-usage tool (kdf), a backup tool, a contrast checker,
  #    a log viewer, debug settings, and VLC playback backends for Phonon.
  kdeconnect krdc krfb plasma-vault
  okteta kfontview kdf kup-backup
  kontrast ksystemlog kdebugsettings
  'phonon*-backend-vlc'

  # 10. cosmetic packs: the wallpaper collection, and the legacy Oxygen icon
  #     and sound themes (Breeze is the default now).
  plasma-workspace-wallpapers oxygen-icon-theme oxygen-sounds

  # 11. Debian doc cruft
  doc-debian 'installation-guide-*'
)
# --no-bluetooth: add the whole Bluetooth stack. An explicit purge removes
# bluedevil even though the pre-step marked it manual.
(( no_bluetooth )) && to_remove+=( bluedevil bluez bluez-obexd blueman 'libbluetooth*' )

# present: the part of to_remove that is installed right now. Removed in
# one apt call. Empty on an already-debloated machine, so re-runs are no-ops.
mapfile -t present < <(expand_installed "${to_remove[@]}")
if (( ${#present[@]} == 0 )); then
  echo "── nothing to remove (already debloated) ──"
else
  printf '── removing %d packages ──\n' "${#present[@]}"
  run sudo apt purge --autoremove -y "${present[@]}"
fi

# --- language filter --------------------------------------------------------
# KDE, Firefox, Thunderbird, spell checkers and manual pages all ship one
# package per language. A default install carries dozens you can't read.
# This step lists every installed language package, keeps English and
# German, and removes the rest. IF YOU READ OTHER LANGUAGES, add them to the
# `case` block below before running.
# Keyboard layouts / xkb-data are untouched. Removing a Russian language
# pack does not remove the Russian keyboard layout; those are separate.
echo "── language filter (keep en_*/de_*, drop the rest) ──"
# lang_cand: every installed package that matches a language-pack pattern.
mapfile -t lang_cand < <(expand_installed \
  'kde-l10n-*' 'firefox-esr-l10n-*' 'thunderbird-l10n-*' \
  'hunspell-*' 'aspell-*' 'myspell-*' 'manpages-*' 'task-*-desktop')
# lang_drop: the candidates to purge. The case block keeps a name if it is
# English (*-en, *-en-*, *english*), German (*-de, *-de-*, *german*), or one
# of the base English manual pages (manpages, manpages-dev, manpages-posix,
# manpages-posix-dev). Everything else goes into lang_drop.
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

# Rewrite the system's locale list (/etc/locale.gen) to exactly two lines,
# en_US.UTF-8 and de_DE.UTF-8. Then locale-gen rebuilds the locales from it.
# Any other locale listed there before is gone.
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
# Baloo is KDE's file indexer. It watches your files so search is instant,
# and it reads a lot of disk, all the time. Disable it — keeps the libs (KDE
# apps are built against them; removing them would break those apps) but
# stops the background daemon + SSD churn. Idempotent.
# baloo: the control tool, balooctl6 (KF6) or else balooctl (KF5). Empty if
# neither exists; then this step is skipped. A failure here is ignored.
baloo=$(firstof balooctl6 balooctl)
if [[ -n $baloo ]]; then run "$baloo" disable || true; fi

# --- Plasma config tweaks (per-user) ----------------------------------------
# These settings live in your own ~/.config files.
# MUST NOT run under sudo or configs land in /root/.config, and do nothing
# for you.
# KW: the config writer, kwriteconfig6 or else kwriteconfig5. If neither
# exists, the whole step is skipped.
#   loginMode=emptySession     don't reopen last session's apps at login;
#                              saves 50–100 MB and a slow login
#   AnimationDurationFactor=0  turn off desktop animations; the desktop
#                              feels quicker
#   Dolphin preview Plugins    image formats only (below)
KW=$(firstof kwriteconfig6 kwriteconfig5)
if [[ -n $KW ]]; then
  echo "── Plasma config tweaks ──"
  run "$KW" --file ksmserverrc --group General --key loginMode emptySession
  run "$KW" --file kdeglobals  --group KDE     --key AnimationDurationFactor 0
  # Dolphin preview plugins: image thumbnails only. This stops the file
  # manager starting video/PDF/audio helpers just to browse a folder.
  # Only set if the user hasn't already configured it (kreadconfig finds
  # no value) — overwriting unconditionally was wiping per-user plugin
  # choices on re-run. If no kreadconfig exists, it is not written at all.
  KREAD=$(firstof kreadconfig6 kreadconfig5)
  if [[ -n $KREAD ]] \
     && [[ -z $("$KREAD" --file dolphinrc --group PreviewSettings --key Plugins 2>/dev/null) ]]; then
    run "$KW" --file dolphinrc --group PreviewSettings --key Plugins \
      "imagethumbnail,jpegthumbnail,svgthumbnail,exrthumbnail"
  fi
fi

# --- additions --------------------------------------------------------------
# Three small installs, the KDE-native way to do things you'll want: the
# Flatpak backend for Discover (so the app store can install flatpaks), its
# settings module, and the Plymouth boot-splash settings module.
# extras_ok: the ones your repos actually have (see available_only).
echo "── installing extras (flatpak backend + plymouth GUI) ──"
mapfile -t extras_ok < <(available_only plasma-discover-backend-flatpak kde-config-flatpak kde-config-plymouth)
(( ${#extras_ok[@]} )) && run sudo apt install -y "${extras_ok[@]}"

# --- cleanup ----------------------------------------------------------------
# Final pass: delete every automatic package nothing needs any more. The
# pre-step above is what keeps this from taking the desktop with it.
echo "── autoremove --purge ──"
run sudo apt autoremove --purge -y

# Reboot afterwards: Akonadi and Baloo daemons keep running in the current
# session even after their packages are gone, so the memory only comes back
# after a restart.
cat <<'EOF'

── done ──
Reboot recommended — Akonadi/Baloo daemons linger until session restart.
To bring something back:  sudo apt install <pkg>
EOF
