#!/usr/bin/env bash
# install-music-dl.sh — install three command-line programs that turn a web
# link into audio files on disk.
#
#   command            downloads from                          you need
#   rip (streamrip)    Qobuz, Tidal, Deezer, SoundCloud        own paid account
#   spotdl             Spotify playlists and albums            nothing
#   yt-dlp             YouTube, SoundCloud, Bandcamp, ~1800    nothing
#                      sites (only if nothing else owns it;
#                      see handle_ytdlp)
#
# How spotdl handles Spotify: Spotify does not let programs download its audio.
# So spotdl does two steps. First it asks Spotify's public information service
# (its public API) what is in the playlist: titles, artists, album art, order.
# That is just a list, no audio. Then it searches YouTube for each song and
# downloads the sound from there. No Spotify account needed; nothing is taken
# from Spotify but the list.
#
# streamrip is the only one that reaches real lossless audio: FLAC files that
# are bit-for-bit the CD, not squashed MP3. It gets there by logging in AS YOU
# and asking for the same stream the official app would play. So:
#   Tidal, Qobuz   need a paid plan with lossless. No plan, no lossless.
#   Deezer         the free tier only serves 128kbps MP3. Lossless needs HiFi.
#   SoundCloud     open, no account needed.
# This script writes NO credentials, and never will (repo rule: no creds in
# git, the repo is public). post_notes prints the one command that opens
# streamrip's config; filling it in is on you.
#
# Why pipx, not `pip3 install --break-system-packages --user` (utils.sh step 9):
# these tools are Python programs. Python programs lean on libraries
# (prewritten chunks of code). Plain pip puts every program's libraries in one
# shared pile (site-packages). Two programs that want different versions of
# the same library then fight: whichever installs second wins, and the other
# quietly breaks at run time. pipx gives each program its own private sandbox
# (a "virtual environment", or venv) with its own copy of every library.
# Not a theory here: streamrip and spotdl share 16 libraries and disagree on
# one, `pillow` (pictures). streamrip pins 10.4.0, spotdl needs 12.3.0. One
# site-packages cannot hold both. Same bug that made utils.sh step 9b put
# yewtube on its own pip line (it wants an old `httpx` and would drag yt-dlp,
# tldr and platformio down with it). pipx makes that whole class of bug go away.
#
# How to use it:
#   installers/install-music-dl.sh --dry-run    print the plan, change nothing
#   installers/install-music-dl.sh              install, or upgrade, all of it
#   installers/install-music-dl.sh --reinstall  rebuild each sandbox from scratch
#   installers/install-music-dl.sh --uninstall  drop sandboxes, keep pipx+ffmpeg
# Re-running the plain form is safe: it upgrades what is out of date and leaves
# the rest alone. Examples once installed:
#   rip url https://tidal.com/album/12345678
#   spotdl download https://open.spotify.com/playlist/abc123
#   yt-dlp -x --audio-format flac https://youtube.com/watch?v=xyz
#
# What was tested (2026-08-24, on the deployed box):
#   yt-dlp   full download, converted to FLAC 44.1kHz stereo, checked with
#            ffprobe. Works.
#   spotdl   Spotify lookup works (right artist, album). The YouTube audio leg
#            is blocked by YouTube's bot gate (see venv_has_module).
#   rip      creates its config, asks for your login, exits cleanly if you
#            give none. The real download needs a paid account; not tested.
# Quirk: `rip search` opens an interactive menu and needs a real terminal. In a
# script it crashes with `No such device or address: '/dev/tty'`. Use `rip url`
# when scripting.
#
# Exit codes: 0 done (or --help), 1 a preflight check failed (or any failing
# command, through `set -e`), 2 unknown argument.

# Re-exec under bash if run as `sh install-music-dl.sh`. `sh` is dash here, and
# dash does not understand the bash-only syntax below.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# -e: stop at the first failing command. -u: an unset variable is an error.
# -o pipefail: a pipe fails if any part of it fails, not only the last part.
set -euo pipefail

# The two apps this script always installs with pipx.
APPS=(streamrip spotdl)          # always pipx-managed
# Helpers from apt. ffmpeg converts audio between formats. Without it you get
# raw streams instead of playable FLAC or MP3 files.
APT_DEPS=(pipx ffmpeg)           # ffmpeg: FLAC/AAC remux for both apps
# Sandboxes that must be able to load curl_cffi (see venv_has_module).
IMPERSONATORS=(yt-dlp spotdl)    # venvs that must be able to import curl_cffi (may already)

