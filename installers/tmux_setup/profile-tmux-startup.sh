#!/usr/bin/env bash
# Measure why `tmux` takes so long to reach a usable prompt, and say what to fix.
#
# Read-only. Never touches the running tmux server: every measurement runs on a
# throwaway socket (`tmux -L profile_$$`) that is killed on exit.
[ -z "${BASH_VERSION:-}" ] && exec bash "$0" "$@"
set -euo pipefail

SOCK="profile_$$"
TMPD=""
cleanup() {
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  if [ -n "$TMPD" ]; then rm -rf "$TMPD"; fi
  return 0
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
usage: profile-tmux-startup.sh [--help]

Times each stage of tmux startup and prints ranked advice. Read-only: no flags
to apply anything, nothing is written outside a temp dir. Safe to run with
sessions attached.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

preflight() {
  command -v tmux >/dev/null 2>&1 || { echo "fatal: tmux not on PATH" >&2; exit 1; }
  command -v awk  >/dev/null 2>&1 || { echo "fatal: awk not on PATH"  >&2; exit 1; }
  date +%s%N | grep -qE '^[0-9]{16,}$' || { echo "fatal: date +%s%N has no nanoseconds" >&2; exit 1; }
}

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# Run "$@" three times, echo the fastest wall time in ms. Best-of-3 rather than
# a mean: the floor is the honest cost, the outliers are scheduler noise.
best_ms() {
  local i s e d best=999999
  for i in 1 2 3; do
    s=$(now_ms); "$@" >/dev/null 2>&1 || true; e=$(now_ms)
    d=$(( e - s ))
    if [ "$d" -lt "$best" ]; then best=$d; fi
  done
  echo "$best"
}

# Same, for starting a tmux server with a given config. The server MUST be
# killed between iterations: a second `new-session` against a live server
# reuses it, skipping the config parse and every run-shell, which silently
# reports plugin loading as free.
best_tmux_ms() {
  local conf=$1 i s e d best=999999
  for i in 1 2 3; do
    tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
    s=$(now_ms)
    tmux -L "$SOCK" -f "$conf" new-session -d -s p >/dev/null 2>&1 || true
    e=$(now_ms)
    d=$(( e - s ))
    if [ "$d" -lt "$best" ]; then best=$d; fi
  done
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  echo "$best"
}

row() { printf '  %7s ms  %s\n' "$1" "$2"; }

# ── Stage timings ─────────────────────────────────────────────────────────────

CONF="$HOME/.tmux.conf"

measure_tmux() {
  echo "tmux server startup"

  T_BARE=$(best_tmux_ms /dev/null)
  row "$T_BARE" "tmux binary, no config at all"

  if [ ! -f "$CONF" ]; then
    echo "  (no $CONF — nothing further to measure here)"
    T_NOPLUG=$T_BARE; T_CONF=$T_BARE
    return 0
  fi

  # Plugins stripped: isolates config parsing from `run-shell` plugin loading.
  grep -v '^[[:space:]]*run-shell' "$CONF" > "$TMPD/noplug.conf"
  T_NOPLUG=$(best_tmux_ms "$TMPD/noplug.conf")
  row "$T_NOPLUG" "+ config parsed, run-shell lines stripped"

  T_CONF=$(best_tmux_ms "$CONF")
  row "$T_CONF" "+ plugins loaded (full config)"
  echo "  note: auto-restore is skipped while another server runs, so the"
  echo "        figure above is plugin load only. Restore is measured below."
}

measure_shell() {
  echo
  echo "interactive shell startup (one of these per pane)"
  SH=$(basename "${SHELL:-/bin/sh}")
  case "$SH" in
    zsh|bash) ;;
    *) echo "  (\$SHELL is $SH — only zsh and bash can be profiled)"; T_SHELL=0; return 0 ;;
  esac
  local floor
  floor=$(best_ms "$SH" -f -i -c exit)
  T_SHELL=$(best_ms "$SH" -i -c exit)
  row "$floor"    "$SH -f -i -c exit  (no rc files: the floor)"
  row "$T_SHELL"  "$SH -i -c exit     (your rc files)"
  row "$(( T_SHELL - floor ))" "= cost of your rc files"
}

# Attribute wall time to individual rc lines by diffing consecutive xtrace
# timestamps. The delta after a line's trace belongs to that line.
trace_shell() {
  if [ "${T_SHELL:-0}" -lt 250 ]; then return 0; fi
  case "$SH" in
    zsh)  PS4=$'+%D{%s.%6.}|%N:%i> ' zsh  -i -x -c exit 2>"$TMPD/trace" || true ;;
    bash) PS4='+${EPOCHREALTIME}|${BASH_SOURCE}:${LINENO}> ' bash -i -x -c exit 2>"$TMPD/trace" || true ;;
  esac
  echo
  echo "  slowest rc lines (file, command, self time):"
  awk '
    match($0, /^\++[0-9]+\.[0-9]+\|/) {
      s = substr($0, RSTART, RLENGTH); sub(/^\++/, "", s); sub(/\|$/, "", s)
      rest = substr($0, RSTART + RLENGTH); p = index(rest, "> ")
      if (p == 0) next
      loc = substr(rest, 1, p - 1); cmd = substr(rest, p + 2)
      if (length(cmd) > 52) cmd = substr(cmd, 1, 52)
      if (have) tot[key] += s - prev
      split(loc, a, ":"); file = a[1]; sub(/.*\//, "", file)
      key = sprintf("%-16s %s", file, cmd)
      prev = s; have = 1
    }
    END { for (k in tot) printf "%9.0f ms  %s\n", tot[k] * 1000, k }
  ' "$TMPD/trace" | sort -rn | head -6 | sed 's/^/    /' || true
  # `|| true` is load-bearing: head closes the pipe, sort takes SIGPIPE, and
  # pipefail turns that into a non-zero pipeline that set -e would act on.
}

