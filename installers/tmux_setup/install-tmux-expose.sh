#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-tmux-expose.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-tmux-expose.sh — cargo-install cesarferreira/tmux-expose (Mission Control
# -style session switcher) and register the TPM plugin in ~/.tmux.conf.
# See CLAUDE.md "installers/" → "install-tmux-expose.sh" for design notes.
set -euo pipefail

CRATE=tmux-expose
PLUGIN_LINE="set -g @plugin 'cesarferreira/tmux.expose'"
CONF=$HOME/.tmux.conf
TPM_DIR=$HOME/.tmux/plugins/tpm

dry=0; mode=install
for a in "$@"; do
  case $a in
    --dry-run)   dry=1 ;;
    --reinstall) mode=reinstall ;;
    --uninstall) mode=uninstall ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--reinstall|--uninstall]"
      echo "  Installs $CRATE via cargo + adds '$PLUGIN_LINE' to $CONF."
      echo "  Default binding: Alt+e opens a fullscreen tmux popup with live previews."
      exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }

# Preflight: cargo on PATH. install-tmux-expose.sh is downstream of utils.sh,
# which installs rustup — fail loud if someone runs it standalone.
command -v cargo >/dev/null || {
  echo "error: cargo not on PATH. Run installers/utils.sh first (rustup section)" >&2
  exit 1
}

if [[ $mode == uninstall ]]; then
  run cargo uninstall "$CRATE" 2>/dev/null || true
  # Strip the plugin line if we added it. Leave the rest of ~/.tmux.conf alone.
  if [[ -f $CONF ]] && grep -Fqx "$PLUGIN_LINE" "$CONF"; then
    if (( dry )); then
      echo "DRY  sed -i '/^set -g @plugin .cesarferreira\/tmux.expose.$/d' $CONF"
    else
      sed -i "\|$PLUGIN_LINE|d" "$CONF"
    fi
  fi
  echo "uninstalled $CRATE; plugin dir under ~/.tmux/plugins/tmux.expose left for TPM to clean"
  exit 0
fi

# `cargo install` is idempotent at the same version, but a forced reinstall is
# cheap and serves --reinstall semantics.
cargo_args=()
[[ $mode == reinstall ]] && cargo_args+=(--force)
run cargo install "${cargo_args[@]}" "$CRATE"

# Add the @plugin line ahead of the `run '~/.tmux/plugins/tpm/tpm'` line.
# tpm only manages plugins that appear before `run-tpm`, so order matters.
if [[ ! -f $CONF ]]; then
  echo "warn: $CONF does not exist. Run installers/install-tmux-immortal.sh first."
  echo "      Add this line by hand before the 'run …/tpm' line: $PLUGIN_LINE"
  exit 0
fi

if grep -Fqx "$PLUGIN_LINE" "$CONF"; then
  echo "$CONF already references cesarferreira/tmux.expose — no change"
else
  if (( dry )); then
    echo "DRY  insert '$PLUGIN_LINE' into $CONF before the tpm run line"
  else
    # Insert before the first line that runs tpm; fall back to append.
    if grep -q "tpm/tpm" "$CONF"; then
      sed -i "0,/tpm\/tpm/{s|.*tpm/tpm.*|$PLUGIN_LINE\n&|}" "$CONF"
    else
      printf '\n%s\n' "$PLUGIN_LINE" >> "$CONF"
    fi
  fi
fi

# Trigger TPM install. Same throwaway-server dance as install-tmux-immortal.sh:
# tpm reads TMUX_PLUGIN_MANAGER_PATH from tmux's global env, not bash's, so a
# live server is required for headless install.
if (( ! dry )) && [[ -x $TPM_DIR/bin/install_plugins ]]; then
  tmux new-session -d -s _tpm_expose 'sleep 30' 2>/dev/null || true
  tmux setenv -g TMUX_PLUGIN_MANAGER_PATH "$HOME/.tmux/plugins/"
  "$TPM_DIR/bin/install_plugins" || true
  tmux kill-session -t _tpm_expose 2>/dev/null || true
fi

echo "── done ── In a fresh tmux: prefix + I (if needed), then Alt+e to open the grid."
echo "Inside an existing tmux server: tmux source-file ~/.tmux.conf"
