#!/usr/bin/env bash
# utils.sh: step 1 of this repo. Turns a fresh MX/Debian (or Ubuntu) install
# into this box. Everything else in the repo assumes it already ran.
#
# The problem it solves: ~/.zshrc is the settings file your shell reads each
# time you open a terminal. It names many programs: fzf, starship, atuin, nvm,
# pyenv and a dozen more. If they are missing, the shell complains on every
# launch or quietly skips half your setup. This script installs every one of
# them, plus the desktop apps and keyboard shortcuts that make the machine
# feel like yours.
#
# Words to know first:
#   package     a program bundled so the system can install and remove it
#               cleanly. apt is Debian's package installer:
#               `apt-get install zsh` fetches zsh from Debian's servers.
#   repo        (repository) the server apt downloads from. Debian's default
#               repos don't carry everything (Steam needs an extra one), so
#               some steps add repos.
#   tarball     a .tar.gz file: a folder squashed into one file. Go and neovim
#               ship these instead of packages, so the script downloads and
#               unpacks them into your home folder by hand.
#   flatpak     a second, newer way to install desktop apps. Each app carries
#               its own libraries, so it can be much newer than Debian's copy.
#   version manager
#               nvm, pyenv and rbenv do nothing by themselves. They let you
#               install and switch between versions of Node, Python and Ruby
#               per project.
#
# How to run it (flags are explained where they are parsed, below):
#   bash installers/utils.sh              do it
#   bash installers/utils.sh --dry-run    print the plan, change nothing
#   bash installers/utils.sh --help       usage
#
# Safe to run twice. Every step checks first ("is oh-my-zsh already there?
# then skip"), so on a set-up box it does nothing. That is how you top up a
# machine after adding a new tool to the list. The one exception is step 8,
# which overwrites your neovim config every time.
#
# The step numbers matter. check-setup.sh checks the same steps in the same
# order, so a [FAIL] there tells you which step here to re-run. When this
# script finishes, run `bash installers/check-setup.sh`. It prints [OK] or
# [FAIL] per item; exit 0 means the bootstrap is clean.
#
# Exit codes:
#   0      finished (also a finished --dry-run or --uninstall-caveman)
#   2      you passed an argument it doesn't know
#   other  a step failed hard. The script stops at the first real error
#          instead of limping on and leaving the box half-built. Steps that
#          are allowed to fail (a flatpak Flathub lacks today, an optional
#          kernel-tools package) end in `|| true` and at most print a warning.
#
# What it deliberately does NOT do:
#   - remove dash or repoint /bin/sh. That bricked the box once; see step 1d.
#   - install a default Node version. nvm is installed; picking a version is
#     yours. (One exception, in step 10b'.)
#   - change your login shell. Installing zsh and running chsh are separate
#     decisions.
#   - debloat anything beyond the two targeted removals in steps 1c and 1e.
#   - log you in, or touch your tokens. See the closing messages at the end.
#
# Trust: many steps download a vendor's installer script and run it (rustup,
# starship, Brave, NordVPN and others). That is how those tools officially
# ship, so there is no way around it, but it means you trust those vendors.

# Re-exec guard. This script uses bash-only syntax. Run as `sh utils.sh`, dash
# would read it and trip. BASH_VERSION is only set inside bash, so when it is
# empty we restart the same script, with the same arguments, under bash.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# Strict mode. -e: stop at the first command that fails. -u: reading an unset
# variable is an error. pipefail: a pipe fails if any part of it fails, not
# only the last command.
set -euo pipefail

# dry: 1 means --dry-run. Every action prints a "DRY ..." line instead of
# running, and nothing on the box changes.
dry=0
# uninstall_caveman: 1 means --uninstall-caveman. Handled right after the
# helper functions below; the script exits there.
uninstall_caveman=0
# Read the arguments, one at a time:
#   --dry-run             print the plan, touch nothing
#   --uninstall-caveman   remove the caveman Claude Code plugin, then exit at
#                         once. Nothing else runs.
#   -h, --help            print usage, exit 0
#   anything else         error, exit 2
# There is no plain --uninstall. Undoing a bulk bootstrap means guessing which
# of two hundred packages you had before, and the script refuses to guess.
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

