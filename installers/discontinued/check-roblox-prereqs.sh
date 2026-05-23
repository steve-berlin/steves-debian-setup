#!/usr/bin/env bash
# check-roblox-prereqs.sh — verify install-roblox.sh can succeed on this box.
# Exits 0 if every hard condition is met, 1 if any FAIL. Soft conditions
# print [WARN] without flipping the exit code.
#
# Mirrors the conditions list in CLAUDE.md so users can run it before the
# 8-step interactive installer instead of bailing partway through.
set -u
P=0; F=0; W=0
ok()   { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; P=$((P+1)); }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; F=$((F+1)); }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; W=$((W+1)); }

# 1. Kernel: must NOT be Liquorix (binder is off there).
kver=$(uname -r)
if [[ $kver == *liquorix* || $kver == *zen* ]]; then
  bad "kernel $kver: Liquorix/Zen builds disable CONFIG_ANDROID_BINDER_IPC."
  bad "  fix: sudo apt install linux-image-amd64 && reboot, pick stock in GRUB."
else
  ok "kernel $kver (not Liquorix/Zen)"
fi

# 2. Binder config: must be =m (modular). =y still works but needs GRUB cmdline edits.
config=/boot/config-$kver
if [[ -r $config ]]; then
  binder_cfg=$(grep -E '^CONFIG_ANDROID_BINDER_IPC=' "$config" | cut -d= -f2)
  case ${binder_cfg:-n} in
    m) ok "CONFIG_ANDROID_BINDER_IPC=m (modular — script can rebind devices)" ;;
    y) warn "CONFIG_ANDROID_BINDER_IPC=y — modprobe can't rebind built-in module."
       warn "  installer will print the GRUB cmdline arg you need to add." ;;
    *) bad "CONFIG_ANDROID_BINDER_IPC not set in $config — kernel lacks binder." ;;
  esac
else
  warn "$config not readable — can't confirm binder config."
fi

# 3. waydroid binary present.
if command -v waydroid >/dev/null 2>&1; then
  ok "waydroid $(waydroid --version 2>/dev/null || echo '?')"
else
  bad "waydroid not on PATH — apt install waydroid (utils.sh handles this)."
fi

# 4. waydroid-container.service stoppable (or already stopped).
if systemctl list-unit-files waydroid-container.service >/dev/null 2>&1; then
  if systemctl is-active --quiet waydroid-container; then
    warn "waydroid-container is running — installer will stop it during step 1."
  else
    ok "waydroid-container.service present and inactive"
  fi
else
  warn "waydroid-container.service not registered — installed by waydroid pkg."
fi

# 5. Network reachable (the script downloads ~500 MB of system image at step 3).
if getent hosts ota.waydro.id >/dev/null 2>&1; then
  ok "DNS resolves ota.waydro.id (image host)"
else
  bad "can't resolve ota.waydro.id — network down or DNS broken."
fi

# 6. sudo available and ideally cached/passwordless (informational).
if sudo -n true 2>/dev/null; then
  ok "sudo available without password prompt"
else
  warn "sudo will prompt for password — installer makes ~10 sudo calls."
fi

# 7. Interactive TTY (or use -y).
if [[ -t 0 ]]; then
  ok "stdin is a TTY (interactive y/N prompts will work)"
else
  warn "stdin is not a TTY — pass -y to install-roblox.sh for unattended."
fi

# 8. Display server: X11 needs weston (handled by step 2), Wayland is native.
session=${XDG_SESSION_TYPE:-x11}
case $session in
  wayland) ok "session: wayland (native)" ;;
  x11)     ok "session: x11 (installer will set up nested weston)" ;;
  *)       warn "session: $session — neither x11 nor wayland, may need manual fix" ;;
esac

printf '\n%d ok, %d warn, %d fail\n' "$P" "$W" "$F"
exit $(( F > 0 ))
