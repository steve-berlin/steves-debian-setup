#!/usr/bin/env bash
# install-anki.sh — install Anki, the flashcard program, from the build its own
# authors ship.
#
# Why not `apt install anki`? Debian has an `anki` package, but it is *years*
# behind. Anki's scheduler, sync protocol and add-on system all move. An
# ancient build means broken add-ons and, one day, a sync server that refuses
# to talk to you. So this script goes to Anki's own releases instead.
#
# What an "anki-launcher" is: since version 25.07, Anki's official Linux
# download is not the program. It is a launcher: a small file that, the first
# time you run it, downloads the real app and keeps it up to date afterwards.
# That is why the download is tiny, and why the *first* launch is slow and
# needs internet. Nothing is broken; that is the design.
#
# How to use it:
#   bash installers/install-anki.sh              # install
#   bash installers/install-anki.sh --reinstall  # remove, then install fresh
#   bash installers/install-anki.sh --uninstall  # remove
#   bash installers/install-anki.sh --dry-run    # print the plan, change nothing
# Then start it with `anki`.
#
# Where things end up:
#   /usr/local/bin/anki      the command you type          keep, it is the app
#   /usr/local/share/anki/   launcher files + uninstall.sh keep
#   ~/.local/share/Anki2/    YOUR DECKS, CARDS AND MEDIA   NEVER delete
#   ~/.cache/Anki2/          the real app the launcher got safe, it re-downloads
# Your collection is never touched. Install, reinstall and uninstall all leave
# ~/.local/share/Anki2/ exactly where it is.
#
# Exit codes:
#   0  installed, uninstalled, or dry-run finished
#   1  a missing tool, no matching release, or no unpacked folder found
#   2  unknown argument
#   A failed download or unpack stops the script through `set -e`, with the
#   exit code of curl or tar (not always 1).
#
# Two gotchas, also in installers/CLAUDE.md: don't `exit` from the awk that
# reads GitHub's answer, and don't make `tmp` a `local` (see where each lives).

# Re-exec under bash if run as `sh install-anki.sh`. `sh` is dash here, and dash
# does not understand the bash-only syntax below.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# -e: stop at the first failing command. -u: an unset variable is an error.
# -o pipefail: a pipe fails if any part of it fails, not only the last part.
set -euo pipefail

# The GitHub project that publishes Anki.
REPO=ankitects/anki
# Where Anki's own installer puts the app. Also where its uninstall.sh lives.
PREFIX=/usr/local
# The file name we hunt for in each release: anki-launcher-<ver>-linux.tar.zst.
# `[.]` means "a real dot". Do not write `\.`: `awk -v` eats one backslash,
# and the dot would then match any character.
ASSET_RE='anki-launcher-.*-linux[.]tar[.]zst$'

# dry=1 means "print, change nothing". mode is install, uninstall or reinstall.
dry=0; mode=install
# The temporary folder for the download. It lives at script level, not as a
# `local` inside install_anki. The EXIT trap below runs after that function
# has returned. A local would be gone by then, and `set -u` would crash with
# "tmp: unbound variable". `${tmp:-}` also keeps the trap safe when tmp is
# still empty.
tmp=""  # script-scoped so EXIT trap can rm it
# On any exit (normal, error, Ctrl-C) delete the temporary folder.
trap 'rm -rf "${tmp:-}"' EXIT

# Read the flags. --reinstall = remove, then install fresh. --uninstall = remove.
# --dry-run = print the plan only. Anything else is exit 2.
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --reinstall) mode=reinstall ;;
    --dry-run)   dry=1 ;;
    -h|--help)   echo "Usage: $0 [--reinstall|--uninstall] [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

# run CMD...: in dry-run, print "DRY  CMD"; otherwise really run CMD.
run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# Remove Anki. Anki's own installer leaves an uninstall.sh behind; we just run
# it with sudo. It does not touch ~/.local/share/Anki2/ (your decks).
uninstall_anki() {
  local sh=$PREFIX/share/anki/uninstall.sh
  if [[ -x $sh ]]; then run sudo "$sh"; else echo "No Anki at $PREFIX."; fi
}

install_anki() {
  # Step 1: check the tools. It needs curl, tar, sudo and awk.
  for c in curl tar sudo awk; do
    command -v "$c" >/dev/null || { echo "missing: $c (apt install $c)" >&2; exit 1; }
  done
  # Anki's file is compressed with zstd. Old tar can't read that. If tar's
  # help text has no --zstd, stop with "tar lacks zstd" and the fix.
  tar --help 2>&1 | grep -q -- '--zstd' \
    || { echo "tar lacks zstd — sudo apt install zstd" >&2; exit 1; }

  # Step 2: ask GitHub for the list of recent releases (newest first) and take
  # the first download link whose file name matches ASSET_RE. We walk the list
  # instead of asking for "latest": some releases carry no Linux launcher, and
  # the newest one that does is the one we want. No jq; awk splits each line
  # on `"` so the URL is field 4.
  # Don't `exit` from awk once found. That closes the pipe early, curl gets
  # SIGPIPE, and with pipefail the whole $(...) silently fails. Instead a
  # `seen` flag prints only the first match and lets curl finish.
  local url
  url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases" \
        | awk -F'"' -v re="$ASSET_RE" \
            '/"browser_download_url":/ && $4 ~ re && !seen {print $4; seen=1}')
  # Empty url is usually not a script bug. GitHub allows about 60 anonymous
  # requests per hour per IP address. Past that it sends an error instead of
  # the list, and the search finds nothing. Wait an hour and retry. A shared
  # VPN exit IP makes this more likely: you share the quota with everyone on it.
  [[ -n $url ]] || { echo "No matching launcher asset in recent releases." >&2; exit 1; }
  echo "Found: $url"

  # Step 3: download and unpack into a fresh temporary folder. The EXIT trap
  # above deletes it however the script ends. The file keeps its own name
  # (the part of the URL after the last /). `tar -a` picks the decompressor
  # from the file name (.zst).
  tmp=$(mktemp -d)
  local file=$tmp/${url##*/}
  run curl -fsSL --retry 3 -o "$file" "$url"
  run tar -xaf "$file" -C "$tmp"

  # Step 4: run Anki's own installer from the unpacked anki-* folder, with
  # sudo. It writes to /usr/local, a system location, hence the password
  # prompt. In dry-run nothing was unpacked, so just say what would happen.
  if (( dry )); then
    echo "DRY  cd <extracted dir> && sudo ./install.sh"
  else
    local dir
    dir=$(find "$tmp" -maxdepth 1 -type d -name 'anki-*' | head -n1)
    [[ -d $dir ]] || { echo "extracted dir not found in $tmp" >&2; exit 1; }
    ( cd "$dir" && sudo ./install.sh )
  fi
  echo "Done. Launch with: anki"
}

case $mode in
  install)   install_anki ;;
  uninstall) uninstall_anki ;;
  reinstall) uninstall_anki; install_anki ;;
esac