# have NAME: true when NAME is a command on PATH.
have() { command -v "$1" >/dev/null 2>&1; }
# apt_has NAME: true when apt has an installable version ("candidate") of NAME.
# `apt-cache madison` prints nothing for an unknown or candidate-less name, so
# "output is not empty" means yes. Its output isn't translated either. That is
# why it is used and not `apt-cache policy`, whose "Candidate:" line comes out
# in the system language on this box.
apt_has() { [ -n "$(apt-cache madison "$1" 2>/dev/null)" ]; }
# run CMD...: in dry-run, print "DRY  CMD" and do nothing. Otherwise run CMD.
# Almost every command that changes the box goes through run or shr.
run() { ((dry)) && printf 'DRY  %s\n' "$*" || "$@"; }
# shr SCRIPT SUMMARY: run the shell string SCRIPT with `bash -c`. In dry-run,
# print only the short SUMMARY. Used for curl|sh installers: printed in full
# they are an unreadable wall of quotes, so the plan shows one line instead.
shr() { ((dry)) && printf 'DRY  %s\n' "$2" || bash -c "$1"; }
# S: the word "sudo" when sudo exists, else empty, so `$S apt-get ...` works
# either way. Unquoted on purpose: an empty $S then vanishes from the command.
S=$(have sudo && echo sudo || echo)

# source_nvm: put nvm's Node on PATH for this script.
# caveman (step 10b') needs node >= 18 for its install and uninstall (npx and
# its bin/install.js). Step 4 installs nvm but no default Node version, so a
# user-installed Node only shows up after loading nvm.sh. nvm.sh reads unset
# variables, which `set -u` would turn into a fatal error, so -u is switched
# off while it loads and back on after. Any error from nvm.sh is ignored.
source_nvm() {
  local nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  if [ -s "$nvm_sh" ]; then set +u; . "$nvm_sh" >/dev/null 2>&1 || true; set -u; fi
}

# --uninstall-caveman: load nvm (npx needs Node), run caveman's own uninstaller
# (strips the plugin and its hooks from ~/.claude), then exit before any
# install step runs. A dedicated flag, because utils.sh has no whole-stack
# teardown.
if ((uninstall_caveman)); then
  source_nvm
  shr "npx -y github:JuliusBrussee/caveman -- --uninstall" \
    "uninstall caveman (npx github:JuliusBrussee/caveman -- --uninstall)"
  echo "[✓] caveman uninstalled"
  exit 0
fi

# 0. Offer to delete installers/discontinued/ (old installers kept only for
#    reference, never on the install path). It asks y/N only at a real
#    terminal (`-t 0`: stdin is a tty). --dry-run and piped runs keep it.
#    Dead code today: that folder was deleted in baaa81c, so the `-d` test
#    below is never true and nothing happens. Harmless; it re-arms if the
#    folder ever comes back.
#    disc: full path of installers/discontinued, worked out from where this
#    script lives, so it works from any current directory.
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

# 1. The big apt install. First refresh apt's list of what is available, then
#    install one long list: zsh git curl tmux fzf, compilers (build-essential)
#    and the libraries Ruby needs to build (autoconf ... uuid-dev), media
#    tools (mpv, playerctl), desktop bits (copyq, flameshot), and the
#    document readers: zathura for PDF and DjVu, mupdf for EPUB/XPS/CBZ.
#    --no-install-recommends: install what each package needs, not the extras
#    it merely recommends.
#    One bad name kills the whole line. apt exits non-zero, set -e stops the
#    script, and nothing in step 1 installs. Two rules follow:
#    - No zathura mupdf plugin here. Neither zathura-pdf-mupdf nor
#      zathura-mupdf exists on trixie: Debian dropped the plugin and kept the
#      engine. So zathura-pdf-poppler + zathura-djvu handle PDF/DjVu inside
#      zathura, and the separate `mupdf` viewer handles EPUB. Two readers is
#      the price of the missing plugin.
#    - Names that differ per distro or release go in step 1a, not here.
run $S apt-get update -y
run $S apt-get install -y --no-install-recommends \
  zsh git curl wget unzip ca-certificates build-essential python3 python3-pip fzf tmux \
  autoconf bison libssl-dev libreadline-dev zlib1g-dev libyaml-dev libncurses-dev \
  libffi-dev libgdbm-dev libdb-dev uuid-dev \
  power-profiles-daemon default-jre gamemode ncurses-term \
  copyq flameshot mpv rename playerctl cryptsetup flatpak \
  xsel xfconf wmctrl gh exiftool btop ncdu \
  zathura zathura-pdf-poppler zathura-djvu mupdf
