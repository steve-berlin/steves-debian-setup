#!/usr/bin/env bash
# check-setup.sh: grades your machine after utils.sh has run.
#
# Why it exists: utils.sh installs about a hundred things, and some of those
# installs may fail quietly (a flatpak Flathub is having a bad day about, a
# vendor script that moved its URL). So "utils.sh finished" and "the box is
# actually set up" are two different questions. This script answers the
# second one. It walks the same numbered steps as utils.sh, in the same
# order, so a [FAIL] tells you which utils.sh step to re-run.
#
# How to run it:
#   bash installers/check-setup.sh
# That is the whole interface: no flags, no arguments, no --dry-run. It needs
# none, because it never changes anything. Every check is a question (is this
# package installed, does this folder exist, is this command on PATH, is this
# setting set to this value). Run it as often as you like, on any box.
#
# Output: one line per item, then a total. For example:
#   [OK]   pkg  zsh
#   [OK]   dir  /home/fred/.oh-my-zsh
#   [FAIL] bin  yt not in PATH
#   Passed: 78  Failed: 2
#
# The one confusing result: on a box that only ran utils.sh, steps 14 and 15
# FAIL, and that is correct. utils.sh debloats nothing; those checks belong to
# the opt-in debloat_scripts/debloat-mx.sh and debloat-nvidia.sh. If you never
# wanted those, read those failures as "not applicable". The exit code is
# still 1.
#
# Exit codes:
#   0   every check passed
#   1   at least one check failed; the count is on the last line

# Re-exec guard. This script uses bash-only syntax (`[[` and `${var,,}`). Run
# as `sh check-setup.sh`, dash would trip on it. BASH_VERSION is only set
# inside bash, so when it is empty we restart the script under bash.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# Only `set -u` (reading an unset variable is an error), on purpose. The other
# scripts in this repo use `set -euo pipefail`, which aborts at the first
# failing command. Here a failed check is the result, not a script error. With
# -e, the first missing package would end the run and you would never see the
# other ~80 answers. So every check records its verdict and the script goes
# on: one run, the complete picture.
set -u
# P: number of passed checks. F: number of failed checks.
P=0; F=0
# The helpers. Every output line comes from one of them.
#   ok MSG / bad MSG   print a green [OK] or red [FAIL] line (\033[...m are
#                      terminal color codes) and add 1 to P or F
#   have NAME          true when NAME is a command on PATH (prints nothing)
#   pkg NAME           true when dpkg says the apt package NAME is installed
#   cf PATH            does this file exist?         "file PATH"
#   cd_ PATH           does this folder exist?       "dir  PATH"
#   cp_ NAME           is this package installed?    "pkg  NAME"
#   np NAME            is this package GONE?         "pkg  NAME removed"
#   cbin NAME          is this command on PATH?      "bin  NAME"
# np is the odd one out: it PASSES when the package is absent. It is used for
# things utils.sh deliberately removes (foliate, atmel-firmware) and for
# everything the debloat scripts strip. A [FAIL] from np means "this is still
# here and shouldn't be".
ok()  { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; P=$((P+1)); }
bad() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; F=$((F+1)); }
have(){ command -v "$1" >/dev/null 2>&1; }
pkg() { dpkg -s "$1" >/dev/null 2>&1; }
cf()  { [ -e "$1" ] && ok "file $1" || bad "file $1 missing"; }
cd_() { [ -d "$1" ] && ok "dir  $1" || bad "dir  $1 missing"; }
cp_() { pkg "$1"    && ok "pkg  $1" || bad "pkg  $1 not installed"; }
np()  { pkg "$1"    && bad "pkg  $1 still installed" || ok "pkg  $1 removed"; }
cbin(){ have "$1"   && ok "bin  $1" || bad "bin  $1 not in PATH"; }

# 1. The apt packages from utils.sh's big install line (a subset of it): zsh,
#    git, curl, fzf, tmux, mpv, the zathura/mupdf reader stack and the rest.
for p in zsh git curl fzf tmux power-profiles-daemon gamemode copyq flameshot mpv playerctl \
         ncurses-term cryptsetup flatpak xsel xfconf wmctrl btop ncdu \
         zathura zathura-pdf-poppler zathura-djvu mupdf; do cp_ "$p"; done

