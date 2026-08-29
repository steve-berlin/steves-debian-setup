# `install-tmux-immortal.sh` explained (ELI11)

A plain-language guide to `installers/tmux_setup/install-tmux-immortal.sh` — it
makes your terminal sessions survive a reboot.

## What tmux is, in one paragraph

`tmux` is a program that holds terminals for you. You start it, open several
panes and windows inside it, and then you can *detach* — close the terminal
window entirely — and everything inside keeps running. Later you `tmux a`
(attach) and it is all exactly as you left it. It is how you keep a long build,
an SSH session and three editors alive without keeping a window open.

The catch: **tmux only survives as long as the computer is on.** Reboot, and
every session is gone.

## What this script adds

Three pieces that together make sessions come back after a reboot:

| Piece | Job |
|---|---|
| **tpm** | tmux's plugin manager — installs and updates the other two |
| **tmux-resurrect** | saves the layout (windows, panes, working folders, what was running) to a file, and restores it |
| **tmux-continuum** | runs resurrect automatically: saves every 15 minutes, and restores when tmux starts |

Plus one more thing that is easy to overlook: an **autostart entry** so a tmux
server starts when you log in. Without that, nothing triggers the restore — the
sessions only come back once you open tmux by hand.

## How to use it

```sh
bash installers/tmux_setup/install-tmux-immortal.sh              # install
bash installers/tmux_setup/install-tmux-immortal.sh --dry-run    # plan only
bash installers/tmux_setup/install-tmux-immortal.sh --uninstall  # remove
```

Afterwards:

- `tmux a` — attach to what's running
- `tmux ls` — list sessions
- `prefix + Ctrl-s` — save now, by hand
- `prefix + Ctrl-r` — restore now, by hand

("prefix" is tmux's attention key. `utils.sh` sets it to `Ctrl-a`.)

## What it does, in order

**1. Makes sure `tmux` and `git` are installed**, apt-installing them if not.

**2. Clones tpm** into `~/.tmux/plugins/tpm`.

**3. Writes `~/.tmux.conf` — but only if you don't have one.** If you already
have a config it does not touch it. Instead it prints the five lines to add
yourself:

```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @continuum-restore 'on'
run '~/.tmux/plugins/tpm/tpm'
```

This caution is scar tissue. An earlier version wrote a marker line into the
config so it could tell "did I write this?" — and when that marker ended up
appended to a hand-written config, later runs treated the whole file as
disposable and flattened settings the user had put there.

**4. Installs the plugins without a terminal open.** This step is stranger than
it looks. tpm's installer asks *tmux* where the plugins go, not the shell — and
asking tmux anything requires a running tmux server. So the script starts a
throwaway session called `_tpm_init` that just sleeps, sets the variable, runs
the installer, and kills the session again.

**5. Writes the autostart entry**, `~/.config/autostart/tmux-immortal.desktop`,
which runs at login:

```
tmux new-session -d -s main
```

Note it creates a session called `main` rather than just starting a server. A
tmux server with no sessions exits immediately, so it would restore nothing.
`main` is a placeholder to keep the server alive; continuum then adds your saved
sessions alongside it.

## Two things about the 15-minute save

**Your first save lands about 15 minutes after you first use tmux.** Reboot
inside that window and there is nothing saved yet. This is the single most
common "it didn't work" report.

**Why not save more often?** Because resurrect is configured to capture the
*contents* of each pane, not just the layout — scrollback and all. That is what
makes a restored session feel real rather than a set of empty shells, but it is
not free on a big scrollback buffer. Fifteen minutes is the compromise between
losing work and grinding the disk.

Saved state lives in `~/.tmux/resurrect/`, with pane contents in a
`pane_contents.tar.gz` next to it.

## Uninstalling

`--uninstall` removes the plugins folder, the saved state, and the autostart
entry. It **leaves `~/.tmux.conf` alone** — same reasoning as above; it may not
be the script's file to delete. If the script did write it, remove the `@plugin`
and `run` lines by hand.

## Not what this box runs

Worth knowing if you are reading this on the deployed ThinkPad: **it doesn't use
any of this.** There, `~/.tmux.conf` is a symlink into a separate repo
(`steves-cli-setup`), which vendors resurrect and continuum directly and has no
plugin manager and no `~/.tmux/` folder at all. Editing this script changes
nothing on that machine. It is here for a fresh box, or for anyone who wants the
plugin-manager route.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | installed, uninstalled, or dry-run finished |
| 2 | unknown argument |
