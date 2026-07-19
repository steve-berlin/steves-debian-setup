#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh check-setup.sh` — uses `[[` and `${var,,}`.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# Verify install-deps.sh ran successfully. Exit 0 if all OK, 1 if any FAIL.
set -u
P=0; F=0
ok()  { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; P=$((P+1)); }
bad() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; F=$((F+1)); }
have(){ command -v "$1" >/dev/null 2>&1; }
pkg() { dpkg -s "$1" >/dev/null 2>&1; }
cf()  { [ -e "$1" ] && ok "file $1" || bad "file $1 missing"; }
cd_() { [ -d "$1" ] && ok "dir  $1" || bad "dir  $1 missing"; }
cp_() { pkg "$1"    && ok "pkg  $1" || bad "pkg  $1 not installed"; }
np()  { pkg "$1"    && bad "pkg  $1 still installed" || ok "pkg  $1 removed"; }
cbin(){ have "$1"   && ok "bin  $1" || bad "bin  $1 not in PATH"; }

# 1. apt packages
for p in zsh git curl fzf tmux power-profiles-daemon gamemode copyq flameshot mpv playerctl \
         easyeffects alacritty cryptsetup flatpak xsel xfconf wmctrl btop ncdu \
         zathura zathura-pdf-mupdf zathura-djvu; do cp_ "$p"; done

# 1c. atmel-firmware — purged unless an at76c50x device is present (utils.sh 1c).
if [ -d /sys/bus/usb/drivers/at76c50x_usb ] && ls /sys/bus/usb/drivers/at76c50x_usb 2>/dev/null | grep -qE '^[0-9]'; then
  pkg atmel-firmware && ok "atmel-firmware kept (at76 device present)" \
    || bad "atmel-firmware missing but an at76 device is present"
else
  np atmel-firmware
fi

# 1d. dash purged + /bin/sh repointed to zsh (utils.sh 1d).
np dash
sh_tgt=$(readlink -f /bin/sh 2>/dev/null || true)
case "$sh_tgt" in
  */zsh) ok "/bin/sh -> $sh_tgt" ;;
  *)     bad "/bin/sh -> '$sh_tgt' (want zsh)" ;;
esac

# 2. oh-my-zsh + plugins
cd_ "$HOME/.oh-my-zsh"
cd_ "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"
cd_ "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"

# 3. fzf integration
cf "$HOME/.fzf.zsh"

# 4. user toolchains
cf "$HOME/.cargo/env"
cd_ "$HOME/.rbenv"
{ have atuin || [ -x "$HOME/.atuin/bin/atuin" ]; } && ok "atuin"    || bad "atuin missing"
have starship                                      && ok "starship" || bad "starship missing"
cf "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
cf "$HOME/.deno/bin/deno"
cf "$HOME/.bun/bin/bun"
cd_ "$HOME/.pyenv"

# 5. go + neovim tarball
cf "$HOME/.local/go/bin/go"
cf "$HOME/.nvim/bin/nvim"

# 6. third-party apps
have brave-browser && ok "brave"    || bad "brave missing"
have waydroid      && ok "waydroid" || bad "waydroid missing"

# 7. LazyVim + app repos — utils.sh step 8 is commented out; skip the checks.

# 8. pip tools
for p in yt-dlp tldr platformio; do cbin "$p"; done

# 9. flatpak + Organic Maps
have flatpak && flatpak info --user app.organicmaps.desktop >/dev/null 2>&1 \
  && ok "flatpak Organic Maps" || bad "flatpak Organic Maps missing"
have flatpak && flatpak info --user network.loki.Session >/dev/null 2>&1 \
  && ok "flatpak Session" || bad "flatpak Session missing"

# 10. Claude Code + NordVPN
{ have claude || [ -x "$HOME/.local/bin/claude" ]; } && ok "claude" || bad "claude missing"
have nordvpn && ok "nordvpn" || bad "nordvpn missing"
getent group nordvpn 2>/dev/null | grep -q "\b$USER\b" \
  && ok "user in nordvpn group" || bad "user NOT in nordvpn group"