# 1a. The distro-dependent installs (utils.sh steps 1a and 4b).
#     cpupower and alacritty are checked as commands on PATH (cbin), not as
#     packages (cp_). The package may legitimately be missing while the tool
#     is there:
#       cpupower    on Ubuntu it comes inside linux-tools-$(uname -r), not
#                   from a linux-cpupower package
#       alacritty   may be a cargo build in ~/.local/bin (utils.sh step 4b)
#     easyeffects and its three effect-plugin packages are checked as
#     packages: utils.sh only installs them from apt. Without the plugins,
#     EasyEffects has no effects to apply.
cbin cpupower
cbin alacritty
for p in easyeffects lsp-plugins-lv2 mda-lv2 zam-plugins; do cp_ "$p"; done

# 1c. atmel-firmware: firmware for at76c50x USB WiFi dongles. utils.sh purges
#     it unless such a device is present. If one is bound to the driver (its
#     sysfs folder has an entry starting with a digit), the package is
#     supposed to STAY, so the check flips: present is [OK], missing is
#     [FAIL]. On a normal laptop there is no such device, so it just checks
#     the package is gone.
#     Only that one sysfs test is used here. utils.sh also checks lsmod and
#     lsusb, so a device found only by those would make utils.sh keep the
#     package while this reports [FAIL] "still installed".
if [ -d /sys/bus/usb/drivers/at76c50x_usb ] && ls /sys/bus/usb/drivers/at76c50x_usb 2>/dev/null | grep -qE '^[0-9]'; then
  pkg atmel-firmware && ok "atmel-firmware kept (at76 device present)" \
    || bad "atmel-firmware missing but an at76 device is present"
else
  np atmel-firmware
fi

# 1d. Removed. utils.sh no longer touches dash or /bin/sh, so there is
#     nothing to check.

# 1e. foliate is gone (utils.sh 1e purges it; mupdf covers EPUB).
np foliate

# 2. oh-my-zsh and its two plugins (syntax highlighting, autosuggestions).
cd_ "$HOME/.oh-my-zsh"
cd_ "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"
cd_ "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"

# 3. fzf's shell integration file.
cf "$HOME/.fzf.zsh"

# 4. Each toolchain, checked by the file that proves it landed:
#    ~/.cargo/env for Rust, the ~/.rbenv folder, nvm.sh, the deno and bun
#    binaries, the ~/.pyenv folder. atuin passes if it is on PATH OR at its
#    install path ~/.atuin/bin/atuin, because a fresh install isn't on PATH
#    until you reopen the shell. starship is checked on PATH only.
cf "$HOME/.cargo/env"
cd_ "$HOME/.rbenv"
{ have atuin || [ -x "$HOME/.atuin/bin/atuin" ]; } && ok "atuin"    || bad "atuin missing"
have starship                                      && ok "starship" || bad "starship missing"
cf "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
cf "$HOME/.deno/bin/deno"
cf "$HOME/.bun/bin/bun"
cd_ "$HOME/.pyenv"

# 5. The Go and neovim tarballs, unpacked into ~/.local/go and ~/.nvim
#    (utils.sh steps 5 and 6).
cf "$HOME/.local/go/bin/go"
cf "$HOME/.nvim/bin/nvim"

# 6. Brave and Waydroid, on PATH (utils.sh step 7).
have brave-browser && ok "brave"    || bad "brave missing"
have waydroid      && ok "waydroid" || bad "waydroid missing"

# 7. The neovim config seeded from the repo's nvim-config/ (utils.sh step 8).
#    It looks for two files, init.lua and lazy-lock.json, not just the folder.
#    Step 8 deletes ~/.config/nvim and copies the repo copy in, so a folder
#    that exists but lacks the lockfile means the copy died halfway.
cf "$HOME/.config/nvim/init.lua"
cf "$HOME/.config/nvim/lazy-lock.json"

# 8. The pip tools: yt-dlp, tldr, platformio, and yt. `yt` is yewtube's
#    command name (utils.sh step 9b). A check for a command called `yewtube`
#    would fail forever; there isn't one.
for p in yt-dlp tldr platformio yt; do cbin "$p"; done

# 9. Each flatpak: Organic Maps, Session, SimpleX Chat, EarTag, Telegram.
#    Asked for by its full app ID (app.drey.EarTag and so on) with
#    `flatpak info --user`. The --user matters: utils.sh installs them into
#    your account, and a system-wide query wouldn't see them. No flatpak
#    command at all counts as a FAIL for every app.
have flatpak && flatpak info --user app.organicmaps.desktop >/dev/null 2>&1 \
  && ok "flatpak Organic Maps" || bad "flatpak Organic Maps missing"
have flatpak && flatpak info --user network.loki.Session >/dev/null 2>&1 \
  && ok "flatpak Session" || bad "flatpak Session missing"
