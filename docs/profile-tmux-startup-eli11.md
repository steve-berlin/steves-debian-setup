# `profile-tmux-startup.sh` — find out why tmux takes so long to open

You type `tmux`, and it sits there. This script times each separate thing that
has to happen before you get a prompt, prints the numbers, and tells you which
one to go fix. It only measures. It never changes anything.

## Words you need first

- **pane** — one rectangle inside tmux running one shell. A window can be split
  into several.
- **rc file** — the script your shell runs every single time it starts.
  For zsh that is `~/.zshrc`, which here also pulls in `~/.zshrc.local`.
- **plugin** — an add-on tmux loads at startup with a `run-shell` line in
  `~/.tmux.conf`. Each one is an ordinary shell script that has to finish
  before tmux moves on.
- **resurrect / continuum** — the two plugins that save your sessions and put
  them back after a reboot. Restoring means re-opening every pane and
  re-launching whatever was running in it.
- **socket** — the file tmux uses to talk to its own server. Two different
  socket names are two completely separate tmux servers that cannot see each
  other. That is the trick that makes this script safe.

## Flags

| Flag | What it does |
|---|---|
| *(none)* | Measure everything and print the report. |
| `--help` | Print usage and exit. |

There is deliberately no `--dry-run`, no `--reinstall`, no `--uninstall`.
Those exist on the installers in this repo because installers change your
machine. This one does not, so there is nothing to undo and nothing to
preview. Anything else on the command line exits 2.

## What it does, in order

1. **Checks it can run at all.** Needs `tmux`, `awk`, and a `date` that can
   print nanoseconds. Missing any of those is a hard fail with a message,
   not a confusing crash later.

2. **Times the tmux server three ways**, each on a throwaway socket named
   `profile_<pid>`:
   - the bare `tmux` binary with `-f /dev/null`, so no config at all
   - your real config with every `run-shell` line stripped out
   - your real config, untouched

   Subtract to read it: first number is tmux itself, second minus first is
   the cost of *parsing* your config, third minus second is the cost of
   *loading your plugins*.

3. **Times your shell twice.** Once with `-f`, which skips every rc file —
   that is the floor, the fastest your shell could possibly start. Once
   normally. The difference is what your own config costs. This matters more
   than any other number here, because **every pane pays it**.

4. **Blames individual rc lines.** If your shell takes more than 250 ms, the
   script re-runs it with tracing on and a timestamp in the prompt, then
   subtracts each timestamp from the next. The gap after a line belongs to
   that line. It prints the six worst.

5. **Reads your last saved session.** Counts how many panes resurrect will
   restore, and how many of those are AI assistants, then adds up the literal
   `sleep` commands the restore scripts run one after another.

6. **Prints a budget and ranked advice.** Server plus shells times pane count
   plus sleeps. Then a numbered list, biggest win first.

## The one thing that makes it safe

Every measurement runs on `tmux -L profile_<pid>`, a private socket. Your
real sessions live on the default socket and are never contacted, never
attached to, never killed. An `EXIT INT TERM` trap kills the throwaway server
and deletes the temp directory even if you Ctrl-C halfway through. Run it with
work open; nothing happens to it.

## Gotchas

- **Restore is not included in the plugin number.** Continuum refuses to
  auto-restore when another tmux server is already running — a deliberate
  guard so two servers cannot fight over one save file. Your real server is
  running while this script measures, so restore never fires on the throwaway
  socket. That is why the sleeps are counted separately from the save file
  instead of being timed directly. The script says so in its own output.

- **The budget is arithmetic, not a stopwatch.** Shell cost times pane count
  is an estimate. It cannot be measured for real without killing your
  sessions and restoring them, which is exactly what this script refuses to
  do. Treat it as the right order of magnitude, not a precise total.

- **Programs inside panes are not counted.** An editor loading its plugins, or
  an AI assistant resuming a conversation, can each cost seconds on top. The
  report says this out loud so the total is not mistaken for the whole wait.

- **Best-of-three, and the server is killed between each.** Restarting matters:
  a second `new-session` against a live server just reuses it, skipping the
  config parse and every plugin. An earlier draft of this script did exactly
  that and cheerfully reported plugin loading as free — 23 ms instead of
  1137 ms. If you edit `best_tmux_ms`, keep the `kill-server`.

- **`|| true` after the `head -6` pipeline is load-bearing.** `head` closes the
  pipe once it has six lines, `sort` gets SIGPIPE, and `pipefail` turns that
  into a failed pipeline that `set -e` acts on. Without it the script exits
  141 and you never see the report. This is the same trap documented in the
  repo's `CLAUDE.md`.

## What it will never do

- Touch your running tmux server, your sessions, or your saved state.
- Edit `~/.tmux.conf`, `~/.zshrc`, `~/.zshrc.local`, or any vendored plugin.
- Install or remove anything.
- Write outside a `mktemp -d` directory it deletes on exit.

It tells you what to change. You change it.

## Reading the advice

The three things it can tell you, and what to actually do about each:

1. **Slow shell.** The usual culprit is a version manager (`nvm`, `rbenv`,
   `pyenv`, `conda`) that resolves and validates a version on every single
   shell start. The fix is lazy loading: put the default version's `bin` on
   `PATH` as a plain string, and define small functions for the commands that
   source the real init the first time you call one. This is not a tmux fix —
   it also speeds up every new terminal, split, and subshell.

2. **Restore sleeps.** These are constants inside the vendored plugins. They
   exist so panes are ready before keystrokes are sent to them; shortening
   them trades startup time for a restore that sometimes drops a command.
   Restoring fewer panes is the safer lever.

3. **Plugin load.** Each `run-shell` line is a synchronous script. There is
   nothing to tune inside a plugin you are keeping — the only move is to drop
   one you are not using.

## Where the shell fix goes

Not in `~/.zshrc`. On this box that is a symlink into the `steves-cli-setup`
repo, so editing it edits a tracked file, and your machine-specific tweak
becomes a permanent diff you have to keep dodging. That repo sources
`~/.zshrc.local` on purpose and never writes to it. Machine-specific shell
config goes there.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Measured everything, printed the report. |
| 1 | Missing `tmux`, `awk`, or nanosecond `date`. |
| 2 | Unknown command-line argument. |