# ── Session restore ───────────────────────────────────────────────────────────

# Panes multiply the shell cost, and the resurrect/continuum restore path has a
# floor of hardcoded sleeps that no amount of tuning removes.
measure_restore() {
  echo
  echo "session restore"
  local dir last
  dir=$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)
  for d in "$dir" "$HOME/.local/share/tmux/resurrect" "$HOME/.tmux/resurrect"; do
    if [ -n "$d" ] && [ -d "$d" ]; then dir=$d; break; fi
  done
  if [ ! -d "${dir:-}" ]; then
    echo "  (no resurrect save directory — restore is not in play)"
    N_PANES=0; N_AI=0; T_SLEEP=0
    return 0
  fi
  last=$(ls -1t "$dir"/tmux_resurrect_*.txt 2>/dev/null | head -1 || true)
  if [ -z "$last" ]; then
    echo "  (no save file in $dir)"
    N_PANES=0; N_AI=0; T_SLEEP=0
    return 0
  fi
  N_PANES=$(awk -F'\t' '$1=="pane"' "$last" | wc -l)
  N_AI=$(awk -F'\t' '$1=="pane"' "$last" | grep -cE 'claude|opencode|codex|(^|[^a-z])pi([^a-z]|$)|grok' || true)
  echo "  last save: $(basename "$last") — $N_PANES panes, $N_AI of them AI assistants"

  # Sum the literal `sleep N` calls the restore scripts run in series.
  T_SLEEP=0
  local v="$HOME/.local/share/steves-cli-setup/vendor"
  if [ -f "$v/tmux-continuum/scripts/continuum_restore.sh" ]; then
    T_SLEEP=$(( T_SLEEP + 1000 ))
  fi
  if [ -f "$v/tmux-assistant-resurrect/scripts/restore-assistant-sessions.sh" ] && [ "$N_AI" -gt 0 ]; then
    T_SLEEP=$(( T_SLEEP + 2000 + N_AI * 1300 ))
  fi
  if [ "$T_SLEEP" -gt 0 ]; then
    row "$T_SLEEP" "hardcoded sleeps in the restore path (fixed floor)"
  fi
  return 0
}

# ── Report ────────────────────────────────────────────────────────────────────

report() {
  echo
  echo "─── estimated budget to a fully restored session ───"
  local shells=$(( T_SHELL * (N_PANES > 0 ? N_PANES : 1) ))
  local total=$(( T_CONF + shells + T_SLEEP ))
  row "$T_CONF"  "tmux server + config + plugins"
  row "$shells"  "$([ "$N_PANES" -gt 0 ] && echo "$N_PANES" || echo 1) x interactive shell"
  row "$T_SLEEP" "restore sleeps"
  row "$total"   "= total (excludes the programs each pane re-launches)"
  echo
  echo "  The per-pane programs are not measured: an editor or an AI assistant"
  echo "  resuming a conversation can each cost seconds on top of the above."

  echo
  echo "─── what to do, in order of payoff ───"
  local n=0
  if [ "${T_SHELL:-0}" -ge 250 ]; then
    n=$((n+1))
    echo
    echo "$n. Shell startup is ${T_SHELL} ms and you pay it once per pane"
    echo "   (${shells} ms across ${N_PANES:-1} panes). This is almost always the"
    echo "   biggest single win, and the fix is not in tmux config at all."
    echo "   Look at the slowest rc lines above. Version managers (nvm, rbenv,"
    echo "   pyenv, conda) are the usual cause: they resolve and validate a"
    echo "   version on every shell. Replace the eager source with a lazy stub —"
    echo "   put the default version's bin on PATH statically, and define shim"
    echo "   functions that source the real init on first call. Machine-specific"
    echo "   shell config belongs in ~/.zshrc.local, which is sourced but not"
    echo "   tracked; do not edit a tracked rc file through the ~/.zshrc symlink."
  fi
  if [ "${T_SLEEP:-0}" -gt 0 ]; then
    n=$((n+1))
    echo
    echo "$n. ${T_SLEEP} ms of the wait is literal \`sleep\` in the restore"
    echo "   scripts, not work. They are vendored plugin constants, so tuning"
    echo "   tmux will not touch them. Reducing them means editing the vendored"
    echo "   copies, and they exist to let panes settle before keys are sent —"
    echo "   shortening them trades startup time for a flaky restore. Cutting"
    echo "   pane count is the safer lever: ${N_PANES:-0} panes are being restored."
  fi
  if [ "$(( T_CONF - T_NOPLUG ))" -ge 300 ]; then
    n=$((n+1))
    echo
    echo "$n. Plugin loading costs $(( T_CONF - T_NOPLUG )) ms of the server start."
    echo "   Each run-shell line is a synchronous shell script. Drop a plugin you"
    echo "   do not use; there is nothing to tune in the ones you keep."
  fi
  if [ "$n" -eq 0 ]; then
    echo
    echo "  Nothing stands out. tmux reaches a prompt in about $(( T_CONF + T_SHELL )) ms here."
  fi
  echo
}

main() {
  preflight
  TMPD=$(mktemp -d)
  echo "profiling tmux startup — running server is not touched (socket: $SOCK)"
  echo
  measure_tmux
  measure_shell
  trace_shell
  measure_restore
  report
}

main
