#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-tmux-immortal.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-tmux-immortal.sh — tpm + tmux-resurrect + tmux-continuum + login autostart.
# See CLAUDE.md "installers/" → "install-tmux-immortal.sh" for the four design decisions.
set -euo pipefail

dry=0; mode=install
for a in "$@"; do
  case $a in
    --dry-run)   dry=1 ;;
    --uninstall) mode=uninstall ;;
    -h|--help)   echo "Usage: $0 [--dry-run] [--uninstall]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
write() { local f=$1; if (( dry )); then echo "DRY  write $f"; cat >/dev/null
  else mkdir -p "$(dirname "$f")"; cat > "$f"; fi; }

TPM_DIR=$HOME/.tmux/plugins/tpm
PLUGIN_DIR=$HOME/.tmux/plugins
CONF=$HOME/.tmux.conf
AUTOSTART=$HOME/.config/autostart/tmux-immortal.desktop

if [[ $mode == uninstall ]]; then
  run rm -rf "$PLUGIN_DIR" "$HOME/.tmux/resurrect"
  run rm -f "$AUTOSTART"
  echo "kept $CONF (remove the @plugin/run-tpm lines by hand if you want)"
  exit 0
fi

for c in tmux git; do command -v "$c" >/dev/null || run sudo apt install -y "$c"; done
[[ -d $TPM_DIR ]] || run git clone --depth=1 https://github.com/tmux-plugins/tpm "$TPM_DIR"

# Only write ~/.tmux.conf if absent — never clobber a hand-rolled config.
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

# tpm's install_plugins reads TMUX_PLUGIN_MANAGER_PATH from tmux's global env,
# not bash's — needs a live server. Throwaway _tpm_init session keeps one alive.
if (( ! dry )); then
  tmux new-session -d -s _tpm_init 'sleep 30' 2>/dev/null || true
  tmux setenv -g TMUX_PLUGIN_MANAGER_PATH "$PLUGIN_DIR/"
  "$TPM_DIR/bin/install_plugins"
  tmux kill-session -t _tpm_init 2>/dev/null || true
else
  echo "DRY  start tmux, setenv TMUX_PLUGIN_MANAGER_PATH, run install_plugins"
fi

# Autostart a detached tmux on login → continuum's restore hook fires on server start.
write "$AUTOSTART" <<'EOF'
[Desktop Entry]
Type=Application
Name=tmux-immortal (auto-restore)
Exec=tmux new-session -d -s main
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

echo "── done ── Re-attach with: tmux a"
echo "First save lands ~15 min after first real use."