have flatpak && flatpak info --user chat.simplex.simplex >/dev/null 2>&1 \
  && ok "flatpak SimpleX Chat" || bad "flatpak SimpleX Chat missing"
have flatpak && flatpak info --user app.drey.EarTag >/dev/null 2>&1 \
  && ok "flatpak EarTag" || bad "flatpak EarTag missing"
have flatpak && flatpak info --user org.telegram.desktop >/dev/null 2>&1 \
  && ok "flatpak Telegram" || bad "flatpak Telegram missing"

# 10. Claude Code (on PATH or at ~/.local/bin/claude), NordVPN, and,
#     separately, whether YOU are in the `nordvpn` group. The group check
#     reads the group list (getent) and looks for your user name as a whole
#     word (\b = word edge). It reads the file, not your current session: it
#     passes right after utils.sh adds you, even though the membership only
#     applies once you log out and back in.
{ have claude || [ -x "$HOME/.local/bin/claude" ]; } && ok "claude" || bad "claude missing"
have nordvpn && ok "nordvpn" || bad "nordvpn missing"
getent group nordvpn 2>/dev/null | grep -q "\b$USER\b" \
  && ok "user in nordvpn group" || bad "user NOT in nordvpn group"

# 10b'. The caveman Claude Code plugin (utils.sh step 10b'). Its installer
#       drops the flag file ~/.claude/.caveman-active. It is a plugin, not a
#       program, so there is no command on PATH to look for. utils.sh uses
#       the same flag file to decide whether it already installed it, so it
#       is the right thing to assert here.
cf "$HOME/.claude/.caveman-active"

# 11. ~/.tmux.conf really says `set -g prefix C-a` (utils.sh step 11 writes
#     it). Same pattern utils.sh greps for; spacing may vary.
grep -qE '^\s*set\s+-g\s+prefix\s+C-a' "$HOME/.tmux.conf" 2>/dev/null \
  && ok "tmux prefix = C-a" || bad "tmux prefix not set to C-a"

# 12. Both helper scripts exist AND are executable (-x).
for f in "$HOME/.local/bin/clear-clipboard" "$HOME/.local/bin/focus-nth"; do
  [ -x "$f" ] && ok "exec $f" || bad "exec $f missing/not-executable"
done

# 13 / 13b. The keyboard shortcuts, but only on the desktop they belong to.
#     On the wrong desktop they are skipped entirely, instead of reporting a
#     wall of false failures.
#     sess: the current desktop's name from XDG_CURRENT_DESKTOP (e.g. "XFCE"
#     or "KDE"), empty if unset. `${sess,,}` is the same text in lowercase.
#     13: XFCE shortcuts, checked only when xfwm4 and xfconf-query exist AND
#     this is an XFCE session (utils.sh writes them whenever xfconf-query
#     exists).
sess=${XDG_CURRENT_DESKTOP:-}
if have xfwm4 && have xfconf-query && [[ ${sess,,} == *xfce* ]]; then
  # xk PROPERTY WANT: read the shortcut's stored command and compare it to
  # WANT exactly. A missing setting reads as empty and fails.
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