# dry=1 means "print, change nothing". mode is install, reinstall or uninstall.
dry=0; mode=install

# Read the flags. Bare = install, or `pipx upgrade` what is already there.
# --reinstall = `pipx install --force`, rebuilding each sandbox.
# --uninstall = remove the pipx sandboxes only. --dry-run combines with any
# mode. Anything else is exit 2.
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --reinstall) mode=reinstall ;;
    --dry-run)   dry=1 ;;
    -h|--help)
      echo "Usage: $0 [--reinstall|--uninstall] [--dry-run]"
      echo "  bare         install/upgrade streamrip + spotdl (+ yt-dlp if unowned)"
      echo "  --reinstall  pipx install --force, rebuilding each venv"
      echo "  --uninstall  drop the pipx venvs; keeps pipx, ffmpeg, your config"
      echo "  --dry-run    print the plan, change nothing"
      exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

# run CMD...: in dry-run, print "DRY  CMD"; otherwise really run CMD.
run() { if (( dry )); then printf 'DRY  %s\n' "$*"; else "$@"; fi; }

# pipx_has APP: true if pipx already manages APP. It takes the first word of
# each `pipx list --short` line, wraps the list in newlines, and checks if
# "<newline>APP<newline>" is inside. Built without `grep -q` on purpose: under
# pipefail, grep -q closes the pipe at the first match, the writer gets
# SIGPIPE, and the pipe reports failure. Same trap install-anki.sh and
# fix-suspend-freeze.sh call out.
pipx_has() {
  local pkgs
  pkgs=$'\n'$(pipx list --short 2>/dev/null | awk '{print $1}' || true)$'\n'
  [[ $pkgs == *$'\n'"$1"$'\n'* ]]
}

# preflight: check the tools before touching anything. Needs sudo, apt-get,
# dpkg, python3 and awk. A miss stops the script loud (exit 1). Under --dry-run
# a miss is only a "warning:" (the local `miss` helper decides), because you
# usually dry-run BEFORE installing the toolchain (same as install-ly.sh).
preflight() {
  local miss; miss() { if (( dry )); then echo "warning: $1" >&2; else echo "$1" >&2; exit 1; fi; }
  for c in sudo apt-get dpkg python3 awk; do
    command -v "$c" >/dev/null || miss "missing: $c"
  done
  # Python version window: streamrip and yt-dlp want >=3.10; spotdl's metadata
  # caps it at <3.15. Outside that window pipx fails deep in its build with a
  # useless traceback, so check up front. python3 prints e.g. "3.13" ("0.0" if
  # it can't run). awk splits it on "." and exits 0 only for 3.10 to 3.14.
  local pyv
  pyv=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo 0.0)
  if ! awk -v v="$pyv" 'BEGIN{split(v,a,".");exit !(a[1]==3 && a[2]>=10 && a[2]<15)}'; then
    miss "python3 is $pyv — need >=3.10 and <3.15 (spotdl's ceiling)"
  fi
}

