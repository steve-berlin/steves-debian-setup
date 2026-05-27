#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh utils.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# Resolve all dependencies referenced by ~/.zshrc on Debian/Ubuntu. Idempotent.
# --dry-run prints actions, mutates nothing.
set -euo pipefail

dry=0
for a in "$@"; do
  case $a in
  --dry-run) dry=1 ;;
  -h | --help)
    echo "Usage: $(basename "$0") [--dry-run]"
    exit 0
    ;;
  *)
    echo "error: unknown arg: $a" >&2
    exit 2
    ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
run() { ((dry)) && printf 'DRY  %s\n' "$*" || "$@"; }
# curl|sh installers are opaque in dry-run; print a short summary instead of
# rendering the whole pipe.
shr() { ((dry)) && printf 'DRY  %s\n' "$2" || bash -c "$1"; }
S=$(have sudo && echo sudo || echo)

# 1. apt packages
run $S apt-get update -y
run $S apt-get install -y --no-install-recommends \
  zsh git curl wget unzip ca-certificates build-essential python3 python3-pip fzf tmux \
  autoconf bison libssl-dev libreadline-dev zlib1g-dev libyaml-dev libncurses-dev \
  libffi-dev libgdbm-dev libdb-dev uuid-dev \
  tlp linux-cpupower default-jre gamemode \
  copyq flameshot mpv rename playerctl easyeffects alacritty cryptsetup flatpak \
  xsel xfconf wmctrl gh exiftool
run $S apt-get install -y --no-install-recommends "linux-tools-$(uname -r)" 2>/dev/null ||
  run $S apt-get install -y --no-install-recommends linux-perf 2>/dev/null || true

# 1b. Steam (needs i386 + non-free; best-effort)
run $S dpkg --add-architecture i386 2>/dev/null || true
run $S apt-get update -y
run $S apt-get install -y steam-installer 2>/dev/null ||
  run $S apt-get install -y steam 2>/dev/null ||
  echo "[!] steam unavailable — add contrib/non-free to /etc/apt/sources.list" >&2

# 2. oh-my-zsh + plugins
[ -d "$HOME/.oh-my-zsh" ] || shr \
  'RUNZSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"' \
  "install oh-my-zsh via curl | sh"
P="$HOME/.oh-my-zsh/custom/plugins"
[ -d "$P/zsh-syntax-highlighting" ] || run git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$P/zsh-syntax-highlighting"
[ -d "$P/zsh-autosuggestions" ] || run git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git "$P/zsh-autosuggestions"

# 3. fzf shell integration
if [ ! -f "$HOME/.fzf.zsh" ]; then
  [ -d "$HOME/.fzf" ] || run git clone --depth=1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
  run "$HOME/.fzf/install" --key-bindings --completion --no-update-rc
fi

# 4. user-level toolchains (each via the upstream curl|sh installer)
[ -f "$HOME/.cargo/env" ] || shr \
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path" \
  "install rustup via curl | sh"
if [ ! -d "$HOME/.rbenv" ]; then
  run git clone --depth=1 https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
  run git clone --depth=1 https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"
fi
have atuin || [ -x "$HOME/.atuin/bin/atuin" ] || shr \
  "curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh" \
  "install atuin via curl | sh"
have starship || shr "curl -sS https://starship.rs/install.sh | sh -s -- -y" \
  "install starship via curl | sh"
[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ] || shr \
  "PROFILE=/dev/null bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'" \
  "install nvm v0.39.7 via curl | bash"
[ -x "$HOME/.deno/bin/deno" ] || shr "curl -fsSL https://deno.land/install.sh | sh -s -- -y || true" \
  "install deno via curl | sh"
[ -x "$HOME/.bun/bin/bun" ] || shr "curl -fsSL https://bun.sh/install | bash || true" \
  "install bun via curl | bash"
[ -d "$HOME/.pyenv" ] || shr "curl -fsSL https://pyenv.run | bash || true" \
  "install pyenv via curl | bash"

# 5. go (tarball)
if [ ! -x "$HOME/.local/go/bin/go" ]; then
  if ((dry)); then
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
  if ((dry)); then
    echo "DRY  download + extract latest nvim tarball to $HOME/.nvim"
  else
    mkdir -p "$HOME/.nvim"
    curl -fsSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz |
      tar -C "$HOME/.nvim" --strip-components=1 -xz
  fi
fi

# 7. third-party installers (brave, waydroid)
have brave-browser || shr "curl -fsS https://dl.brave.com/install.sh | sh || true" \
  "install brave via curl | sh"
have waydroid || shr "{ curl -s https://repo.waydro.id | $S bash && $S apt-get install -y waydroid; } || true" \
  "add waydroid apt repo + apt install waydroid"