#    Kernel tools (perf, and cpupower on Ubuntu): try the linux-tools package
#    for the running kernel (`uname -r`), else Debian's linux-perf. Both may
#    be missing (no linux-tools package matches a Liquorix kernel). Errors are
#    hidden and `|| true` makes that a skip, not a failure.
run $S apt-get install -y --no-install-recommends "linux-tools-$(uname -r)" 2>/dev/null ||
  run $S apt-get install -y --no-install-recommends linux-perf 2>/dev/null || true

# 1a. Packages whose name or availability differs between distros and
#     releases. They stay off the step-1 line on purpose: one name with no
#     candidate (no installable version) fails that whole `apt-get install`,
#     set -e stops the script, and nothing in step 1 lands. Here each one is
#     first asked about with apt_has, then installed on its own.
#
#     cpupower: a tool to read and set CPU speed limits. Debian/MX ship it as
#     `linux-cpupower`. Ubuntu has no such package and puts the binary in
#     linux-tools-$(uname -r), which step 1 already tried. So:
#       apt has linux-cpupower          -> install it
#       no package, cpupower on PATH    -> nothing to do (linux-tools gave it)
#       neither                         -> print a warning and carry on
#     Not pinned to the running kernel's version. The tool is
#     backward-compatible, and Liquorix kernels have no matching package.
if apt_has linux-cpupower; then
  run $S apt-get install -y --no-install-recommends linux-cpupower
elif ! have cpupower; then
  echo "[!] cpupower unavailable — no linux-cpupower package and linux-tools didn't provide it" >&2
fi
#     easyeffects: a sound-effects app (equalizer, auto volume and so on). The
#     app is only a frame. The effects themselves are plugins in other
#     packages. Debian's build only *Recommends* those plugins, so with
#     --no-install-recommends you would get an EasyEffects with no effects.
#     So the plugins are named here: lsp-plugins-lv2, mda-lv2, zam-plugins.
#     MX's build already Depends on them, so naming them there is a no-op.
#     lsp-plugins-lv2 is the pick from the "lsp or calf" choice because calf
#     drags in GTK2.
#     No easyeffects in apt -> warn and skip. Step 15's presets need it.
if apt_has easyeffects; then
  run $S apt-get install -y --no-install-recommends \
    easyeffects lsp-plugins-lv2 mda-lv2 zam-plugins
else
  echo "[!] easyeffects unavailable in apt — skipped (step 15 presets need it)" >&2
fi
#     alacritty: the terminal app (autostarts/ starts it at login). Not every
#     release's repos carry it. Bookworm-based MX 23 has none, and apt would
#     fail with "E: Package 'alacritty' has no installation candidate".
#       apt has alacritty               -> install it
#       no package, alacritty on PATH   -> nothing to do (an earlier build)
#       neither                         -> install the build tools now, and
#                                          compile it in step 4b, once rustup
#                                          from step 4 exists
#     build_alacritty: 0 = nothing to build, 1 = step 4b builds from source.
build_alacritty=0
if apt_has alacritty; then
  run $S apt-get install -y --no-install-recommends alacritty
elif ! have alacritty; then
  build_alacritty=1
  # Build deps per alacritty's INSTALL.md (Debian section): cmake, g++ and
  # pkg-config to compile, plus the font and X11 keyboard libraries it links.
  run $S apt-get install -y --no-install-recommends \
    cmake g++ pkg-config libfreetype-dev libfontconfig1-dev \
    libxcb-xfixes0-dev libxkbcommon-dev python3
fi

# 1b. Steam. Steam is 32-bit, so first tell dpkg that 32-bit (i386) packages
#     are allowed at all, then refresh apt's list so it sees them. Try
#     `steam-installer`, then the older name `steam`. Steam lives in Debian's
#     contrib/non-free sections. If those aren't enabled, print a warning
#     instead of dying. Best-effort: this step never stops the script.
run $S dpkg --add-architecture i386 2>/dev/null || true
run $S apt-get update -y
run $S apt-get install -y steam-installer 2>/dev/null ||
  run $S apt-get install -y steam 2>/dev/null ||
  echo "[!] steam unavailable — add contrib/non-free to /etc/apt/sources.list" >&2

