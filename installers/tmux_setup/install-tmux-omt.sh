#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-tmux-omt.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-tmux-omt.sh — deploy gpakosz "oh my tmux!" from the vendored copy.
#
# gpakosz ships two files: .tmux.conf (the engine, never edited) and
# .tmux.conf.local (your settings). Both live vendored in ../../tmux-config/ —
# the .local there already declares tmux-resurrect + tmux-continuum. This script
# just copies them into place; it never touches the network.
#
#   ~/.tmux/.tmux.conf   <- copy of the engine
#   ~/.tmux.conf         -> symlink to it
#   ~/.tmux.conf.local   <- copy of the template (only when absent — your edits stay)
#
# C-a is gpakosz's built-in secondary prefix (C-b stays primary), so the
# utils.sh step-11 "prefix C-a" invariant holds. Replaces a real ~/.tmux.conf
# from install-tmux-immortal.sh (backed up first). See CLAUDE.md.
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)
SRC=$SELF/../../tmux-config
OMT_DIR=$HOME/.tmux
CONF=$HOME/.tmux.conf
LOCAL=$HOME/.tmux.conf.local
TPM=$OMT_DIR/plugins/tpm
STAMP=$(date +%Y%m%d-%H%M%S)

dry=0; mode=install
for a in "$@"; do
  case $a in
    --dry-run)   dry=1 ;;
    --reinstall) mode=reinstall ;;
    --uninstall) mode=uninstall ;;
    -h|--help)   echo "Usage: $0 [--dry-run] [--reinstall|--uninstall]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
# gpakosz's engine carries this URL near the top — how we recognise our copy.
is_omt() { head -n 20 "$OMT_DIR/.tmux.conf" 2>/dev/null | grep -q 'gpakosz/.tmux'; }

command -v tmux >/dev/null || { echo "error: tmux not on PATH" >&2; exit 1; }

if [[ $mode == uninstall ]]; then
  [[ -L $CONF ]] && run rm -f "$CONF"
  newest=$(ls -1t "$CONF".bak.* 2>/dev/null | head -n1 || true)
  [[ -n $newest ]] && { run mv "$newest" "$CONF"; echo "restored $CONF from $newest"; }
  is_omt && run rm -f "$OMT_DIR/.tmux.conf"
  echo "kept $LOCAL and ~/.tmux/plugins — delete by hand for a clean slate"
  exit 0
fi

[[ -f $SRC/.tmux.conf && -f $SRC/.tmux.conf.local ]] \
  || { echo "error: vendored config missing under $SRC" >&2; exit 1; }

# 1. Copy the engine into ~/.tmux (idempotent; --reinstall refreshes it too).
run mkdir -p "$OMT_DIR"
run cp "$SRC/.tmux.conf" "$OMT_DIR/.tmux.conf"

# 2. Point ~/.tmux.conf at it, backing up a real file first.
[[ -e $CONF && ! -L $CONF ]] && { run mv "$CONF" "$CONF.bak.$STAMP"; echo "backed up $CONF -> $CONF.bak.$STAMP"; }
run ln -sf "$OMT_DIR/.tmux.conf" "$CONF"

# 3. Seed ~/.tmux.conf.local once — never clobber your edits.
if [[ -f $LOCAL ]]; then
  echo "$LOCAL exists — leaving it alone"
else
  run cp "$SRC/.tmux.conf.local" "$LOCAL"
  echo "seeded $LOCAL (declares resurrect + continuum)"
fi

# 4. Install TPM + plugins headless. gpakosz self-clones tpm on first launch,
#    but do it here for determinism — same trick as install-tmux-immortal.sh:
#    tpm reads TMUX_PLUGIN_MANAGER_PATH from tmux's global env, so it needs a
#    live server.
[[ -d $TPM ]] || run git clone --depth=1 https://github.com/tmux-plugins/tpm "$TPM"
if (( ! dry )); then
  tmux new-session -d -s _tpm_omt 'sleep 30' 2>/dev/null || true
  tmux setenv -g TMUX_PLUGIN_MANAGER_PATH "$OMT_DIR/plugins/"
  "$TPM/bin/install_plugins" || true
  tmux kill-session -t _tpm_omt 2>/dev/null || true
fi

echo "── done ── Reload a running server: tmux source-file ~/.tmux.conf"
echo "Edit ~/.tmux.conf.local, not ~/.tmux.conf (managed symlink). Prefix C-b, alt C-a."
