#!/usr/bin/env bash
# install-roblox.sh — set up Roblox on Linux via Waydroid + uptodown APK.
# Target profile: MX Linux XFCE / ThinkPad T480 (Intel UHD 620, x86_64, X11).
# Degrades to a warning, not a hard fail, on other hardware or distros so the
# script stays usable outside that profile.
#
# Every step explains what it does in plain English and asks before running.

set -euo pipefail

ROBLOX_DIR=${ROBLOX_DIR:-$HOME/install_roblox}
APK_PATH=${APK_PATH:-$ROBLOX_DIR/roblox.apk}
UPTODOWN_URL=https://roblox.en.uptodown.com/android/download
WAYDROID_SCRIPT_REPO=https://github.com/casualsnek/waydroid_script
WAYDROID_SCRIPT_DIR=$ROBLOX_DIR/waydroid_script
VENV_DIR=$ROBLOX_DIR/venv

auto_yes=0
dry=0
for a in "$@"; do
  case $a in
    -y|--yes)   auto_yes=1 ;;
    --dry-run)  dry=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [-y|--yes] [--dry-run]
  -y, --yes    non-interactive (assume yes to every prompt)
  --dry-run    print actions instead of running them
EOF
      exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

# ---- output helpers ----
if [[ -t 1 ]]; then
  c_cyan=$'\033[36m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'
  c_green=$'\033[32m'; c_dim=$'\033[2m';    c_off=$'\033[0m'
else
  c_cyan= c_yellow= c_red= c_green= c_dim= c_off=
fi

section() { printf '\n%s── %s ──%s\n' "$c_cyan" "$1" "$c_off"; }
eli5()    { printf '%sELI5%s  %s\n' "$c_yellow" "$c_off" "$1"; }
info()    { printf '      %s\n' "$1"; }
warn()    { printf '%swarn%s  %s\n' "$c_yellow" "$c_off" "$1"; }
err()     { printf '%serr%s   %s\n'  "$c_red"    "$c_off" "$1" >&2; }
ok()      { printf '%sok%s    %s\n'  "$c_green"  "$c_off" "$1"; }

ask() {
  (( auto_yes )) && { printf '%s?%s     %s [auto-yes]\n' "$c_cyan" "$c_off" "$1"; return 0; }
  local a
  read -r -p "?     $1 [y/N] " a
  [[ $a == [Yy]* ]]
}

run() { if (( dry )); then printf '%sDRY%s   %s\n' "$c_dim" "$c_off" "$*"; else "$@"; fi; }

require_cmd() { command -v "$1" >/dev/null || { err "need $1 on PATH"; exit 1; }; }

# ---- Step 0: survey ----
section "0/8  system survey"
eli5 "I look at your CPU, GPU, distro, and display server to pick the right
      path. Intel iGPU + X11 + Debian-family is the tuned profile; anything
      else just means you may need to tweak apt commands below."

arch=$(uname -m)
if [[ $arch == x86_64 ]]; then ok "CPU: x86_64"
else warn "CPU $arch — Roblox ships arm64 only; translation setup may differ"; fi

if command -v lspci >/dev/null; then
  gpu=$(lspci | grep -iE 'vga|3d|display' | head -1 | sed 's/^[^:]*: //')
  info "GPU: $gpu"
  [[ $gpu == *Intel* ]] && ok "Intel iGPU (matches T480 profile)"
fi

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "Distro: ${PRETTY_NAME:-unknown}"
  case ${ID_LIKE:-}${ID:-} in
    *debian*|*ubuntu*|*mx*) ok "Debian/Ubuntu family — apt paths will work" ;;
    *) warn "non-Debian distro — translate 'apt install <x>' to your package manager" ;;
  esac
fi

session=${XDG_SESSION_TYPE:-x11}
info "Display server: $session"

# ---- Step 1: waydroid + kernel ----
section "1/8  waydroid & kernel modules"
eli5 "Waydroid runs an Android container on top of your Linux kernel. It
      needs one kernel module: binder_linux, which is how Android apps talk
      to each other. Liquorix (your kernel) ships it built-in; we just check
      it is loadable."

require_cmd waydroid
ok "waydroid $(waydroid --version)"

if [[ -d /sys/module/binder_linux ]] || lsmod 2>/dev/null | grep -q '^binder_linux'; then
  ok "binder_linux active"
elif modinfo binder_linux &>/dev/null; then
  info "binder_linux available but not loaded"
  ask "load it now (sudo modprobe binder_linux)?" && run sudo modprobe binder_linux
else
  warn "binder_linux not found — your kernel may not support Waydroid (check /boot/config-\$(uname -r))"
fi

# ---- Step 2: weston (X11 only) ----
section "2/8  nested Wayland compositor (X11 only)"
eli5 "Waydroid is a Wayland citizen but XFCE is X11. The fix is Weston, a
      tiny reference Wayland compositor (<5 MB) that runs as a window
      inside X11. The launcher script will spawn it automatically. On a
      Wayland desktop we skip this."

if [[ $session == wayland ]]; then
  ok "already on Wayland — weston not required"
elif command -v weston >/dev/null; then
  ok "weston already installed"
else
  info "weston is missing"
  if ask "apt install weston now?"; then
    run sudo apt-get update
    run sudo apt-get install -y weston
  else
    warn "skipped — the launcher will fail until weston exists or you switch to Wayland"
  fi
fi

# ---- Step 3: waydroid init ----
section "3/8  initialise Waydroid (Android 13, VANILLA)"
eli5 "One-time download of the Android system image (~500 MB, VANILLA
      flavour, no Google Play). Roblox accepts 2FA email login and does
      not require Play Services, so the lighter image is enough. Files
      land under /var/lib/waydroid, outside your home."

