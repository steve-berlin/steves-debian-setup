#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh utils.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# Resolve all dependencies referenced by ~/.zshrc on Debian/Ubuntu. Idempotent.
# --dry-run prints actions, mutates nothing.
set -euo pipefail

dry=0
uninstall_caveman=0
for a in "$@"; do
  case $a in
  --dry-run) dry=1 ;;
  --uninstall-caveman) uninstall_caveman=1 ;;
  -h | --help)
    echo "Usage: $(basename "$0") [--dry-run] [--uninstall-caveman]"
    echo "  --uninstall-caveman  remove the caveman Claude Code plugin, then exit"
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

# caveman needs node >= 18 for its install/uninstall (npx / bin/install.js).
# utils.sh installs nvm (step 4) but no default node version, so source nvm to
# put a user-installed node on PATH. Guarded against set -u fallout in nvm.sh.
source_nvm() {
  local nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  if [ -s "$nvm_sh" ]; then set +u; . "$nvm_sh" >/dev/null 2>&1 || true; set -u; fi
}

# --uninstall-caveman: strip the plugin + hooks and bail before the install flow.
if ((uninstall_caveman)); then
  source_nvm
  shr "npx -y github:JuliusBrussee/caveman -- --uninstall" \
    "uninstall caveman (npx github:JuliusBrussee/caveman -- --uninstall)"
  echo "[✓] caveman uninstalled"
  exit 0
fi

# 0. First things first: offer to delete the discontinued installers (kept only
#    for reference, never on the install path). Prompt only on an interactive
#    tty; --dry-run and piped/non-interactive runs keep them.
disc="$(cd "$(dirname "$0")" && pwd)/discontinued"
if [[ -d $disc ]]; then
  if ((dry)); then
    echo "DRY  prompt: delete discontinued installers ($disc)"
  elif [[ -t 0 ]]; then
    read -r -p "Delete discontinued installers in $disc? [y/N] " ans
    if [[ $ans == [yY]* ]]; then
      rm -rf "$disc"
      echo "deleted $disc"
    else echo "kept $disc"; fi
  fi
fi

# 1. apt packages
run $S apt-get update -y
run $S apt-get install -y --no-install-recommends \
  zsh git curl wget unzip ca-certificates build-essential python3 python3-pip fzf tmux \
  autoconf bison libssl-dev libreadline-dev zlib1g-dev libyaml-dev libncurses-dev \
  libffi-dev libgdbm-dev libdb-dev uuid-dev \
  power-profiles-daemon linux-cpupower default-jre gamemode \
  copyq flameshot mpv rename playerctl easyeffects alacritty cryptsetup flatpak \
  xsel xfconf wmctrl gh exiftool btop ncdu \
  zathura zathura-pdf-mupdf zathura-djvu
run $S apt-get install -y --no-install-recommends "linux-tools-$(uname -r)" 2>/dev/null ||
  run $S apt-get install -y --no-install-recommends linux-perf 2>/dev/null || true

# 1b. Steam (needs i386 + non-free; best-effort)
run $S dpkg --add-architecture i386 2>/dev/null || true
run $S apt-get update -y
run $S apt-get install -y steam-installer 2>/dev/null ||
  run $S apt-get install -y steam 2>/dev/null ||
  echo "[!] steam unavailable — add contrib/non-free to /etc/apt/sources.list" >&2

# 1c. atmel-firmware: firmware for Atmel at76c50x USB 802.11b dongles (~2004),
#     pulled in on some installs but dead weight on Intel-wifi boxes. Guard
#     against yanking firmware a real device needs — only purge when no at76
#     device is bound to the driver, the module isn't loaded, and lsusb sees
#     nothing matching. Any hit keeps the package with a warning.
atmel_present() {
  local d=/sys/bus/usb/drivers/at76c50x_usb
  [ -d "$d" ] && ls "$d" 2>/dev/null | grep -qE '^[0-9]' && return 0
  lsmod 2>/dev/null | grep -qi at76c50x_usb && return 0
  have lsusb && lsusb 2>/dev/null | grep -qiE 'at76|atmel.*(wireless|802\.11)' && return 0
  return 1
}
if dpkg -l atmel-firmware 2>/dev/null | grep -q '^ii'; then
  if atmel_present; then
    echo "[!] atmel-firmware kept — an at76c50x device appears present" >&2
  else
    run $S apt-get purge -y atmel-firmware
  fi
fi

