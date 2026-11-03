#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-tmux-immortal.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-tmux-immortal.sh — make your tmux sessions survive a reboot.
#
# tmux is a program that holds terminals for you. You start it, open panes and
# windows inside it, then "detach": close the terminal window, and everything
# inside keeps running. Later `tmux a` (attach) brings it all back as you left
# it. The catch: tmux only lives as long as the computer is on. Reboot, and
# every session is gone.
#
# This script adds three pieces that bring sessions back after a reboot:
#   tpm              tmux's plugin manager; installs and updates the other two
#   tmux-resurrect   saves the layout (windows, panes, working folders, what
#                    was running) to a file, and restores it
#   tmux-continuum   runs resurrect for you: saves every 15 minutes, and
#                    restores when tmux starts
# Plus an autostart entry, so a tmux server starts when you log in. Without
# it nothing triggers the restore; sessions only come back once you open tmux
# by hand.
#
# Usage:
#   bash installers/tmux_setup/install-tmux-immortal.sh              # install
#   bash installers/tmux_setup/install-tmux-immortal.sh --dry-run    # plan only
#   bash installers/tmux_setup/install-tmux-immortal.sh --uninstall  # remove
# Afterwards:
#   tmux a            attach to what's running
#   tmux ls           list sessions (main plus restored ones)
#   prefix + Ctrl-s   save now, by hand
#   prefix + Ctrl-r   restore now, by hand
# ("prefix" is tmux's attention key. utils.sh sets it to Ctrl-a.)
#
# Not what the deployed ThinkPad runs. There, ~/.tmux.conf is a symlink into a
# separate repo (steves-cli-setup). That repo vendors resurrect and continuum
# directly: no plugin manager, no ~/.tmux/ folder at all. Editing this script
# changes nothing on that machine. It is here for a fresh box, or for anyone
# who wants the plugin-manager route. Design notes: installers/tmux_setup/
# CLAUDE.md, "install-tmux-immortal.sh".
#
# Exit codes:
#   0  installed, uninstalled, or dry-run finished
#   2  unknown argument
set -euo pipefail

# dry=1 means "print what would happen, change nothing".
# mode: install (default) or uninstall. Any other argument exits with code 2.
dry=0; mode=install
for a in "$@"; do
  case $a in
    --dry-run)   dry=1 ;;
    --uninstall) mode=uninstall ;;
    -h|--help)   echo "Usage: $0 [--dry-run] [--uninstall]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

# run: in dry-run, print "DRY  <command>"; otherwise run it.
# write FILE: copy standard input into FILE, creating its folder first. In
# dry-run it prints "DRY  write FILE" and throws the input away.
run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
write() { local f=$1; if (( dry )); then echo "DRY  write $f"; cat >/dev/null
  else mkdir -p "$(dirname "$f")"; cat > "$f"; fi; }

# TPM_DIR: where tpm is cloned.
# PLUGIN_DIR: where tpm puts every plugin (tpm itself lives inside it too).
# CONF: your tmux config file.
# AUTOSTART: the login autostart entry this script writes.
TPM_DIR=$HOME/.tmux/plugins/tpm
PLUGIN_DIR=$HOME/.tmux/plugins
CONF=$HOME/.tmux.conf
AUTOSTART=$HOME/.config/autostart/tmux-immortal.desktop

# --uninstall: remove the plugins folder, the saved state (~/.tmux/resurrect)
# and the autostart entry. It LEAVES ~/.tmux.conf alone: it may not be this
# script's file to delete (see step 3). If the script did write it, remove
# the @plugin and `run` lines by hand.
if [[ $mode == uninstall ]]; then
  run rm -rf "$PLUGIN_DIR" "$HOME/.tmux/resurrect"
  run rm -f "$AUTOSTART"
  echo "kept $CONF (remove the @plugin/run-tpm lines by hand if you want)"
  exit 0
fi

