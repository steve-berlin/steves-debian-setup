#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-tmux-immortal.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-tmux-immortal.sh — make tmux sessions survive reboots.
# tpm + tmux-resurrect + tmux-continuum, plus an autostart that boots
# a detached tmux server on login so continuum's auto-restore fires.
#
# Idempotent. --dry-run / --uninstall supported.

set -euo pipefail

dry=0; mode=install
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    --uninstall) mode=uninstall ;;
    -h|--help) sed -n '2,6p' "$0"; echo "Usage: $0 [--dry-run] [--uninstall]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
write() { local f=$1; if (( dry )); then printf 'DRY  write %s\n' "$f"; cat >/dev/null
  else mkdir -p "$(dirname "$f")"; cat > "$f"; fi; }

TPM_DIR="$HOME/.tmux/plugins/tpm"
PLUGIN_DIR="$HOME/.tmux/plugins"
CONF="$HOME/.tmux.conf"
AUTOSTART="$HOME/.config/autostart/tmux-immortal.desktop"

if [[ $mode == uninstall ]]; then
  echo "── uninstall ──"
  run rm -rf "$PLUGIN_DIR" "$HOME/.tmux/resurrect"
  run rm -f "$AUTOSTART"
  echo "kept $CONF (remove the @plugin/run-tpm lines manually if you want)"
  exit 0
fi

# 1. tmux + git
echo "── packages ──"
command -v tmux >/dev/null || run sudo apt install -y tmux
command -v git  >/dev/null || run sudo apt install -y git

# 2. tpm (Tmux Plugin Manager).
if [[ ! -d $TPM_DIR ]]; then
  echo "── tpm ──"
  run git clone --depth=1 https://github.com/tmux-plugins/tpm "$TPM_DIR"
fi

# 3. ~/.tmux.conf — only write if absent. Never overwrite an existing
#    config; user merges plugin lines manually.
if [[ ! -f $CONF ]]; then
  echo "── ~/.tmux.conf ──"
  write "$CONF" <<'EOF'
set -g default-terminal "tmux-256color"
set -g history-limit 50000
set -g mouse on

set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'

# resurrect: also save scrollback. continuum: autosave every 15 min,
# auto-restore on server start.
set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'
set -g @continuum-save-interval '15'

run '~/.tmux/plugins/tpm/tpm'
EOF
else
  echo "~/.tmux.conf already exists; leaving it alone"
  echo "  → if you haven't yet, paste these lines somewhere in it:"
  echo "      set -g @plugin 'tmux-plugins/tpm'"
  echo "      set -g @plugin 'tmux-plugins/tmux-resurrect'"
  echo "      set -g @plugin 'tmux-plugins/tmux-continuum'"
  echo "      set -g @continuum-restore 'on'"
  echo "      run '~/.tmux/plugins/tpm/tpm'"
fi

# 4. Install plugins headlessly. tpm's install_plugins reads the path
#    via `tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH`, so we need
#    a live tmux server with that var set. A throwaway `sleep` session
#    keeps the server alive for the duration; killed afterwards.
echo "── plugins ──"
if (( ! dry )); then
  tmux new-session -d -s _tpm_init 'sleep 30' 2>/dev/null || true
  tmux setenv -g TMUX_PLUGIN_MANAGER_PATH "$PLUGIN_DIR/"
  "$TPM_DIR/bin/install_plugins"
  tmux kill-session -t _tpm_init 2>/dev/null || true
else
  printf 'DRY  start tmux, setenv TMUX_PLUGIN_MANAGER_PATH, run install_plugins\n'
fi

# 5. Autostart a detached tmux on login. continuum's restore hook fires
#    on server start, so this is what makes "immortal" hands-free. The
#    'main' session is just a placeholder if continuum has nothing saved
#    yet; harmless to leave around.
echo "── autostart ──"
write "$AUTOSTART" <<'EOF'
[Desktop Entry]
Type=Application
Name=tmux-immortal (auto-restore)
Exec=tmux new-session -d -s main
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

cat <<'EOF'

── done ──
Re-attach with:  tmux a
First save lands ~15 min after first real use; before then there's
nothing for continuum to restore, so a fresh reboot starts empty.
EOF