# 1d. dash: repoint /bin/sh to zsh, then purge dash. dash is Essential and owns
#     the /bin/sh symlink via debconf (dpkg -S /bin/sh finds no package), so the
#     order is load-bearing: flip the symlink to zsh FIRST — otherwise purge
#     strands /bin/sh — and pass --allow-remove-essential so apt doesn't stop at
#     the interactive "Yes, do as I say!" guard. dash's postrm may drop the
#     symlink, so reassert it afterward. Needs zsh (installed in step 1). Once
#     /bin/sh is zsh and dash is gone, every step below is a no-op (idempotent).
#     NOTE: zsh runs /bin/sh in POSIX emulation — fine for system scripts, but a
#     deliberate, non-default choice; revert with `apt-get install dash` +
#     `dpkg-reconfigure dash`.
if dpkg -l dash 2>/dev/null | grep -q '^ii'; then
  zsh_bin=$(command -v zsh || true)
  if [ -z "$zsh_bin" ]; then
    echo "[!] dash kept — zsh not on PATH for /bin/sh" >&2
  else
    # Silence dash's debconf so a later reconfigure can't re-grab /bin/sh.
    run $S sh -c 'echo "dash dash/sh boolean false" | debconf-set-selections'
    run $S ln -sf "$zsh_bin" /bin/sh
    run $S apt-get purge -y --allow-remove-essential dash
    run $S ln -sf "$zsh_bin" /bin/sh
  fi
fi

# 1e. foliate: GTK ebook reader, superseded by zathura + the mupdf backend from
#     step 1 (one keyboard-driven viewer covering EPUB alongside PDF/XPS/CBZ).
#     Purge + autoremove --purge to also drop the gjs/webkit stack it pulled in;
#     nothing else here depends on those, and the autoremove is scoped by apt to
#     packages left orphaned. Skipped when foliate isn't installed (idempotent).
if dpkg -l foliate 2>/dev/null | grep -q '^ii'; then
  run $S apt-get purge -y foliate
  run $S apt-get autoremove -y --purge
fi

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

# 8. LazyVim starter — overwrite ~/.config/nvim/ from vendored nvim-config/
#    (git-stash there first to keep hand-tweaks). `cp -a src/.` preserves
#    dotfiles; rm-then-cp drops stale files from an older snapshot.
nvim_src="$(cd "$(dirname "$0")/.." && pwd)/nvim-config"
run mkdir -p "$HOME/.config"
run rm -rf "$HOME/.config/nvim"
run cp -a "$nvim_src/." "$HOME/.config/nvim/"

# 9. pip tools
run pip3 install --break-system-packages --user -U yt-dlp tldr platformio || true
# 9b. yewtube — terminal YouTube client (mps-youtube successor). Entry point is
#     `yt`, not `yewtube`. Kept on its own pip line because it pins httpx<0.28:
#     a resolver conflict there must not take yt-dlp/tldr/platformio with it.
#     Player + downloader deps already covered (mpv in step 1, yt-dlp above).
run pip3 install --break-system-packages --user -U yewtube || true

# 10. flatpak + Organic Maps, Session, SimpleX Chat, EarTag
#     EarTag comes from Flathub rather than Debian's `eartag` (trixie ships
#     0.6.5; upstream is a GNOME Circle app that moves faster than a release
#     cycle) — and it keeps the whole app set on one update path.
if have flatpak; then
  run flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  run flatpak install --user -y flathub app.organicmaps.desktop || true
  run flatpak install --user -y flathub network.loki.Session || true
  run flatpak install --user -y flathub chat.simplex.simplex || true
  run flatpak install --user -y flathub app.drey.EarTag || true
fi

# 10b. Claude Code
have claude || shr "curl -fsSL https://claude.ai/install.sh | bash || true" \
  "install claude via curl | bash"

# 10b'. caveman — Claude Code token-compression plugin (JuliusBrussee/caveman).
#       Universal installer wires the plugin + hooks + statusline into ~/.claude
#       and drops a ~/.claude/.caveman-active flag file we use as the idempotency
#       guard. Needs node >= 18 (source_nvm puts nvm's node on PATH; nvm install
#       --lts provides one since utils.sh installs no default node). Remove with
#       `utils.sh --uninstall-caveman`.
source_nvm
if ! have node && have nvm; then
  if ((dry)); then
    echo "DRY  nvm install --lts (no node on PATH for caveman)"
  else
    nvm install --lts >/dev/null 2>&1 || true
  fi
fi
[ -e "$HOME/.claude/.caveman-active" ] || shr \
  "curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash -s -- --non-interactive || true" \
  "install caveman (Claude Code plugin) via curl | bash"

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
