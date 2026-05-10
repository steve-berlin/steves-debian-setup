#!/usr/bin/env bash
# install-roblox.sh — set up Roblox on Linux via Waydroid + uptodown APK.
# Target profile: MX Linux XFCE / ThinkPad T480 (Intel UHD 620, x86_64, X11).
# Degrades to a warning, not a hard fail, on other hardware or distros so the
# script stays usable outside that profile.
#
# Every step explains what it does in plain English and asks before running.

# Re-exec under bash if invoked as `sh install-roblox.sh`. The script uses
# `[[`, `((`, and other bashisms; under dash these silently return nonzero
# inside `if` conditions (set -e doesn't fire there), so the script limps
# along making wrong decisions instead of erroring out cleanly. POSIX test
# below works in both shells.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

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
eli5 "Waydroid runs an Android container on top of your Linux kernel. The
      kernel has to speak 'binder' -- a fast IPC mechanism Android invented
      in 2008. Every framework call inside Android goes through it. Android
      actually uses three separate binder domains for security isolation:
      'binder' (apps), 'hwbinder' (hardware HALs), 'vndbinder' (vendor
      processes). Liquorix 6.19 ships with binder entirely disabled --
      hard fail. Debian stock (linux-image-amd64) ships binder as a module
      but creates only the 'binder' device by default; we conjure the
      other two by reloading binder_linux with devices=binder,hwbinder,
      vndbinder. We check both before the 500 MB image download."

require_cmd waydroid
ok "waydroid $(waydroid --version)"

# Three possible binder states:
#   loaded         - active in /sys/module, or built-in (binder shows in /proc/filesystems)
#   module-on-disk - .ko file exists for the running kernel, just not loaded yet
#   missing        - neither: kernel was built without binder support at all
binder_state() {
  [[ -d /sys/module/binder_linux ]] && { echo loaded; return; }
  grep -qw binder /proc/filesystems 2>/dev/null && { echo loaded; return; }
  find "/lib/modules/$(uname -r)" -name 'binder_linux.ko*' 2>/dev/null \
    | grep -q . && { echo module-on-disk; return; }
  echo missing
}

case $(binder_state) in
  loaded)
    ok "binder_linux active"
    ;;
  module-on-disk)
    info "binder_linux available but not loaded -- loading now"
    run sudo modprobe binder_linux
    ;;
  missing)
    err "binder_linux is not present in kernel $(uname -r)."
    config=/boot/config-$(uname -r)
    if [[ -r $config ]] && ! grep -q '^CONFIG_ANDROID_BINDER_IPC=[ym]' "$config"; then
      info "confirmed via $config: kernel was built WITHOUT CONFIG_ANDROID_BINDER_IPC."
      info "(Liquorix kernels turn this off; Debian's stock kernel turns it on.)"
    fi
    info "fix options, in order of effort:"
    info "  1. install Debian's stock kernel alongside Liquorix (easy, recommended):"
    info "       sudo apt install linux-image-amd64 && sudo reboot"
    info "     -- ships CONFIG_ANDROID_BINDER_IPC=y. Does NOT remove Liquorix;"
    info "     GRUB keeps both and lets you pick at boot. Run Roblox on stock,"
    info "     Liquorix for everything else."
    info "  2. install an out-of-tree binder DKMS module (anbox-modules-dkms /"
    info "     binder_linux-dkms from third-party repos -- not in Debian main)."
    info "  3. rebuild your current kernel with binder enabled (~30-60 min on a T480,"
    info "     only do this if 1 and 2 are not options):"
    info "       sudo apt install build-essential libssl-dev libelf-dev libncurses-dev \\"
    info "            bc flex bison dwarves zstd fakeroot"
    info "       # Liquorix source: https://liquorix.net/sources/  (or git: zen-kernel/zen-kernel)"
    info "       # Debian source:   apt source linux-image-\$(uname -r)"
    info "       cd <kernel-source>/"
    info "       cp /boot/config-\$(uname -r) .config"
    info "       scripts/config --enable CONFIG_ANDROID_BINDER_IPC \\"
    info "                      --enable CONFIG_ANDROID_BINDERFS"
    info "       make olddefconfig && make -j\$(nproc) bindeb-pkg"
    info "       sudo dpkg -i ../linux-image-*.deb && sudo reboot"
    exit 1
    ;;
esac

# Waydroid expects three separate binder IPC domains: binder (apps),
# hwbinder (hardware HALs), vndbinder (vendor processes). They are three
# different security contexts, not aliases. Most desktop kernels build
# CONFIG_ANDROID_BINDER_DEVICES="binder" (just the one) and disable
# CONFIG_ANDROID_BINDERFS, so hwbinder/vndbinder don't exist out of the
# box. Fix: load binder_linux with devices=binder,hwbinder,vndbinder via
# /etc/modprobe.d/. Built-in binder needs the same value on the kernel
# cmdline instead, since modprobe can't rebind a built-in module.
missing_devs=()
for dev in binder hwbinder vndbinder; do
  [[ -c /dev/$dev ]] || missing_devs+=("$dev")
done