# 11. tmux prefix = C-a. utils.sh writes `prefix C-a`; if install-tmux-omt.sh
#     ran, ~/.tmux.conf is the gpakosz symlink which binds C-a as `prefix2`.
#     Accept either (follows the symlink).
grep -qE '^\s*set\s+-g\s+prefix2?\s+C-a' "$HOME/.tmux.conf" 2>/dev/null \
  && ok "tmux prefix = C-a" || bad "tmux prefix not set to C-a"

# 12. helper scripts
for f in "$HOME/.local/bin/clear-clipboard" "$HOME/.local/bin/focus-nth"; do
  [ -x "$f" ] && ok "exec $f" || bad "exec $f missing/not-executable"
done

# 13. XFCE keybindings — only check on an XFCE session (utils.sh skips
#     them otherwise via `have xfconf-query`).
sess=${XDG_CURRENT_DESKTOP:-}
if have xfwm4 && have xfconf-query && [[ ${sess,,} == *xfce* ]]; then
  xk() {
    local got; got=$(xfconf-query -c xfce4-keyboard-shortcuts -p "$1" 2>/dev/null || true)
    [ "$got" = "$2" ] && ok "xfce $1" || bad "xfce $1 = '$got' (want '$2')"
  }
  xk '/xfwm4/custom/<Super>Page_Up'   'maximize_window_key'
  xk '/xfwm4/custom/<Super>Page_Down' 'hide_window_key'
  xk '/commands/custom/<Super>k'      'systemctl poweroff'
  xk '/commands/custom/<Super>l'      'xfce4-session-logout --logout'
  xk '/commands/custom/<Super>c'      "$HOME/.local/bin/clear-clipboard"
  xk '/commands/custom/Print'         'flameshot gui'
  for i in 1 2 3 4 5 6 7 8 9; do
    xk "/commands/custom/<Super>$i" "$HOME/.local/bin/focus-nth $i"
  done
fi

# 13b. KDE keybindings — mirrors utils.sh step 13b. Only check on a KDE
#      session (kreadconfig6/5 fall back through gracefully if unavailable).
if [[ ${sess,,} == *kde* ]] && { have kreadconfig6 || have kreadconfig5; }; then
  KR=$(command -v kreadconfig6 || command -v kreadconfig5)
  KGS=kglobalshortcutsrc
  kk() {
    # kk <file> <group> <key> <want-prefix> — match by prefix: Plasma rewrites
    # the value as "<active>\t<default>\t<displayname>"; we assert <active>.
    local got; got=$("$KR" --file "$1" --group "$2" --key "$3" 2>/dev/null || true)
    case "$got" in
      "$4"*) ok "kde $1[$2][$3] starts with '$4'" ;;
      *)     bad "kde $1[$2][$3] = '$got' (want prefix '$4')" ;;
    esac
  }
  kk "$KGS"  ksmserver "Halt Without Confirmation" "Meta+K"
  kk "$KGS"  ksmserver "Log Out"                   "Meta+L"
  kk  kxkbrc Layout    Options                     "grp:win_space_toggle"
fi

# 14. debloat — should be GONE
for p in gimp mx-packageinstaller lo-main-helper strawberry gmtp deb-installer vlc \
         xserver-xorg-video-nouveau; do np "$p"; done
dpkg -l 'nvidia-*' 2>/dev/null | grep -q '^ii' \
  && bad "nvidia-* packages still installed" || ok "no nvidia-* packages"

# 15. nouveau blacklist + active GPU
cf /etc/modprobe.d/blacklist-nouveau.conf
lsmod | grep -qE '^(nvidia|nouveau)' \
  && bad "nvidia/nouveau kernel module loaded (reboot pending?)" \
  || ok "nvidia/nouveau not in kernel"
if have glxinfo; then
  r=$(glxinfo 2>/dev/null | awk -F': ' '/OpenGL renderer/ {print $2; exit}')
  case "$r" in
    *NVIDIA*|*nouveau*) bad "renderer: $r (not iGPU)" ;;
    '')                 bad "no OpenGL renderer (no X session?)" ;;
    *)                  ok "renderer: $r" ;;
  esac
else
  printf '[--]   glxinfo missing — skipping renderer check (apt install mesa-utils)\n'
fi

echo
printf 'Passed: %d  Failed: %d\n' "$P" "$F"
[ "$F" -eq 0 ]