# 8. LazyVim starter — sync from vendored nvim-config/. Fresh-install script, so
# we overwrite unconditionally (use `git stash` in ~/.config/nvim/ if you've
# hand-tweaked it and want to keep changes). `cp -a src/.` preserves dotfiles
# (.gitignore, .neoconf.json); rm-then-cp avoids stale files lingering from an
# older vendored snapshot.
nvim_src="$(cd "$(dirname "$0")/.." && pwd)/nvim-config"
run mkdir -p "$HOME/.config"
run rm -rf "$HOME/.config/nvim"
run cp -a "$nvim_src/." "$HOME/.config/nvim/"

# 9. pip tools
run pip3 install --break-system-packages --user -U yt-dlp tldr platformio || true

# 10. flatpak + Organic Maps
if have flatpak; then
  run flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  run flatpak install --user -y flathub app.organicmaps.desktop || true
fi

# 10b. Claude Code
have claude || shr "curl -fsSL https://claude.ai/install.sh | bash || true" \
  "install claude via curl | bash"

# 10c. NordVPN
have nordvpn || shr "curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh | sh || true" \
  "install nordvpn via curl | sh"
getent group nordvpn >/dev/null 2>&1 && run $S usermod -aG nordvpn "$USER" || true

# 11. tmux: Ctrl+a prefix
T="$HOME/.tmux.conf"
if ! grep -qE '^\s*set\s+-g\s+prefix\s+C-a' "$T" 2>/dev/null; then
  if ((dry)); then
    echo "DRY  rewrite $T to set tmux prefix = C-a"
  else
    [ -f "$T" ] && sed -i.bak -E '/^\s*(set\s+-g\s+prefix|unbind\s+C-b|bind\s+C-a\s+send-prefix)\b/d' "$T"
    printf '\nunbind C-b\nset -g prefix C-a\nbind C-a send-prefix\n' >>"$T"
  fi
fi

# 12. helper scripts: clear-clipboard + focus-nth
if ((dry)); then
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

# 13. XFCE keybindings (Super = Win)
if have xfconf-query; then
  X=(xfconf-query -c xfce4-keyboard-shortcuts --create -t string)
  run "${X[@]}" -p '/xfwm4/custom/<Super>Page_Up' -s 'maximize_window_key' || true
  run "${X[@]}" -p '/xfwm4/custom/<Super>Page_Down' -s 'hide_window_key' || true
  run "${X[@]}" -p '/commands/custom/<Super>k' -s 'systemctl poweroff' || true
  run "${X[@]}" -p '/commands/custom/<Super>l' -s 'xfce4-session-logout --logout' || true
  run "${X[@]}" -p '/commands/custom/<Super>c' -s "$HOME/.local/bin/clear-clipboard" || true
  run "${X[@]}" -p '/commands/custom/Print' -s 'flameshot gui' || true
  run xfconf-query -c xfce4-keyboard-shortcuts -p '/commands/default/Print' -r 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9; do
    run "${X[@]}" -p "/commands/custom/<Super>$i" -s "$HOME/.local/bin/focus-nth $i" || true
  done
fi

# 13b. KDE keybindings (Meta = Win)
if have kwriteconfig6 || have kwriteconfig5; then
  KW=$(command -v kwriteconfig6 || command -v kwriteconfig5)
  KGS=kglobalshortcutsrc
  # Value format: "<active>,<default>,<displayname>". Meta+K poweroff, Meta+L logout.
  run "$KW" --file "$KGS" --group ksmserver --key "Halt Without Confirmation" "Meta+K,none,Shut Down"
  run "$KW" --file "$KGS" --group ksmserver --key "Log Out" "Meta+L,Ctrl+Alt+Del,Log Out"
  run "$KW" --file "$KGS" --group ksmserver --key "Lock Session" "none,Meta+L,Lock Session"
  run "$KW" --file kxkbrc --group Layout --key Options "grp:win_space_toggle"
  run "$KW" --file kxkbrc --group Layout --key ResetOldOptions true
fi

# 14. debloat — split out. Run as needed:
#       bash installers/debloat-mx.sh
#       bash installers/debloat-nvidia.sh   # iGPU-only laptops

[ -f "$HOME/wallchange.py" ] || echo "[!] ~/wallchange.py missing (referenced by .zshrc)" >&2
echo "[✓] done — run 'claude login' and 'nordvpn login'; log out/in for nordvpn group"
echo "[!] rotate GH_TOKEN/ANTHROPIC_API_TOKEN in ~/.zshrc; line 2 points at /home/alex"
echo "[i] next: bash installers/debloat-mx.sh && bash installers/debloat-nvidia.sh"

# 15. EasyEffects presets
shr "bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/JackHack96/EasyEffects-Presets/master/install.sh)\"" \
  "install EasyEffects presets via curl | bash"
