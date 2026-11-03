#!/usr/bin/env bash
# profile-tmux-startup.sh — find out why tmux takes so long to open.
#
# You type `tmux`, and it sits there. This script times each separate thing
# that has to happen before you get a prompt, prints the numbers, and says
# which one to go fix. It only measures. It never changes anything.
#
# Words you need first:
#   pane      one rectangle inside tmux, running one shell. A window can be
#             split into several.
#   rc file   the script your shell runs every time it starts. For zsh that
#             is ~/.zshrc, which here also pulls in ~/.zshrc.local.
#   plugin    an add-on tmux loads at startup with a `run-shell` line in
#             ~/.tmux.conf. Each one is an ordinary shell script that must
#             finish before tmux moves on.
#   resurrect / continuum
#             the two plugins that save your sessions and put them back after
#             a reboot. Restoring means re-opening every pane and re-launching
#             whatever ran in it.
#   socket    the file tmux uses to talk to its own server. Two socket names
#             are two separate tmux servers that cannot see each other. That
#             is the trick that makes this script safe.
#
# Why it is safe: every measurement runs on a throwaway socket,
# `tmux -L profile_<pid>`. Your real sessions live on the default socket and
# are never attached to and never killed. (One read-only exception: step 5
# asks the default server for its @resurrect-dir option.) An EXIT INT TERM
# trap kills the throwaway server and deletes the temp folder, even if you
# Ctrl-C halfway. Run it with work open.
#
# What it will never do: touch your running server, sessions or saved state;
# edit ~/.tmux.conf, ~/.zshrc, ~/.zshrc.local or any vendored plugin; install
# or remove anything; write outside a `mktemp -d` folder it deletes on exit.
# It tells you what to change. You change it.
#
# Flags:
#   (none)   measure everything and print the report
#   --help   print usage and exit
# There is deliberately no --dry-run, --reinstall or --uninstall. Installers
# have those because they change your machine. This doesn't, so there is
# nothing to undo or preview.
#
# Exit codes:
#   0  measured everything, printed the report
#   1  missing tmux, awk, or a nanosecond-capable `date`
#   2  unknown command-line argument
[ -z "${BASH_VERSION:-}" ] && exec bash "$0" "$@"
set -euo pipefail

# SOCK: name of the private tmux socket. $$ is this script's process id, so
# two runs never share one.
# TMPD: the temp folder (made in main). Empty until then, so cleanup() knows
# there is nothing to delete yet.
# cleanup: kill the throwaway server and delete TMPD. The trap runs it on
# normal exit, Ctrl-C (INT) and kill (TERM).
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

# Only the first argument is looked at: --help/-h, or nothing. Anything else
# prints usage and exits 2.
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# Step 1: check it can run at all. Needs tmux, awk, and a `date` that prints
# nanoseconds (`date +%s%N` must give 16+ digits). Any missing is a hard fail
# with a message, not a confusing crash later.
preflight() {
  command -v tmux >/dev/null 2>&1 || { echo "fatal: tmux not on PATH" >&2; exit 1; }
  command -v awk  >/dev/null 2>&1 || { echo "fatal: awk not on PATH"  >&2; exit 1; }
  date +%s%N | grep -qE '^[0-9]{16,}$' || { echo "fatal: date +%s%N has no nanoseconds" >&2; exit 1; }
}

# now_ms: the current time in milliseconds (nanoseconds / 1000000).
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
# reports plugin loading as free. An earlier draft did exactly that and
# reported plugin loading as 23 ms instead of 1137 ms. If you edit this, keep
# the kill-server.
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

# row MS TEXT: print one report line, the number right-aligned.
row() { printf '  %7s ms  %s\n' "$1" "$2"; }

# ── Stage timings ─────────────────────────────────────────────────────────────

# CONF: the tmux config being profiled. On the deployed box this is a symlink
# into steves-cli-setup, so that is the config measured.
CONF="$HOME/.tmux.conf"