# ensure_apt_deps: apt-install pipx and ffmpeg, but only the ones dpkg says are
# missing. If both are there, just say so and run no apt at all.
ensure_apt_deps() {
  local need=() p
  for p in "${APT_DEPS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then need+=("$p"); fi
  done
  if (( ${#need[@]} )); then
    run sudo apt-get update -y
    run sudo apt-get install -y --no-install-recommends "${need[@]}"
  else
    echo "apt deps already present: ${APT_DEPS[*]}"
  fi
}

# ensure_path: pipx puts small launcher files ("shims") in ~/.local/bin. PATH is
# the list of folders your shell searches for commands. If ~/.local/bin is not
# in it, run `pipx ensurepath` to add it. utils.sh's pip --user line uses the
# same folder, so on a box that ran utils.sh it is already there.
ensure_path() {
  case ":${PATH}:" in
    *":$HOME/.local/bin:"*) echo "PATH already has ~/.local/bin" ;;
    *) run pipx ensurepath ;;
  esac
}

# pipx_install APP: not there yet -> `pipx install`. There and --reinstall ->
# `pipx install --force` (rebuild the sandbox). There otherwise -> upgrade.
pipx_install() {
  local app=$1
  if pipx_has "$app"; then
    if [[ $mode == reinstall ]]; then
      run pipx install --force "$app"
    else
      run pipx upgrade "$app"      # exits 0 and prints "already at latest"
    fi
  else
    run pipx install "$app"
  fi
}

# handle_ytdlp: yt-dlp is the one collision in this stack. It can arrive three ways, and on the
# deployed T480 all three are present at once: apt (/usr/bin/yt-dlp), utils.sh
# step 9's `pip3 --break-system-packages --user`, and pipx. The middle two both
# target ~/.local/bin/yt-dlp — the exact path pipx wants for its shim. pipx won
# that race here, leaving the pip *package* orphaned in ~/.local/lib with no
# script, and `apt` still owning the copy that actually wins PATH.
#
# So: adopt yt-dlp into pipx ONLY when nothing else provides it. `pipx install`
# on an unowned ~/.local/bin/yt-dlp would refuse ("not associated with pipx"),
# and --force would shadow a pip package that rots in ~/.local/lib and comes
# back on the next utils.sh run. The three branches below:
#   pipx owns it            -> upgrade (or --force rebuild), then warn if shadowed
#   another copy is on PATH -> leave it alone, say where it is
#   nothing provides it     -> fresh `pipx install`, then warn if shadowed
# It never removes the apt or pip copies for you; it tells you and you decide.
#
# This costs nothing functionally: spotdl vendors yt-dlp as a LIBRARY inside its
# own venv, so it never consults the yt-dlp CLI at all. streamrip does not use
# yt-dlp in any form (aiohttp + deezer-py + ffmpeg). Only interactive `yt-dlp`
# invocations care which copy wins PATH.
handle_ytdlp() {
  if pipx_has yt-dlp; then
    pipx_install yt-dlp
    warn_if_shadowed
  elif command -v yt-dlp >/dev/null; then
    echo "yt-dlp: already provided by $(command -v yt-dlp) — left alone."
  else
    run pipx install yt-dlp
    warn_if_shadowed
  fi
}

# warn_if_shadowed: the shell searches PATH folders top to bottom; the first
# match wins and the rest are invisible. pipx's shim lives in ~/.local/bin, but
# that folder is LAST in this box's PATH (after /usr/bin), so Debian's
# apt-packaged /usr/bin/yt-dlp wins. The upgrade then succeeds and changes
# nothing: pipx bumps a binary the shell never reaches. That matters because
# the distro copy goes stale. YouTube changes its pages every few weeks and
# yt-dlp ships fixes within days, while Debian's copy is frozen at release.
# A stale yt-dlp fails on YouTube with a confusing extraction error. So: if
# the shim exists but `command -v yt-dlp` points somewhere else, warn loudly
# and name both fixes (move ~/.local/bin earlier in PATH in ~/.zshrc, or
# `sudo apt purge yt-dlp`).
warn_if_shadowed() {
  if (( dry )); then return 0; fi   # nothing installed yet under --dry-run
  local on_path shim="$HOME/.local/bin/yt-dlp"
  on_path=$(command -v yt-dlp 2>/dev/null || true)
  if [[ -n $on_path && -e $shim && $on_path != "$shim" ]]; then
    echo "warning: pipx manages $shim, but 'yt-dlp' resolves to $on_path" >&2
    echo "warning: ~/.local/bin sorts after that dir in PATH, so pipx upgrades" >&2
    echo "warning: will not change the yt-dlp you actually run. Either move" >&2
    echo "warning: ~/.local/bin earlier in PATH (~/.zshrc) or 'sudo apt purge yt-dlp'." >&2
  fi
}

# venv_has_module APP MODULE: true if APP's pipx sandbox can import MODULE.
#
# Why we care (the VPN problem): this box keeps NordVPN connected all the time
# and rotates country every six hours. Traffic leaves from an exit IP shared by
# lots of strangers (Senegal at the time of writing). Sites can't tell you
# apart from them, so they treat the whole IP as suspicious and challenge it.
# There are two different challenges, needing two different fixes.
#
# 1. Cloudflare's 403. Cloudflare can tell a program from a real browser by the
#    exact way each starts an encrypted connection, a kind of fingerprint
#    (TLS/JA3). A plain `yt-dlp <url>` on a CDN-fronted host dies with:
#      ERROR: [generic] Got HTTP Error 403 caused by Cloudflare anti-bot challenge
#    The library curl-cffi lets yt-dlp copy a real browser's fingerprint:
#    `yt-dlp --impersonate chrome <URL>`. inject_impersonation adds it.
#    spotdl needs the same thing (it drives yt-dlp as a library) but already
#    ships curl-cffi, so the loop finds it and skips the inject.
# 2. YouTube's bot gate: `Sign in to confirm you're not a bot.` Copying a
#    fingerprint does NOT get past this one; tested, with or without
#    --impersonate. YouTube wants cookies from a browser where you are signed
#    in (post_notes prints the yt-dlp and spotdl flags). Since spotdl gets its
#    audio from YouTube, spotdl downloads nothing while the VPN is up unless you
#    give it cookies. Its Spotify half still lists every song, then the audio
#    fetch fails. That is the VPN, not a broken install.
#
# Detection is an import check against the venv's own interpreter, NOT a grep of
# `pipx list --include-injected`. Two reasons that text output lies here: it only
# lists packages pipx itself injected, and spotdl already ships curl-cffi 0.15.0
# as a transitive dependency — pipx then refuses the inject ("already seems to be
# injected") while reporting `injected_packages: []`. What matters is whether the
# module imports, so ask the interpreter. Also avoids a `... | grep -q` pipeline,
# which SIGPIPEs its writer under `pipefail` (see install-anki.sh).
venv_has_module() {
  local py="$HOME/.local/share/pipx/venvs/$1/bin/python"
  if [[ ! -x $py ]]; then return 1; fi
  "$py" -c "import $2" >/dev/null 2>&1
}

# inject_impersonation: for each pipx-managed app in IMPERSONATORS, add
# curl-cffi to its sandbox (`pipx inject`) unless it can already import it.
inject_impersonation() {
  local app
  for app in "${IMPERSONATORS[@]}"; do
    if ! pipx_has "$app"; then continue; fi
    if venv_has_module "$app" curl_cffi; then
      echo "curl-cffi already present in $app's venv"
    else
      run pipx inject "$app" curl-cffi
    fi
  done
}

# post_notes: print the three commands, the streamrip login step and the
# cookie flags for YouTube's bot gate.
post_notes() {
  cat <<'EOF'

Done. Three commands:

  rip url <URL>              streamrip — Qobuz/Tidal/Deezer/SoundCloud
  spotdl download <URL>      Spotify playlist/album -> audio via YouTube
  yt-dlp <URL>               everything else (see any PATH warning above)

streamrip fetches nothing until you give it credentials for a service you
actually subscribe to:

  rip config open            edits ~/.config/streamrip/config.toml

Fill in qobuz / tidal, or deezer's `arl` cookie. This script writes no
credentials and never will (repo rule: no creds in git).

If YouTube answers "Sign in to confirm you're not a bot", that is the VPN exit
IP, not a broken install. Pass browser cookies:

  yt-dlp --cookies-from-browser firefox <URL>
  spotdl --cookie-file ~/cookies.txt download <URL>

`--impersonate chrome` (via curl-cffi) clears Cloudflare 403s but
NOT YouTube's bot gate — that one needs the cookies.
EOF
}

# install_stack: the whole install/upgrade, in order: checks, apt helpers,
# PATH, streamrip + spotdl, yt-dlp, curl-cffi, closing notes.
install_stack() {
  preflight
  ensure_apt_deps
  ensure_path
  local app
  for app in "${APPS[@]}"; do pipx_install "$app"; done
  handle_ytdlp
  inject_impersonation
  post_notes
}

# uninstall_stack: remove the pipx sandboxes of streamrip, spotdl and yt-dlp
# (each only if pipx manages it). It leaves pipx and ffmpeg alone (other things
# on the box use them) and ~/.config/streamrip/ (it may hold your logins).
uninstall_stack() {
  local app
  for app in "${APPS[@]}" yt-dlp; do
    if pipx_has "$app"; then run pipx uninstall "$app"; fi
  done
  echo "Removed the pipx venvs. Left alone: pipx and ffmpeg (shared), and"
  echo "~/.config/streamrip/ — delete that yourself if it holds credentials."
}

case $mode in
  install|reinstall) install_stack ;;
  uninstall)         uninstall_stack ;;
esac
