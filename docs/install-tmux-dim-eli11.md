# `install-tmux-dim.sh` explained (ELI11)

A plain-language guide to `installers/tmux_setup/install-tmux-dim.sh` — it
builds a version of tmux that visibly dims the pane you are *not* using.

## The problem

Split a terminal into four panes and they all look equally bright. Nothing on
screen says which one your keyboard is actually talking to. You find out by
typing.

tmux has a built-in setting for this (`window-style` / `window-active-style`),
and it half works. It can only recolour cells that are using the terminal's
*default* colours. Any text that sets its own colour — syntax highlighting, a
`lazygit` interface, coloured log output — ignores it completely. So the exact
panes that are busiest stay at full brightness, which is the opposite of helpful.

## The fix

This script builds tmux from its source code with a **patch** applied — a small
set of edits to the original code — that dims every cell on the way to the
screen, whatever colour it was.

Two things happen to each colour in an inactive pane: it loses about 30% of its
colourfulness, and it is blended 35% toward the pane's background. The result
reads as "pushed back" rather than "greyed out", and it works on any content.

There are no settings to tune. The two numbers are compiled in.

## How to use it

```sh
bash installers/tmux_setup/install-tmux-dim.sh              # build + install
bash installers/tmux_setup/install-tmux-dim.sh --dry-run    # plan only
bash installers/tmux_setup/install-tmux-dim.sh --reinstall  # rebuild anyway
bash installers/tmux_setup/install-tmux-dim.sh --uninstall  # remove
TMUX_VERSION=3.5a bash installers/tmux_setup/install-tmux-dim.sh   # different version
```

Check it worked:

```sh
hash -r && tmux -V && which tmux
```

You want `/usr/local/bin/tmux`. Then split a pane (`prefix + "`) and move
between them (`prefix + ;`) to see the effect.

**Already-running tmux servers keep using the old program** until you
`tmux kill-server` or log out and back in. A running server is one process that
was started from the old file; a new file on disk doesn't change it.

## Why it installs to `/usr/local/bin`

Your system's own tmux lives at `/usr/bin/tmux` and belongs to apt. This build
goes to `/usr/local/bin/tmux` and both stay on the machine.

`/usr/local/bin` comes earlier in the search path than `/usr/bin` on Debian, so
typing `tmux` finds the patched one. But apt still owns and updates the original
copy, so a system upgrade can't overwrite the build and uninstalling is just
deleting one file — the distro version is right there underneath.

## What it does, in order

**1. Checks the patch file exists**, then works out which build tools are
missing and apt-installs only those: a compiler, `make`, `pkg-config`, `patch`,
`curl`, `tar`, plus the `libevent`, `ncurses` and `bison` development packages.

**2. Skips everything if the same version is already built.** It records what it
installed in `/usr/local/share/tmux-dim.version`; a matching re-run does
nothing. `--reinstall` forces the rebuild.

**3. Downloads the tmux source** into a temporary folder that is deleted when
the script exits, whatever happens.

**4. Tests the patch before applying it.** `patch --dry-run` first, and only
then for real. This matters more than it sounds: a future tmux release could
move the code the patch expects, and `patch` would apply what it could and skip
the rest. You would get a tmux that builds fine, installs fine, and doesn't dim
anything, with no error anywhere. The dry run turns that into an immediate,
loud failure.

**5. Builds and installs**, then writes the version stamp.

## Uninstalling

`--uninstall` deletes the built program, its manual page and the stamp. The
distro tmux at `/usr/bin/tmux` was never touched, so you land back on it
immediately.

## Not what this box runs

On the deployed ThinkPad the tmux config comes from a separate repo
(`steves-cli-setup`) which does its dimming with tmux's built-in
`window-style` settings, not this patch. So this script is optional even there —
it is the stronger version of an effect that box already has a weaker form of.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | built and installed, already installed, uninstalled, or dry-run finished |
| 1 | patch file missing, download failed, or the patch no longer applies |
| 2 | unknown argument |
