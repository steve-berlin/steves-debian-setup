#!/usr/bin/env bash
# Resolve all dependencies referenced by ~/.zshrc on Debian/Ubuntu. Idempotent.
# --dry-run prints actions, mutates nothing.
set -euo pipefail

dry=0
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    -h|--help) echo "Usage: $(basename "$0") [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
run()  { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
S=$(have sudo && echo sudo || echo)

# 1. apt packages
run $S apt-get update -y
run $S apt-get install -y --no-install-recommends \
  zsh git curl wget unzip ca-certificates build-essential python3 python3-pip fzf tmux \
  autoconf bison libssl-dev libreadline-dev zlib1g-dev libyaml-dev libncurses-dev \
  libffi-dev libgdbm-dev libdb-dev uuid-dev \
  tlp linux-cpupower default-jre gamemode \
  copyq flameshot mpv rename playerctl easyeffects alacritty cryptsetup flatpak \
  xsel xfconf wmctrl gh \
  kate
run $S apt-get install -y --no-install-recommends "linux-tools-$(uname -r)" 2>/dev/null ||
  run $S apt-get install -y --no-install-recommends linux-perf 2>/dev/null || true

# 1b. Steam (needs i386 + non-free; best-effort)
run $S dpkg --add-architecture i386 2>/dev/null || true
run $S apt-get update -y
run $S apt-get install -y steam-installer 2>/dev/null || run $S apt-get install -y steam 2>/dev/null ||
  echo "[!] steam unavailable — add contrib/non-free to /etc/apt/sources.list" >&2

# 2. oh-my-zsh + plugins
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  if (( dry )); then
    echo "DRY  install oh-my-zsh via curl | sh (ohmyzsh/ohmyzsh master)"
  else
    RUNZSH=no KEEP_ZSHRC=yes sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  fi
fi
P="$HOME/.oh-my-zsh/custom/plugins"
[ -d "$P/zsh-syntax-highlighting" ] || run git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$P/zsh-syntax-highlighting"
[ -d "$P/zsh-autosuggestions" ]    || run git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git "$P/zsh-autosuggestions"

# 3. fzf shell integration
if [ ! -f "$HOME/.fzf.zsh" ]; then
  [ -d "$HOME/.fzf" ] || run git clone --depth=1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
  run "$HOME/.fzf/install" --key-bindings --completion --no-update-rc
fi

# 4. user-level toolchains
if [ ! -f "$HOME/.cargo/env" ]; then
  if (( dry )); then echo "DRY  install rustup via curl | sh (sh.rustup.rs)"
  else curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  fi
fi
if [ ! -d "$HOME/.rbenv" ]; then
  run git clone --depth=1 https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
  run git clone --depth=1 https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"
fi
if ! have atuin && [ ! -x "$HOME/.atuin/bin/atuin" ]; then
  if (( dry )); then echo "DRY  install atuin via curl | sh (setup.atuin.sh)"
  else curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
  fi
fi
if ! have starship; then
  if (( dry )); then echo "DRY  install starship via curl | sh (starship.rs)"
  else curl -sS https://starship.rs/install.sh | sh -s -- -y
  fi
fi
if [ ! -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
  if (( dry )); then echo "DRY  install nvm v0.39.7 via curl | bash (nvm-sh/nvm)"
  else PROFILE=/dev/null bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
  fi
fi
if [ ! -x "$HOME/.deno/bin/deno" ]; then
  if (( dry )); then echo "DRY  install deno via curl | sh (deno.land)"
  else curl -fsSL https://deno.land/install.sh | sh -s -- -y || true
  fi
fi
if [ ! -x "$HOME/.bun/bin/bun" ]; then
  if (( dry )); then echo "DRY  install bun via curl | bash (bun.sh)"
  else curl -fsSL https://bun.sh/install | bash || true
  fi
fi
if [ ! -d "$HOME/.pyenv" ]; then
  if (( dry )); then echo "DRY  install pyenv via curl | bash (pyenv.run)"
  else curl -fsSL https://pyenv.run | bash || true
  fi
fi

# 5. go (tarball)
if [ ! -x "$HOME/.local/go/bin/go" ]; then
  if (( dry )); then
    echo "DRY  download + extract latest go tarball to $HOME/.local/go"
  else
    V=$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)
    A=$(dpkg --print-architecture)
    mkdir -p "$HOME/.local"
    curl -fsSL "https://go.dev/dl/${V}.linux-${A}.tar.gz" | tar -C "$HOME/.local" -xz
  fi
fi

# 6. neovim
if [ ! -x "$HOME/.nvim/bin/nvim" ]; then
  if (( dry )); then
    echo "DRY  download + extract latest nvim tarball to $HOME/.nvim"
  else
    mkdir -p "$HOME/.nvim"
    curl -fsSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz |
      tar -C "$HOME/.nvim" --strip-components=1 -xz
  fi
fi

# 7. third-party installers (brave, waydroid)
if ! have brave-browser; then
  if (( dry )); then echo "DRY  install brave via curl | sh (dl.brave.com)"
  else curl -fsS https://dl.brave.com/install.sh | sh || true
  fi
fi
if ! have waydroid; then
  if (( dry )); then echo "DRY  add waydroid apt repo (repo.waydro.id) + apt install waydroid"
  else { curl -s https://repo.waydro.id | $S bash && $S apt-get install -y waydroid; } || true
  fi
fi

# 8. LazyVim starter + app repos (wallChange, clockApp)
#[ -d "$HOME/.config/nvim" ] || { git clone --depth=1 https://github.com/LazyVim/starter "$HOME/.config/nvim" && rm -rf "$HOME/.config/nvim/.git"; }
#[ -d "$HOME/wallChange" ] || git clone --depth=1 https://github.com/steve-berlin/wallChange "$HOME/wallChange"
#[ -d "$HOME/clockApp" ]   || git clone --depth=1 https://github.com/steve-berlin/clockApp   "$HOME/clockApp"

# 9. pip tools (yt-dlp, tldr, platformio)
run pip3 install --break-system-packages --user -U yt-dlp tldr platformio || true

# 10. flatpak + Organic Maps
if have flatpak; then
  run flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  run flatpak install --user -y flathub app.organicmaps.desktop || true
fi

# 10b. Claude Code (native installer → ~/.local/bin/claude)
if ! have claude; then
  if (( dry )); then echo "DRY  install claude via curl | bash (claude.ai/install.sh)"
  else curl -fsSL https://claude.ai/install.sh | bash || true
  fi
fi

# 10c. NordVPN (adds apt repo, installs nordvpn, enrolls user in group)
if ! have nordvpn; then
  if (( dry )); then echo "DRY  install nordvpn via curl | sh (downloads.nordcdn.com)"
  else curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh | sh || true
  fi
fi
getent group nordvpn >/dev/null 2>&1 && run $S usermod -aG nordvpn "$USER" || true

# 11. tmux: Ctrl+a prefix
T="$HOME/.tmux.conf"
if ! grep -qE '^\s*set\s+-g\s+prefix\s+C-a' "$T" 2>/dev/null; then
  if (( dry )); then
    echo "DRY  rewrite $T to set tmux prefix = C-a"
  else
    [ -f "$T" ] && sed -i.bak -E '/^\s*(set\s+-g\s+prefix|unbind\s+C-b|bind\s+C-a\s+send-prefix)\b/d' "$T"
    printf '\nunbind C-b\nset -g prefix C-a\nbind C-a send-prefix\n' >>"$T"
  fi
fi

# 12. helper scripts: clear-clipboard (X11 + CopyQ) and focus-nth (wmctrl-based)
if (( dry )); then
  echo "DRY  write $HOME/.local/bin/clear-clipboard + focus-nth (chmod +x)"
else
  mkdir -p "$HOME/.local/bin"
  cat >"$HOME/.local/bin/clear-clipboard" <<'EOS'
#!/usr/bin/env sh
command -v xsel  >/dev/null && { xsel -bc; xsel -pc; } 2>/dev/null
command -v copyq >/dev/null && copyq removeall        2>/dev/null
exit 0
EOS
  cat >"$HOME/.local/bin/focus-nth" <<'EOS'
#!/usr/bin/env sh
# focus-nth N — focus the Nth normal window sorted top-to-bottom, left-to-right
n=${1:-1}
command -v wmctrl >/dev/null || exit 0
id=$(wmctrl -lG | awk '$2 != "-1"' | sort -k4,4n -k3,3n | awk -v n="$n" 'NR==n {print $1}')
[ -n "$id" ] && wmctrl -ia "$id"
EOS
  chmod +x "$HOME/.local/bin/clear-clipboard" "$HOME/.local/bin/focus-nth"
fi

# 13. XFCE keybindings (Super = Win key; via xfconf-query)
if have xfconf-query; then
  X=(xfconf-query -c xfce4-keyboard-shortcuts --create -t string)
  # xfwm4 window actions: Super+PgUp maximize-toggle, Super+PgDn minimize
  run "${X[@]}" -p '/xfwm4/custom/<Super>Page_Up' -s 'maximize_window_key' || true
  run "${X[@]}" -p '/xfwm4/custom/<Super>Page_Down' -s 'hide_window_key' || true
  # custom commands
  run "${X[@]}" -p '/commands/custom/<Super>k' -s 'systemctl poweroff' || true
  run "${X[@]}" -p '/commands/custom/<Super>l' -s 'xfce4-session-logout --logout' || true
  run "${X[@]}" -p '/commands/custom/<Super>c' -s "$HOME/.local/bin/clear-clipboard" || true
  run "${X[@]}" -p '/commands/custom/Print' -s 'flameshot gui' || true
  # clear default Print (xfce4-screenshooter) so flameshot wins
  run xfconf-query -c xfce4-keyboard-shortcuts -p '/commands/default/Print' -r 2>/dev/null || true
  # Super+1..9 = focus Nth window by position (top-to-bottom, left-to-right)
  for i in 1 2 3 4 5 6 7 8 9; do
    run "${X[@]}" -p "/commands/custom/<Super>$i" -s "$HOME/.local/bin/focus-nth $i" || true
  done
fi

# 13b. KDE keybindings (Meta = Win; via kwriteconfig6/5). Mirrors the
#      XFCE bindings above: Meta+K poweroff, Meta+L logout, Meta+Space
#      toggles keyboard layout (xkb option, works once a 2nd layout is
#      added in System Settings → Keyboard → Layouts). No-op if no KDE
#      CLI tools on PATH. Apply needs a re-login or
#      `kquitapp6 kglobalaccel && kglobalaccel6 &`.
if have kwriteconfig6 || have kwriteconfig5; then
  KW=$(command -v kwriteconfig6 || command -v kwriteconfig5)
  KGS=kglobalshortcutsrc
  # ksmserver session actions. Value format: "<active>,<default>,<displayname>".
  # Halt Without Confirmation = poweroff with no dialog (matches XFCE Super+k).
  # Log Out = the standard KDE logout dialog (logout/poweroff/reboot/cancel).
  # Lock Session default is Meta+L; override so Meta+L lands on logout.
  run "$KW" --file "$KGS" --group ksmserver --key "Halt Without Confirmation" "Meta+K,none,Shut Down"
  run "$KW" --file "$KGS" --group ksmserver --key "Log Out"                   "Meta+L,Ctrl+Alt+Del,Log Out"
  run "$KW" --file "$KGS" --group ksmserver --key "Lock Session"              "none,Meta+L,Lock Session"
  # Keyboard layout toggle via xkb option (matches install-lxqt.sh).
  run "$KW" --file kxkbrc --group Layout --key Options          "grp:win_space_toggle"
  run "$KW" --file kxkbrc --group Layout --key ResetOldOptions  true
fi

# 14. debloat — split out into its own script.
#     Run separately:  bash installers/debloat-mx.sh [--intel-only]
#     --intel-only also purges nvidia/nouveau (matches what used to live here).

[ -f "$HOME/wallchange.py" ] || echo "[!] ~/wallchange.py missing (referenced by .zshrc)" >&2
echo "[✓] done — run 'claude login' and 'nordvpn login'; log out/in for nordvpn group"
echo "[!] rotate GH_TOKEN/ANTHROPIC_API_TOKEN in ~/.zshrc; line 2 points at /home/alex"
echo "[i] next: bash installers/debloat-mx.sh --intel-only   # MX debloat + nvidia purge"

# 15. EasyEffects presets
if (( dry )); then
  echo "DRY  install EasyEffects presets via curl | bash (JackHack96/EasyEffects-Presets)"
else
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/JackHack96/EasyEffects-Presets/master/install.sh)"
fi