# Step 1: make sure tmux and git are installed; apt-install any that are not.
# Step 2: clone tpm into ~/.tmux/plugins/tpm, unless that folder exists.
for c in tmux git; do command -v "$c" >/dev/null || run sudo apt install -y "$c"; done
[[ -d $TPM_DIR ]] || run git clone --depth=1 https://github.com/tmux-plugins/tpm "$TPM_DIR"

# Step 3: write ~/.tmux.conf, but only if you don't have one. Never clobber a
# hand-rolled config. If one exists, print the five lines to add yourself.
# This caution is scar tissue. An earlier version wrote a marker line into the
# config so it could tell "did I write this?". When that marker ended up
# appended to a hand-written config, later runs treated the whole file as
# disposable and flattened the user's own settings (the prefix rebind).
# In the config written below:
#   @resurrect-capture-pane-contents 'on' saves each pane's text (scrollback
#     and all), not just the layout, so a restore feels real.
#   @continuum-restore 'on' restores automatically when the server starts.
#   @continuum-save-interval '15' saves every 15 minutes.
if [[ ! -f $CONF ]]; then
  write "$CONF" <<'EOF'
set -g default-terminal "tmux-256color"
set -g history-limit 50000
set -g mouse on

set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'

set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'
set -g @continuum-save-interval '15'

run '~/.tmux/plugins/tpm/tpm'
EOF
else
  echo "~/.tmux.conf exists — add these lines yourself if not already present:"
  echo "  set -g @plugin 'tmux-plugins/tpm'"
  echo "  set -g @plugin 'tmux-plugins/tmux-resurrect'"
  echo "  set -g @plugin 'tmux-plugins/tmux-continuum'"
  echo "  set -g @continuum-restore 'on'"
  echo "  run '~/.tmux/plugins/tpm/tpm'"
fi

# Step 4: install the plugins without a terminal open. Stranger than it looks.
# tpm's install_plugins asks TMUX, not the shell, where plugins go: it reads
# TMUX_PLUGIN_MANAGER_PATH from tmux's global environment. Asking tmux
# anything needs a running tmux server. So: start a throwaway session called
# _tpm_init that just runs `sleep 30` (keeps a server alive), set the
# variable, run the installer, then kill the session.
if (( ! dry )); then
  tmux new-session -d -s _tpm_init 'sleep 30' 2>/dev/null || true
  tmux setenv -g TMUX_PLUGIN_MANAGER_PATH "$PLUGIN_DIR/"
  "$TPM_DIR/bin/install_plugins"
  tmux kill-session -t _tpm_init 2>/dev/null || true
else
  echo "DRY  start tmux, setenv TMUX_PLUGIN_MANAGER_PATH, run install_plugins"
fi

# Step 5: write the autostart entry. At login it runs
# `tmux new-session -d -s main` (always rewritten, even if it exists).
# Why a session called "main" and not just `tmux start-server`? A tmux server
# with no sessions exits at once, so it would restore nothing. "main" is a
# placeholder that keeps the server alive. When the server starts, continuum's
# restore hook fires and adds your saved sessions alongside it.
write "$AUTOSTART" <<'EOF'
[Desktop Entry]
Type=Application
Name=tmux-immortal (auto-restore)
Exec=tmux new-session -d -s main
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

# About the 15-minute save:
# - Your first save lands about 15 minutes after you first really use tmux.
#   Reboot inside that window and nothing is saved yet. This is the most
#   common "it didn't work" report.
# - Why not save more often? Resurrect captures each pane's contents, not
#   just the layout. That isn't free on a big scrollback. 15 minutes is the
#   compromise between losing work and grinding the disk.
# Saved state lives in ~/.tmux/resurrect/ (newest save: `last`), with pane
# contents in pane_contents.tar.gz next to it.
echo "── done ── Re-attach with: tmux a"
echo "First save lands ~15 min after first real use."
