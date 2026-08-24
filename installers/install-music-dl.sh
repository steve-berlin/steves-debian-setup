#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-music-dl.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-music-dl.sh — pipx-managed music/audio downloader stack.
#
#   streamrip  Qobuz, Tidal, Deezer, SoundCloud — real lossless, but only with
#              YOUR OWN subscription credentials. Tidal/Qobuz lossless need a
#              paid plan; Deezer free tier is 128k MP3; SoundCloud is open.
#   spotdl     Spotify playlists/albums — reads track METADATA from Spotify's
#              public API, sources the audio from YouTube. No Spotify account.
#   yt-dlp     YouTube, SoundCloud, Bandcamp, ~1800 extractors. Conditional —
#              see handle_ytdlp(); apt, utils.sh step 9, or pipx may own it.
#
# pipx, not `pip3 install --break-system-packages --user` (utils.sh step 9):
# each app lands in its own venv, so they can pin conflicting versions of the
# same library without one resolver conflict taking the other down. Not
# hypothetical — streamrip pins pillow 10.4.0, spotdl needs pillow 12.3.0, and
# they share 16 dependencies total. One site-packages cannot hold both. Same
# failure utils.sh step 9b splits yewtube onto its own pip line to avoid.
#
# This script writes NO credentials. See "post_notes" for the one command that
# opens streamrip's config; filling it in is on you.
set -euo pipefail

APPS=(streamrip spotdl)          # always pipx-managed
APT_DEPS=(pipx ffmpeg)           # ffmpeg: FLAC/AAC remux for both apps
IMPERSONATORS=(yt-dlp spotdl)    # venvs that must be able to import curl_cffi (may already)

dry=0; mode=install

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

run() { if (( dry )); then printf 'DRY  %s\n' "$*"; else "$@"; fi; }

# Is $1 a pipx-managed app? Built without `grep -q`: under `set -o pipefail`
# grep -q closes the pipe on first match and SIGPIPEs the writer, which reports
# as failure — the trap install-anki.sh and fix-suspend-freeze.sh both call out.
pipx_has() {
  local pkgs
  pkgs=$'\n'$(pipx list --short 2>/dev/null | awk '{print $1}' || true)$'\n'
  [[ $pkgs == *$'\n'"$1"$'\n'* ]]
}

# Under --dry-run a missing dep is a warning, not a hard fail (see install-ly.sh):
# you typically dry-run BEFORE installing the toolchain.
preflight() {
  local miss; miss() { if (( dry )); then echo "warning: $1" >&2; else echo "$1" >&2; exit 1; fi; }
  for c in sudo apt-get dpkg python3 awk; do
    command -v "$c" >/dev/null || miss "missing: $c"
  done
  # streamrip/yt-dlp want >=3.10; spotdl's metadata caps it at <3.15. A python
  # outside that window fails deep inside pipx's build, so check it up front.
  local pyv
  pyv=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo 0.0)
  if ! awk -v v="$pyv" 'BEGIN{split(v,a,".");exit !(a[1]==3 && a[2]>=10 && a[2]<15)}'; then
    miss "python3 is $pyv — need >=3.10 and <3.15 (spotdl's ceiling)"
  fi
}

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

# pipx drops shims in ~/.local/bin. utils.sh's pip --user line uses the same dir,
# so on a box that ran utils.sh this is already on PATH and ensurepath is a no-op.
ensure_path() {
  case ":${PATH}:" in
    *":$HOME/.local/bin:"*) echo "PATH already has ~/.local/bin" ;;
    *) run pipx ensurepath ;;
  esac
}

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

# yt-dlp is the one collision in this stack. It can arrive three ways, and on the
# deployed T480 all three are present at once: apt (/usr/bin/yt-dlp), utils.sh
# step 9's `pip3 --break-system-packages --user`, and pipx. The middle two both
# target ~/.local/bin/yt-dlp — the exact path pipx wants for its shim. pipx won
# that race here, leaving the pip *package* orphaned in ~/.local/lib with no
# script, and `apt` still owning the copy that actually wins PATH.
#
# So: adopt yt-dlp into pipx ONLY when nothing else provides it. `pipx install`
# on an unowned ~/.local/bin/yt-dlp would refuse ("not associated with pipx"),
# and --force would shadow a pip package that returns on the next utils.sh run.
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

# pipx's shim lives in ~/.local/bin, but that directory is LAST in this box's
# PATH (after /usr/bin), so Debian's apt-packaged /usr/bin/yt-dlp wins the
# lookup. The upgrade then appears to do nothing: pipx bumps a binary the shell
# never reaches. Distro yt-dlp goes stale fast — YouTube extractor breakage is
# the usual symptom — so say so loudly rather than let it look like a no-op.
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

# curl-cffi gives yt-dlp TLS/JA3 impersonation (`--impersonate chrome`), which is
# the documented way past Cloudflare's anti-bot 403. Not optional on this box:
# NordVPN autoconnect keeps traffic on a shared exit IP 24/7 (Senegal at the time
# of writing), and those IPs are exactly what anti-bot layers challenge. Without
# it a plain `yt-dlp <url>` on a CDN-fronted host dies with:
#   ERROR: [generic] Got HTTP Error 403 caused by Cloudflare anti-bot challenge
# spotdl needs the same capability (it drives yt-dlp as a library) but already
# ships curl-cffi transitively, so the loop below finds it and skips the inject.
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