# 1c. Remove atmel-firmware, carefully. It is firmware for Atmel at76c50x USB
#     802.11b WiFi dongles from around 2004. Some installs pull it in. On an
#     Intel-WiFi laptop it is dead weight, but deleting firmware a real device
#     needs would kill that device's WiFi. So it is purged only when
#     atmel_present (below) finds no such device. Any hit keeps the package
#     and prints a warning. Skipped when the package isn't installed
#     (`^ii` in `dpkg -l` means "installed").
#     atmel_present: true if any of three checks finds an at76c50x device:
#       1. a device is bound to the driver: the driver's sysfs folder has an
#          entry starting with a digit (USB device names look like 1-1:1.0)
#       2. the at76c50x_usb kernel module is loaded (lsmod)
#       3. lsusb (if installed) lists an at76 or Atmel wireless/802.11 device
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

# 1d. REMOVED. dash stays, and stays as /bin/sh. Do not reintroduce this.
#     An earlier version pointed /bin/sh at zsh and purged dash. That cannot
#     work, and it bricked the box on 2026-08-02. dash OWNS /bin/sh on trixie
#     (dash.prerm carries `remove_divert /bin/sh`). The old claim that
#     `dpkg -S /bin/sh` finds no owner is only true after a failed purge has
#     already truncated dash's file list. What happens, step by step:
#       1. dpkg deletes /bin/sh partway through the purge, including the zsh
#          symlink planted just before.
#       2. dpkg then runs dash.postrm, whose first line is #!/bin/sh.
#       3. There is no /bin/sh any more, so it cannot run: exit 1.
#     Result: dash wedged half-installed, /bin/sh gone, and every #!/bin/sh
#     script on the system dead at once (that includes all of dpkg's own
#     package scripts). set -e kills this script before its "put /bin/sh
#     back" line can run. No ordering of the commands survives, because the
#     delete happens between them, inside dpkg. Recovery:
#       sudo ln -sf /usr/bin/bash /bin/sh
#       sudo apt-get install -y --reinstall dash
#       sudo dpkg --configure -a

# 1e. Remove foliate, a GTK ebook reader. The standalone `mupdf` viewer from
#     step 1 replaces it (keyboard-driven, covers EPUB/XPS/CBZ next to
#     zathura's PDF).
#     Load-bearing: if `mupdf` ever leaves the step-1 apt list, drop this
#     purge in the same commit, or the box is left with no EPUB reader at all.
#     Purge, then `autoremove --purge` to also drop the gjs/webkit libraries
#     foliate pulled in. Nothing else here needs them, and apt only
#     autoremoves packages nothing depends on any more. Skipped when foliate
#     isn't installed, so a re-run does nothing.
if dpkg -l foliate 2>/dev/null | grep -q '^ii'; then
  run $S apt-get purge -y foliate
  run $S apt-get autoremove -y --purge
fi

# 2. oh-my-zsh, a bundle of zsh settings and plugins. Skipped if
#    ~/.oh-my-zsh exists. Its installer comes from GitHub via curl.
#    RUNZSH=no: don't start a zsh when done (that would pause this script).
#    KEEP_ZSHRC=yes: leave the existing ~/.zshrc alone.
[ -d "$HOME/.oh-my-zsh" ] || shr \
  'RUNZSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"' \
  "install oh-my-zsh via curl | sh"
#    P: oh-my-zsh's folder for extra plugins. Clone the two plugins that make
#    zsh pleasant, each skipped if already there: syntax highlighting (colors
#    a command as you type it) and autosuggestions (offers the rest of a
#    command from your history). --depth=1 fetches only the newest commit.
P="$HOME/.oh-my-zsh/custom/plugins"
[ -d "$P/zsh-syntax-highlighting" ] || run git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$P/zsh-syntax-highlighting"
[ -d "$P/zsh-autosuggestions" ] || run git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git "$P/zsh-autosuggestions"

# 3. fzf shell integration. fzf is the fuzzy finder: type part of a name and
#    pick from a filtered list. Its own install script writes ~/.fzf.zsh,
#    which wires fzf's key bindings and tab completion into zsh. Skipped when
#    ~/.fzf.zsh exists. The fzf source is cloned to ~/.fzf first if missing.
#    --no-update-rc: don't edit ~/.zshrc; it is managed elsewhere.
if [ ! -f "$HOME/.fzf.zsh" ]; then
  [ -d "$HOME/.fzf" ] || run git clone --depth=1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
  run "$HOME/.fzf/install" --key-bindings --completion --no-update-rc