if [[ -f /var/lib/waydroid/waydroid.cfg ]]; then
  ok "already initialised"
else
  if ask "run sudo waydroid init -s VANILLA now?"; then
    run sudo waydroid init -s VANILLA
  else
    err "cannot continue without init"; exit 1
  fi
fi

# ---- Step 4: container service ----
section "4/8  waydroid-container.service"
eli5 "A system service keeps the Android container alive between runs.
      Enabling it once means the launcher can attach instantly, without
      sudo, every time you hit play."

if systemctl is-active --quiet waydroid-container; then
  ok "waydroid-container running"
else
  ask "enable + start waydroid-container.service?" \
    && run sudo systemctl enable --now waydroid-container
fi

# ---- Step 5: libndk ARM translation ----
section "5/8  ARM → x86 translation (libndk)"
eli5 "Your CPU speaks x86_64 but the Roblox APK is compiled for ARM64.
      Android uses a translator (libndk_translation) to bridge this. The
      community tool waydroid_script automates installing it. We clone
      it into $WAYDROID_SCRIPT_DIR and run it inside a local Python venv
      so nothing touches your system Python."

if ask "install libndk via waydroid_script?"; then
  require_cmd git
  require_cmd python3
  [[ -d $WAYDROID_SCRIPT_DIR ]] \
    || run git clone --depth 1 "$WAYDROID_SCRIPT_REPO" "$WAYDROID_SCRIPT_DIR"
  if [[ ! -d $VENV_DIR ]]; then
    run python3 -m venv "$VENV_DIR"
    run "$VENV_DIR/bin/pip" install --quiet -r "$WAYDROID_SCRIPT_DIR/requirements.txt"
  fi
  ( cd "$WAYDROID_SCRIPT_DIR" \
    && run sudo "$VENV_DIR/bin/python" main.py install libndk )
else
  warn "skipped — Roblox will crash on launch without a translator"
fi

# ---- Step 6: device spoof + multi-window ----
section "6/8  device spoofing and windowed mode"
eli5 $'Default Waydroid props report the device as emulator, which the\nRoblox integrity check rejects. We swap them for a real Pixel 5\nprofile so Roblox opens.'

if ask "apply Pixel 5 device spoof?"; then
  [[ -d $WAYDROID_SCRIPT_DIR ]] || { err "run step 5 first"; exit 1; }
  ( cd "$WAYDROID_SCRIPT_DIR" \
    && run sudo "$VENV_DIR/bin/python" main.py hack devicespoofing )
fi

eli5 $'Multi-window mode lets `waydroid app launch` open Roblox in its\nown Wayland window. Without it, apps render only inside the full\nAndroid desktop, so the launcher would have to show that desktop\nand you would tap Roblox by hand every time. This prop is what\nmakes the one-click launcher work.'

if ask "turn on multi-window mode (persist.waydroid.multi_windows=true)?"; then
  run waydroid prop set persist.waydroid.multi_windows true
fi

# ---- Step 7: fetch APK ----
section "7/8  Roblox APK from uptodown"
eli5 "Uptodown mirrors unmodified vendor APKs. We first try to download
      the file directly. If the uptodown page layout has changed, I
      print the URL and you download it in a browser, save to $APK_PATH
      and rerun."

mkdir -p "$ROBLOX_DIR"

apk_ok() { [[ -s $APK_PATH ]] && head -c 4 "$APK_PATH" | grep -q 'PK'; }

if apk_ok; then
  ok "APK already at $APK_PATH ($(du -h "$APK_PATH" | awk '{print $1}'))"
elif ask "try to fetch APK automatically from $UPTODOWN_URL?"; then
  require_cmd curl
  tmp=$(mktemp)
  # fetch uptodown's download page; || true keeps set -e from killing us
  # if curl fails -- we want to decide below, not bail here
  curl -fsSL -A 'Mozilla/5.0' "$UPTODOWN_URL" -o "$tmp" || true
  # uptodown has used two HTML shapes for the real APK URL; try both
  dl=$(grep -oE 'https://dw[^"]+\.apk' "$tmp" | head -1 || true)
  [[ -z $dl ]] && dl=$(grep -oE 'data-url="[^"]+"' "$tmp" | head -1 | sed 's/^data-url="//; s/"$//')
  rm -f "$tmp"
  [[ -n $dl ]] && { info "resolved: $dl"; run curl -fL -A 'Mozilla/5.0' "$dl" -o "$APK_PATH"; }
  # uptodown sometimes serves a Cloudflare page with HTTP 200 -- re-check magic bytes
  apk_ok || { warn "auto-fetch failed. Open $UPTODOWN_URL in a browser, save as $APK_PATH, then rerun."; exit 1; }
  ok "APK downloaded"
else
  info "no APK present -- drop one at $APK_PATH then rerun"
  exit 0
fi

# ---- Step 8: install APK ----
section "8/8  install APK into Waydroid"
eli5 $'The command waydroid app install is the Waydroid equivalent of\nadb install. After this, Roblox shows up in the Waydroid app list\nand in the XFCE applications menu.'

if ask "install $APK_PATH into waydroid now?"; then
  run waydroid app install "$APK_PATH"
fi

# ---- done ----
section "done"
ok "launch:   $ROBLOX_DIR/rbx"
ok "or alias: alias rbx='$ROBLOX_DIR/rbx'   # add to ~/.zshrc"
info "first launch may take 30-60s while the container warms up."