if (( ${#missing_devs[@]} > 0 )); then
  warn "missing binder device(s): ${missing_devs[*]}"
  info "kernel created fewer binder nodes than waydroid needs."

  binder_conf=/boot/config-$(uname -r)
  if [[ -r $binder_conf ]] && grep -q '^CONFIG_ANDROID_BINDER_IPC=y' "$binder_conf"; then
    err "binder is built-in (=y); modprobe cannot rebind it on this kernel."
    info "add this to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub,"
    info "then run 'sudo update-grub && sudo reboot':"
    info "    binder_linux.devices=binder,hwbinder,vndbinder"
    exit 1
  fi

  modprobe_conf=/etc/modprobe.d/waydroid-binder.conf
  info "writing $modprobe_conf and reloading binder_linux."
  if (( dry )); then
    printf '%sDRY%s   echo "options binder_linux devices=binder,hwbinder,vndbinder" | sudo tee %s\n' \
      "$c_dim" "$c_off" "$modprobe_conf"
  else
    echo 'options binder_linux devices=binder,hwbinder,vndbinder' \
      | sudo tee "$modprobe_conf" >/dev/null
  fi
  # rmmod fails with "Device or resource busy" if waydroid-container is up
  # (LXC holds /dev/binder open). Stop it first; safe even if already stopped.
  if systemctl is-active --quiet waydroid-container 2>/dev/null; then
    info "stopping waydroid-container so binder_linux can be unloaded"
    run sudo systemctl stop waydroid-container
  fi
  if ! run sudo rmmod binder_linux; then
    err "rmmod failed -- something else is holding binder_linux."
    info "$modprobe_conf is in place; reboot and the new device list will take effect."
    exit 1
  fi
  run sudo modprobe binder_linux
  if ! (( dry )); then
    for dev in binder hwbinder vndbinder; do
      [[ -c /dev/$dev ]] \
        || { err "/dev/$dev still missing after reload"; exit 1; }
    done
    ok "all three binder devices now present"
  fi
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
  # waydroid init pulls .lzip-compressed system + vendor images and shells
  # out to the external `lzip` binary to decompress them. The Debian
  # waydroid package does not depend on lzip, so init fails partway
  # through ("lzip: not found", leaving /var/lib/waydroid half-populated)
  # unless we install it first.
  if ! command -v lzip >/dev/null; then
    info "lzip missing -- waydroid init needs it to decompress system images"
    if ask "apt install lzip now?"; then
      run sudo apt-get update
      run sudo apt-get install -y lzip
    else
      err "cannot continue without lzip"; exit 1
    fi
  fi
  if ask "run sudo waydroid init -s VANILLA now?"; then
    run sudo waydroid init -s VANILLA
  else
    err "cannot continue without init"; exit 1
  fi
fi

# ---- Step 4: container service ----
section "4/8  waydroid-container.service"
eli5 "A system service runs the Android container manager. We start it
      now but do NOT enable-on-boot: at boot, weston is not running yet,
      so a stale session config referencing /run/user/\$UID/wayland-1
      would make the LXC bind-mount fail. The launcher (rbx) starts
      this service on demand, after weston is up."

if systemctl is-active --quiet waydroid-container; then
  ok "waydroid-container running"
else
  ask "start waydroid-container.service (without enabling on boot)?" \
    && run sudo systemctl start waydroid-container
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

# Roblox is ~150 MB. The uptodown scrape has historically grabbed the
# wrong link (e.g. the 10 MB Uptodown App Store APK) which still passes
# a PK-magic check. Size-gate at 50 MB to reject those impostors.
apk_ok() {
  [[ -s $APK_PATH ]] || return 1
  head -c 4 "$APK_PATH" | grep -q 'PK' || return 1
  local sz
  sz=$(stat -c %s "$APK_PATH")
  (( sz > 50*1024*1024 ))
}

if apk_ok; then
  ok "APK already at $APK_PATH ($(du -h "$APK_PATH" | awk '{print $1}'))"
else
  if [[ -f $APK_PATH ]]; then
    sz=$(du -h "$APK_PATH" | awk '{print $1}')
    warn "$APK_PATH exists but is too small ($sz) -- not the Roblox APK"
    info "removing impostor and re-prompting"
    run rm -f "$APK_PATH"
  fi
  warn "uptodown's HTML scrape has been unreliable -- prefer manual download"
  info "open $UPTODOWN_URL in a browser, save the ~150 MB APK as $APK_PATH, rerun"
  if ask "or try the auto-scrape anyway? (likely to grab wrong APK)"; then
    require_cmd curl
    tmp=$(mktemp)
    curl -fsSL -A 'Mozilla/5.0' "$UPTODOWN_URL" -o "$tmp" || true
    dl=$(grep -oE 'https://dw[^"]+\.apk' "$tmp" | head -1 || true)
    [[ -z $dl ]] && dl=$(grep -oE 'data-url="[^"]+"' "$tmp" | head -1 | sed 's/^data-url="//; s/"$//')
    rm -f "$tmp"
    [[ -n $dl ]] && { info "resolved: $dl"; run curl -fL -A 'Mozilla/5.0' "$dl" -o "$APK_PATH"; }
    apk_ok || { warn "auto-fetch yielded wrong/missing APK. Download manually and rerun."; rm -f "$APK_PATH"; exit 1; }
    ok "APK downloaded"
  else
    exit 0
  fi
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