fi

# 4. User-level toolchains. They install into your home folder, run as you.
#    Each one is skipped when the file that proves it landed already exists.
#    Most come from the project's own curl|sh installer.
#    rustup, atuin, starship and nvm have no `|| true`: if one of those
#    installers fails, the script stops. deno, bun and pyenv do, so a failure
#    there is skipped quietly.
#    rustup (Rust). Proof: ~/.cargo/env. -y: answer no questions.
#    --no-modify-path: don't edit shell rc files.
[ -f "$HOME/.cargo/env" ] || shr \
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path" \
  "install rustup via curl | sh"
#    rbenv (Ruby) is cloned straight from git, because that is how rbenv
#    ships. ruby-build is the rbenv plugin that compiles Ruby versions.
if [ ! -d "$HOME/.rbenv" ]; then
  run git clone --depth=1 https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
  run git clone --depth=1 https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"
fi
#    atuin (searchable shell history). Skipped if it is on PATH or at its
#    install path ~/.atuin/bin/atuin; a fresh install isn't on PATH until you
#    reopen the shell.
have atuin || [ -x "$HOME/.atuin/bin/atuin" ] || shr \
  "curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh" \
  "install atuin via curl | sh"
#    starship (the prompt: the text before your cursor in the terminal).
have starship || shr "curl -sS https://starship.rs/install.sh | sh -s -- -y" \
  "install starship via curl | sh"
#    nvm (Node version manager), pinned to v0.39.7. PROFILE=/dev/null makes
#    its installer write its "load nvm" lines into nowhere instead of a rc.
[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ] || shr \
  "PROFILE=/dev/null bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'" \
  "install nvm v0.39.7 via curl | bash"
#    deno and bun (JavaScript runtimes), pyenv (Python version manager).
[ -x "$HOME/.deno/bin/deno" ] || shr "curl -fsSL https://deno.land/install.sh | sh -s -- -y || true" \
  "install deno via curl | sh"
[ -x "$HOME/.bun/bin/bun" ] || shr "curl -fsSL https://bun.sh/install | bash || true" \
  "install bun via curl | bash"
[ -d "$HOME/.pyenv" ] || shr "curl -fsSL https://pyenv.run | bash || true" \
  "install pyenv via curl | bash"

# 4b. Build alacritty from source. Runs only when step 1a found no apt
#     package and no alacritty on PATH (build_alacritty=1). It had to wait
#     until here because it needs cargo, Rust's build tool, from step 4.
#     `cargo install` downloads alacritty's source from crates.io (Rust's
#     package site) and compiles it. That takes a few minutes.
#       --locked       use the exact library versions alacritty's authors
#                      tested (its Cargo.lock), not the newest ones
#       --root ~/.local
#                      put the binary in ~/.local/bin. That folder is on the
#                      login PATH (~/.profile adds it), so the autostart's
#                      bare `alacritty` finds it.
#     Full path to cargo: rustup ran with --no-modify-path, so ~/.cargo/bin
#     isn't on this script's PATH yet.
#     Terminfo (the entry that tells programs what this terminal can do)
#     comes from ncurses-term in step 1, so nothing extra is needed for it.
if ((build_alacritty)); then
  run "$HOME/.cargo/bin/cargo" install --locked --root "$HOME/.local" alacritty
  #   A built binary has no menu entry. So write a .desktop file (the small
  #   text file app menus read) to ~/.local/share/applications. Exec= is the
  #   full path, so the menu finds it whatever its PATH is. The EOS marker is
  #   unquoted, so $HOME is filled in when the file is written.
  if ((dry)); then
    echo "DRY  write $HOME/.local/share/applications/Alacritty.desktop"
  else
    mkdir -p "$HOME/.local/share/applications"
    cat >"$HOME/.local/share/applications/Alacritty.desktop" <<EOS
[Desktop Entry]
Type=Application
Name=Alacritty
Comment=A fast, cross-platform, OpenGL terminal emulator
Exec=$HOME/.local/bin/alacritty
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
EOS
  fi
fi