# 13b. KDE shortcuts (mirrors utils.sh step 13b). Checked only in a KDE
#      session, and only if kreadconfig6 or kreadconfig5 (KDE's config
#      reader) exists. KR: whichever one was found. KGS: KDE's global
#      shortcuts file. Checks Meta+K shut down, Meta+L log out, and the
#      Win+Space layout toggle.
if [[ ${sess,,} == *kde* ]] && { have kreadconfig6 || have kreadconfig5; }; then
  KR=$(command -v kreadconfig6 || command -v kreadconfig5)
  KGS=kglobalshortcutsrc
  kk() {
    # kk <file> <group> <key> <want-prefix>. Compares by PREFIX, not exact
    # match, on purpose. Plasma rewrites the stored value into three
    # tab-separated fields, "<active>\t<default>\t<displayname>" (the active
    # key, the default key, the display name). We assert only that <active>
    # comes first and ignore whatever Plasma appended.
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

# 14. Debloat results: these should be GONE. GIMP, the MX-bundled tools
#     (mx-packageinstaller, lo-main-helper, deb-installer), strawberry, gmtp,
#     VLC, the nouveau X driver, and every installed nvidia-* package (`^ii`
#     in `dpkg -l` means "installed"). Fails by design on a box that never
#     ran debloat_scripts/ (see the header).
for p in gimp mx-packageinstaller lo-main-helper strawberry gmtp deb-installer vlc \
         xserver-xorg-video-nouveau; do np "$p"; done
dpkg -l 'nvidia-*' 2>/dev/null | grep -q '^ii' \
  && bad "nvidia-* packages still installed" || ok "no nvidia-* packages"

# 15. GPU state after debloat-nvidia.sh:
#     - the nouveau blacklist file exists
#     - no nvidia or nouveau kernel module is loaded. Right after removing
#       the driver this can fail with "reboot pending?": the removal worked,
#       the running kernel just hasn't caught up.
#     - if glxinfo exists, the OpenGL renderer is the Intel chip, not NVIDIA
#       or nouveau. r: the renderer name glxinfo reports; empty means no
#       graphics session to ask. No glxinfo prints a neutral [--] line,
#       counted as neither pass nor fail. `apt install mesa-utils` gets it.
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

# 16. EasyEffects presets (utils.sh step 15). The upstream installer writes
#     preset .json files into ~/.config/easyeffects/{output,input}; only
#     output is checked. It needs at least one .json there, not merely the
#     folder. EasyEffects creates that folder itself on first launch, so an
#     empty one would otherwise pass while the presets never landed.
#     ee: the output presets folder.
ee="$HOME/.config/easyeffects/output"
if [ -d "$ee" ] && ls "$ee"/*.json >/dev/null 2>&1; then
  ok "easyeffects presets in $ee"
else
  bad "easyeffects presets missing in $ee"
fi

# 17. Credential scan. Not about your setup at all: it looks for passwords
#     and API tokens sitting in your shell startup files. utils.sh closes by
#     telling you to keep tokens out of them; this makes that checkable.
#     Why these files: each time you open a terminal, the shell reads and
#     runs them. Pasting a token there is easy, so people do. But they are
#     plain, unprotected text. Worse, ~/.zshrc here is not a real file. It is
#     a symlink into the steves-cli-setup git repo, so a token pasted there
#     lands in a *tracked* file, one `git commit -a` from GitHub. That
#     happened on 2026-09-05 (a GH_TOKEN ended up staged).
#
#     SECRET_RE: the pattern (an extended regex) for "looks like a secret".
#     Two kinds of match:
#       1. Shapes it recognises. These are near-certain:
#            GitHub      ghp_ gho_ ghu_ ghs_ ghr_ (gh[pousr]_) or github_pat_,
#                        followed by 20+ token characters
#            Anthropic   sk-ant- followed by 20+ characters
#            AWS         AKIA followed by 16 capitals/digits
#       2. Names that suggest a secret: anything ending _TOKEN, _KEY,
#          _SECRET or PASSWORD, set with `=` to a bare literal.
#     The "bare literal" rule (the value must start with a letter or digit)
#     is the whole trick against false alarms. FOO_TOKEN="$BAR" starts with
#     a quote, so it is not a pasted secret. FOO_KEY= and FOO_KEY="" hold
#     nothing. Only a value that looks pasted is reported.
SECRET_RE='gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
SECRET_RE="$SECRET_RE"'|sk-ant-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}'
SECRET_RE="$SECRET_RE"'|(_TOKEN|_KEY|_SECRET|PASSWORD)=[A-Za-z0-9]'
# sec_bad: becomes 1 as soon as any file has a hit.
sec_bad=0
# The six shell startup files. Missing ones are skipped.
for rc in "$HOME/.zshrc" "$HOME/.zshrc.local" "$HOME/.zshenv" "$HOME/.zprofile" \
          "$HOME/.profile" "$HOME/.bashrc"; do
  [ -f "$rc" ] || continue
  # hits: the line numbers that match, space-separated. grep -n puts
  # "NUMBER:" in front of each match first, and only then are commented-out
  # lines dropped, so the numbers still match what you see in your editor.
  # `cut` keeps only the number. It NEVER prints the secret itself, only
  # the file and the line numbers. A check that shouted your token across
  # the terminal would be worse than the problem it found.
  hits=$(grep -nE "$SECRET_RE" "$rc" 2>/dev/null \
         | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1 | tr '\n' ' ')
  # On a hit: open the file at those lines and move the value into the
  # tool's own store. For GitHub that is `gh auth login`, which writes
  # ~/.config/gh/hosts.yml with permissions only you can read.
  if [ -n "$hits" ]; then
    bad "secret in $rc — line(s): ${hits% }"
    sec_bad=1
  fi
done
[ "$sec_bad" -eq 0 ] && ok "no credential-shaped lines in shell rc files"

# Totals, then the exit code. The last line's test is the exit status:
# zero failures -> exit 0, otherwise exit 1.
echo
printf 'Passed: %d  Failed: %d\n' "$P" "$F"
[ "$F" -eq 0 ]
