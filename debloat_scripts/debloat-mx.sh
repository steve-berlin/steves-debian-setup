#!/usr/bin/env bash
# This script uses bash-only features. If you start it as
# `sh debloat-mx.sh`, sh is not bash and BASH_VERSION is empty, so the
# script starts itself again under bash, with the same arguments.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# debloat-mx.sh — remove the software MX Linux ships that you probably
# don't want.
#
# MX comes with a lot pre-installed: its own settings tools, a welcome
# tour, an office suite, a photo editor, CD burning software. All optional,
# all taking disk space and menu entries. This script removes a hand-picked
# list. It is not a "remove everything that looks unused" guess: every
# entry was chosen, and each group has a comment saying why. More notes in
# debloat_scripts/CLAUDE.md.
#
# How to use it:
#   bash debloat_scripts/debloat-mx.sh --dry-run   see the list first — do this
#   bash debloat_scripts/debloat-mx.sh             actually remove
# Read the dry run before the real run. Everything is recoverable with
# `sudo apt install <name>`, but it is faster to notice beforehand that you
# did want GIMP after all.
#
# There is no --uninstall: the reverse of removing a package is installing
# it, and apt already does that.
# For the nvidia/nouveau graphics-driver purge use the sibling
# `debloat-nvidia.sh`.
#
# Exit codes:
#   0  removed, nothing to remove, or dry-run finished
#   1  not MX Linux, or a required tool is missing
#   2  unknown argument
#   A failing apt/sudo command also stops the script (set -e below), with
#   that command's own exit code.

# set -e: stop at the first command that fails.
# set -u: treat a typo'd (unset) variable name as an error.
# set -o pipefail: a pipe fails if any command in it fails, not just the last.
set -euo pipefail

# dry=1 means --dry-run: print what would happen, change nothing.
# Any other argument is an error (exit 2).
dry=0
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    -h|--help) echo "Usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

# run CMD...: in dry-run, print "DRY  CMD" instead of running it.
# Otherwise run CMD as given.
run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# Preflight: every tool the script needs must exist, or stop with exit 1.
for c in apt apt-cache dpkg-query sudo awk; do
  command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done

# Refuse to run on plain Debian. The list is full of mx-* names that only
# exist on MX, so running elsewhere would do nothing useful; this check
# cheaply catches "wrong machine". /etc/mx-version is the marker MX itself
# uses, and it survives switching desktop environments.
[[ -f /etc/mx-version ]] || { echo "error: not MX Linux (no /etc/mx-version)" >&2; exit 1; }

# expand_installed NAME_OR_GLOB...: print one line per package that is
# installed right now. Takes plain names and patterns like 'libreoffice-*'.
# Handing patterns straight to apt on a machine where they aren't installed
# produces errors. So dpkg-query lists each match with its status, and awk
# keeps only the ones whose status is "installed".
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

# to_remove: names and patterns to purge, in 9 groups. A pattern in quotes
# (like 'vlc-*') is passed to dpkg-query as-is, not expanded by bash.
# Opt-ins (commented) at the bottom.
#
# Deliberately NOT in the list — MX's genuinely good tools stay:
#   mx-tools mx-snapshot mx-cleanup mx-tweak mx-repo-manager mx-iso-dump
#   mx-software-defaults mx-default-settings mx-keyring
to_remove=(
  # 1. one-time welcome/tour screens
  mx-welcome mx-tour
  # 2. MX misc bloat: updater, GUI pkg installer, mx-viewer "MX browser"
  #    (a minimal browser), installer for Flash (a plugin that no longer
  #    exists), one-shot codec installer.
  mx-updater 'mx-packageinstaller*' mx-viewer mx-flash mx-codecs
  # 3. settings GUIs that duplicate the desktop's own Settings panels
  #    (keyboard, locale, date/time, user, menu editor)
  mx-keyboard mx-locale mx-date-time mx-user mx-menu-editor 'mx-system-keyboard*'
  # 4. niche network/sharing helpers: rsync frontend, Samba config, share
  #    finder, network assistant, service manager
  mx-rsync mx-samba-config mx-find-shares mx-network-assistant mx-service-manager
  # 5. theme/sound packs (artwork, Faenza icons, sound pickers) + quick-info
  mx-artwork mx-faenza-icons mx-select-sound mx-system-sounds mx-quick-system-info
  # 6. mx-comp-mgr, MX's compositing manager — irrelevant once you switch
  #    to KDE (KWin handles compositing itself)
  mx-comp-mgr
  # 7. bundled heavyweights from the old utils.sh step 14: GIMP, Strawberry,
  #    gmtp, deb-installer, qpdfview, Catfish, LibreOffice helper
  gimp strawberry gmtp deb-installer qpdfview catfish lo-main-helper
  # 8. CD/DVD burning/ripping — dead tech on a laptop with no optical drive
  xfburn asunder brasero 'brasero-*' k3b 'k3b-*' 'libk3b*' xcdroast gnomebaker mybashburn
  # 9. wildcards: all of LibreOffice, all of VLC, all of GIMP
  'libreoffice-*' vlc 'vlc-*' 'gimp*'
  # Opt-in (uncomment any you want gone):
  # mx-conky          # only if you don't run Conky
  # mxlive-usb-maker  # mx-iso-dump covers the same use
  # mx-remastercc     # only useful when remastering the ISO
  # mx-installer      # only useful for an OS reinstall
)

# present: the part of to_remove that is installed right now, removed in
# one apt call. On an already-debloated machine it is empty and the script
# says so. That is why re-running is safe and quick.
mapfile -t present < <(expand_installed "${to_remove[@]}")
if (( ${#present[@]} == 0 )); then
  echo "── nothing to remove (already debloated) ──"
else
  printf '── removing %d packages ──\n' "${#present[@]}"
  run sudo apt purge --autoremove -y "${present[@]}"
fi

# Final pass: clear out libraries nothing needs any more. Often a bigger
# space saving than the packages themselves.
echo "── autoremove --purge ──"
run sudo apt autoremove --purge -y

cat <<'EOF'

── done ──
To bring something back:  sudo apt install <pkg>
For nvidia + nouveau purge: run ./debloat-nvidia.sh
EOF