# 5. Go, as a tarball, unpacked to ~/.local/go. Skipped if
#    ~/.local/go/bin/go exists. It asks go.dev what the current version is,
#    instead of hard-coding a number.
if [ ! -x "$HOME/.local/go/bin/go" ]; then
  if ((dry)); then
    echo "DRY  download + extract latest go tarball to $HOME/.local/go"
  else
    #  V: current Go version, e.g. "go1.23.2" (first line of go.dev's answer).
    V=$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)
    #  A: this machine's architecture in Debian's words, e.g. "amd64".
    A=$(dpkg --print-architecture)
    mkdir -p "$HOME/.local"
    #  Download and unpack in one go. The tarball holds a go/ folder, so it
    #  lands as ~/.local/go.
    curl -fsSL "https://go.dev/dl/${V}.linux-${A}.tar.gz" | tar -C "$HOME/.local" -xz
  fi
fi

# 6. Neovim, as a tarball (the latest release), unpacked to ~/.nvim. Skipped
#    if ~/.nvim/bin/nvim exists. The x86_64 file name is fixed, not looked up
#    like Go's architecture. --strip-components=1 drops the tarball's top
#    folder, so the binary lands at ~/.nvim/bin/nvim.
if [ ! -x "$HOME/.nvim/bin/nvim" ]; then
  if ((dry)); then
    echo "DRY  download + extract latest nvim tarball to $HOME/.nvim"
  else
    mkdir -p "$HOME/.nvim"
    curl -fsSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz |
      tar -C "$HOME/.nvim" --strip-components=1 -xz
  fi
fi

# 7. Third-party installers, each skipped if the command exists, each allowed
#    to fail (`|| true`).
#    Brave browser: its vendor install script.
#    Waydroid (runs Android apps on Linux): repo.waydro.id's script adds
#    Waydroid's apt repo. It needs root for that ($S bash), the one vendor
#    script here run as root. Then apt installs waydroid.
have brave-browser || shr "curl -fsS https://dl.brave.com/install.sh | sh || true" \
  "install brave via curl | sh"
have waydroid || shr "{ curl -s https://repo.waydro.id | $S bash && $S apt-get install -y waydroid; } || true" \
  "add waydroid apt repo + apt install waydroid"

# 8. Neovim config (LazyVim starter). WARNING: this step overwrites. It
#    deletes ~/.config/nvim/ and copies the repo's nvim-config/ folder in its
#    place, every run. Every other step skips work already done; this one
#    does not. Hand-edited something in there? Commit it (git stash) or copy
#    it somewhere else first.
#    Delete-then-copy also drops stale files left by an older snapshot.
#    `cp -a src/.` copies the folder's contents, dotfiles included.
#    nvim_src: full path of the repo's nvim-config/ (one level above this
#    script's installers/ folder).
nvim_src="$(cd "$(dirname "$0")/.." && pwd)/nvim-config"
run mkdir -p "$HOME/.config"
run rm -rf "$HOME/.config/nvim"
run cp -a "$nvim_src/." "$HOME/.config/nvim/"

# 9. Python tools via pip: yt-dlp, tldr, platformio. -U upgrades them if
#    present. --user installs into ~/.local. --break-system-packages: Debian
#    marks its Python as "externally managed" and pip refuses to install
#    without this flag. `|| true`: a pip failure doesn't stop the script.
run pip3 install --break-system-packages --user -U yt-dlp tldr platformio || true
# 9b. yewtube, a terminal YouTube client (successor of mps-youtube). Its
#     command is `yt`, not `yewtube`. Kept on its own pip line because it
#     pins httpx<0.28: if that clashes with something, the failure must not
#     take yt-dlp/tldr/platformio down with it. Its player and downloader are
#     already covered (mpv from step 1, yt-dlp from step 9).
run pip3 install --break-system-packages --user -U yewtube || true