# Step 2: time the tmux server three ways, each on the private socket:
#   T_BARE    the bare binary with -f /dev/null, so no config at all
#   T_NOPLUG  your real config with every `run-shell` line stripped out
#   T_CONF    your real config, untouched
# Read it by subtracting. T_BARE is tmux itself. T_NOPLUG - T_BARE is the
# cost of parsing your config. T_CONF - T_NOPLUG is the cost of loading your
# plugins. No config file means all three are set to T_BARE.
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
  # Drops lines starting with `run-shell` and with its short alias `run`
  # (e.g. `run '~/.tmux/plugins/tpm/tpm'`, the form install-tmux-immortal.sh
  # writes), each with or without -b. The word must end right after `run` or
  # `run-shell`, so a line like `running...` is not touched.
  grep -vE '^[[:space:]]*run(-shell)?([[:space:]]|$)' "$CONF" > "$TMPD/noplug.conf"
  T_NOPLUG=$(best_tmux_ms "$TMPD/noplug.conf")
  row "$T_NOPLUG" "+ config parsed, run-shell lines stripped"

  # Restore is not in this number. Continuum refuses to auto-restore when
  # another tmux server is already running: a guard so two servers can't
  # fight over one save file. Your real server runs while we measure, so
  # restore never fires here. (The note printed below says "measured", but
  # step 5 actually computes it from the save file.)
  T_CONF=$(best_tmux_ms "$CONF")
  row "$T_CONF" "+ plugins loaded (full config)"
  echo "  note: auto-restore is skipped while another server runs, so the"
  echo "        figure above is plugin load only. Restore is measured below."
}

# Step 3: time your shell twice (best of 3 each). Once with -f, which skips
# every rc file: the floor, the fastest your shell can start. Once normally:
# T_SHELL. The gap is what your own config costs. This matters more than any
# other number here, because EVERY PANE PAYS IT. SH is the shell's name
# from $SHELL; only zsh and bash can be profiled, others set T_SHELL=0.
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

# Step 4: blame individual rc lines. Only runs if the shell took 250 ms or
# more. It re-runs the shell with xtrace on (-x: print each line before it
# runs) and a timestamp in the trace prompt (PS4). Then it subtracts each
# timestamp from the next. The gap after a line belongs to that line. The
# awk sums those gaps per file+command (command cut to 52 chars), and the
# six worst are printed.
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
  # Without it the script exits 141 and you never see the report. Same family
  # as the AND-list trap in the repo's CLAUDE.md.
}

# ── Session restore ───────────────────────────────────────────────────────────

# Panes multiply the shell cost, and the resurrect/continuum restore path has a
# floor of hardcoded sleeps that no amount of tuning removes.
# Step 5: read your last saved session. Find the save folder: the live
# server's @resurrect-dir option first, then ~/.local/share/tmux/resurrect,
# then ~/.tmux/resurrect. Take the newest tmux_resurrect_*.txt in it.
#   N_PANES  lines whose first tab-separated field is "pane"
#   N_AI     those panes that look like an AI assistant (claude, opencode,
#            codex, a standalone "pi", grok)
#   T_SLEEP  the literal `sleep` calls the restore scripts run one after
#            another, added up
# No folder or no save file means all three are 0.
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
  # These are counted, not timed: timing restore for real would mean killing
  # your sessions. Constants from the vendored plugins (steves-cli-setup):
  #   continuum_restore.sh present            1000 ms
  #   restore-assistant-sessions.sh present,  2000 ms + 1300 ms per AI pane
  #   and at least one AI pane
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

# Step 6: print a budget and ranked advice.
# Budget = server+config+plugins + (shell cost x pane count, at least 1) +
# restore sleeps. It is arithmetic, not a stopwatch: the right order of
# magnitude, not a precise total. Programs inside panes (an editor loading
# plugins, an AI assistant resuming a chat) are not counted and can each add
# seconds; the report says so out loud.
# Advice, biggest win first. Each item only shows when its number is big:
#   1. Slow shell (T_SHELL >= 250 ms). Usual cause: a version manager (nvm,
#      rbenv, pyenv, conda) that resolves a version on every shell start. Fix
#      is lazy loading: put the default version's bin on PATH as a plain
#      string, and define small functions that source the real init the
#      first time you call one. Not a tmux fix: it also speeds up every new
#      terminal, split and subshell. Put it in ~/.zshrc.local, not ~/.zshrc.
#      On this box ~/.zshrc is a symlink into steves-cli-setup, so editing it
#      edits a tracked file. That repo sources ~/.zshrc.local on purpose and
#      never writes to it.
#   2. Restore sleeps (T_SLEEP > 0). Constants in the vendored plugins. They
#      let panes get ready before keys are sent; shortening them risks a
#      restore that drops a command. Restoring fewer panes is safer.
#   3. Plugin load (T_CONF - T_NOPLUG >= 300 ms). Each run-shell line is a
#      synchronous script. Nothing to tune in a plugin you keep; drop one you
#      don't use.
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