# 10. Flatpak apps: Organic Maps, Session, SimpleX Chat, EarTag, Telegram.
#     Only if flatpak exists. First add Flathub (the main flatpak app store)
#     as a source, if not added yet. --user installs into your account, not
#     system-wide. Each app may fail on its own (`|| true`).
#     EarTag comes from Flathub, not Debian's `eartag` (trixie ships 0.6.5;
#     upstream is a GNOME Circle app that moves faster than a Debian release).
#     That also keeps the whole app set on one update path. Telegram is here
#     for the same reason: Debian's `telegram-desktop` trails upstream, and
#     the server enforces a minimum client version, so a stale build
#     eventually refuses to connect.
if have flatpak; then
  run flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  run flatpak install --user -y flathub app.organicmaps.desktop || true
  run flatpak install --user -y flathub network.loki.Session || true
  run flatpak install --user -y flathub chat.simplex.simplex || true
  run flatpak install --user -y flathub app.drey.EarTag || true
  run flatpak install --user -y flathub org.telegram.desktop || true
fi

# 10b. Claude Code, via its own installer. Skipped if `claude` exists.
have claude || shr "curl -fsSL https://claude.ai/install.sh | bash || true" \
  "install claude via curl | bash"

# 10b'. caveman: a Claude Code plugin that shrinks Claude's token use
#       (JuliusBrussee/caveman). Its installer wires the plugin, hooks and
#       statusline into ~/.claude and drops a flag file,
#       ~/.claude/.caveman-active. That file is the "already installed?"
#       test, because a plugin is not a command on PATH that `have` could
#       find. Remove it with `utils.sh --uninstall-caveman`.
#       It needs node >= 18. source_nvm puts nvm's Node on PATH. If there is
#       still no node, `nvm install --lts` installs the long-term-support
#       release. This is the one place utils.sh installs a Node version.
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

# 10c. NordVPN, via its vendor installer. Skipped if `nordvpn` exists.
#      Then, if the `nordvpn` group exists, add you to it (usermod -aG).
#      Group membership only takes effect after you log out and back in.
have nordvpn || shr "curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh | sh || true" \
  "install nordvpn via curl | sh"
getent group nordvpn >/dev/null 2>&1 && run $S usermod -aG nordvpn "$USER" || true

# 11. tmux prefix. The prefix is tmux's "attention key", pressed before
#     every tmux command. This changes it from Ctrl-b to Ctrl-a.
#     T: the tmux config file.
#     If T already has a `set -g prefix C-a` line, nothing happens.
#     Otherwise: delete any old prefix lines (sed -i.bak keeps the old file
#     as ~/.tmux.conf.bak), then append three lines: unbind C-b,
#     set -g prefix C-a, bind C-a send-prefix (press Ctrl-a twice to send a
#     real Ctrl-a to the program inside).
#     If T is a symlink (on this box it points into steves-cli-setup), the
#     file belongs to another repo. `sed -i` writes a brand-new file, which
#     would replace the symlink with a plain copy. So for a symlink it only
#     warns and leaves the file alone; set the prefix in that repo instead.
T="$HOME/.tmux.conf"
if ! grep -qE '^\s*set\s+-g\s+prefix\s+C-a' "$T" 2>/dev/null; then
  if [ -L "$T" ]; then
    echo "[!] $T is a symlink ($(readlink "$T")) — not rewriting; set prefix C-a there" >&2
  elif ((dry)); then
    echo "DRY  rewrite $T to set tmux prefix = C-a"
  else
    if [ -f "$T" ]; then
      sed -i.bak -E '/^\s*(set\s+-g\s+prefix|unbind\s+C-b|bind\s+C-a\s+send-prefix)\b/d' "$T"
    fi
    printf '\nunbind C-b\nset -g prefix C-a\nbind C-a send-prefix\n' >>"$T"
  fi
fi

# 12. Two small helper scripts, written into ~/.local/bin/ and made
#     executable. Rewritten every run. The 'EOS' marker is quoted, so the
#     text is written exactly as shown; nothing in it is expanded.
#     clear-clipboard: wipes the clipboard (xsel -bc), the mouse-selection
#     buffer (xsel -pc) and CopyQ's whole history (copyq removeall). Each
#     part runs only if its tool exists. Always exits 0.
#     focus-nth N: jump to the Nth window on screen. wmctrl -lG lists windows
#     with their positions. Windows on desktop -1 (sticky ones, like panels)
#     are dropped. The rest are sorted top-to-bottom, then left-to-right, and
#     the Nth one is activated. Does nothing if wmctrl is missing.
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

# 13. XFCE keyboard shortcuts (Super = the Windows key). Only if
#     xfconf-query, XFCE's settings tool, exists. Each may fail on its own.
#     X: the shared start of every command. --create makes the setting if it
#     doesn't exist yet; -t string says its value is text.
#       Super+Page_Up     maximize window
#       Super+Page_Down   hide (minimize) window
#       Super+K           power off (systemctl poweroff)
#       Super+L           log out
#       Super+C           clear-clipboard (step 12)
#       Print             screenshot (flameshot gui)
#       Super+1 .. 9      focus-nth 1 .. 9 (step 12)
#     XFCE's default Print binding is removed (-r), so flameshot owns Print.
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

# 13b. KDE keyboard shortcuts (Meta = the Windows key). Only if KDE's config
#      writer exists (kwriteconfig6 for Plasma 6, else kwriteconfig5).
#      Fewer than XFCE: no Super+C, Print or Super+1..9 here.
#      KW: path of whichever kwriteconfig was found.
#      KGS: KDE's global shortcuts file.
if have kwriteconfig6 || have kwriteconfig5; then
  KW=$(command -v kwriteconfig6 || command -v kwriteconfig5)
  KGS=kglobalshortcutsrc
  # Value format: "<active>,<default>,<displayname>".
  #   Meta+K   shut down, no confirmation dialog
  #   Meta+L   log out (KDE's own default for it stays Ctrl+Alt+Del)
  #   Lock Session is set to "none": Meta+L is KDE's default lock key, and it
  #   is now taken by log out.
  #   kxkbrc Layout Options grp:win_space_toggle: Win+Space switches the
  #   keyboard layout. ResetOldOptions=true clears old layout options first.
  run "$KW" --file "$KGS" --group ksmserver --key "Halt Without Confirmation" "Meta+K,none,Shut Down"
  run "$KW" --file "$KGS" --group ksmserver --key "Log Out" "Meta+L,Ctrl+Alt+Del,Log Out"
  run "$KW" --file "$KGS" --group ksmserver --key "Lock Session" "none,Meta+L,Lock Session"
  run "$KW" --file kxkbrc --group Layout --key Options "grp:win_space_toggle"
  run "$KW" --file kxkbrc --group Layout --key ResetOldOptions true
fi

# 14. Debloat: nothing here any more. It moved to debloat_scripts/, which is
#     opt-in. Run as needed:
#       bash debloat_scripts/debloat-mx.sh
#       bash debloat_scripts/debloat-nvidia.sh   # iGPU-only laptops

# Closing messages. Nothing here logs you in. It reminds you to run
# `claude login` and `nordvpn login` yourself, and to log out and back in so
# the nordvpn group (step 10c) applies.
# ~/wallchange.py is a script ~/.zshrc calls. This repo doesn't ship it, so
# only warn when it is missing.
[ -f "$HOME/wallchange.py" ] || echo "[!] ~/wallchange.py missing (referenced by .zshrc)" >&2
echo "[✓] done — run 'claude login' and 'nordvpn login'; log out/in for nordvpn group"
# Token reminder. It only prints advice; it reads and changes no token.
# Credentials belong in a tool's own store, not a shell rc. ~/.zshrc is a
# symlink into steves-cli-setup, so a token pasted there is one `git commit -a`
# from GitHub; ~/.zshrc.local is untracked but still world-readable plaintext.
# check-setup.sh step 17 turns this reminder into a real check.
echo "[!] no API tokens in ~/.zshrc or ~/.zshrc.local — \`gh auth login\` stores"
echo "    GitHub creds in ~/.config/gh/hosts.yml (0600); \`claude login\` its own."
echo "    check: grep -nE '_TOKEN=|_KEY=' ~/.zshrc.local ~/.zshrc"
echo "[i] next: bash debloat_scripts/debloat-mx.sh && bash debloat_scripts/debloat-nvidia.sh"

# 15. EasyEffects presets: ready-made equalizer profiles from
#     JackHack96/EasyEffects-Presets, via its installer. Runs every time (no
#     "already there?" check). It runs after the "done" message above, so a
#     failure here (no network, the upstream script changed) must not turn
#     the whole run into a failure: it only prints a warning, and the script
#     still exits 0. check-setup.sh step 16 tells you if presets are missing.
shr "bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/JackHack96/EasyEffects-Presets/master/install.sh)\"" \
  "install EasyEffects presets via curl | bash" \
  || echo "[!] EasyEffects presets install failed — re-run step 15 by hand" >&2
