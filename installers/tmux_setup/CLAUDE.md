# installers/tmux_setup/
> **The deployed T480 does not use any of this.** `~/.tmux.conf` is a symlink to `~/steves-cli-setup/tmux/tmux.conf` — a **third repo**, self-contained: Nord theme, `prefix C-a` (+ `C-b` as `prefix2`), splits on `|`/`-`, pane dimming via built-in `window-style`/`window-active-style` rather than the `install-tmux-dim.sh` patch, resurrect/continuum vendored under `~/.local/share/steves-cli-setup/vendor/` and sourced directly — no TPM, no `~/.tmux/` at all. So `backup.tmux.conf` and `install-tmux-immortal.sh` describe a setup the box isn't running; editing them changes nothing live. Per-machine tweaks belong in `~/.tmux.conf.local` (gitignored, sourced at that config's line 191 — after the keybindings so rebinds win, before the plugins because continuum appends its save hook to `status-right` and a later overwrite kills auto-save silently). Reload with `tmux source-file ~/.tmux.conf`; verify with `tmux list-keys`, never `tmux send-keys` (it targets the pane's program and bypasses tmux's key tables entirely).
> **Removed: gpakosz "oh my tmux!"** (`install-tmux-omt.sh` + vendored `tmux-config/`) and **`install-tmux-expose.sh`** (cesarferreira/tmux.expose, Alt+e switcher, plus its `@plugin` line + `@tmux-expose-*` settings in `backup.tmux.conf`). Both removals have landed on the deployed box: `~/.tmux/` is gone and so is `~/.cargo/bin/tmux-expose`. Recover either from git history.

## `install-tmux-immortal.sh` — persist tmux sessions across reboots

Drops `~/.tmux/plugins/{tpm,tmux-resurrect,tmux-continuum}`; `~/.tmux.conf` (only if absent); `~/.config/autostart/tmux-immortal.desktop` (detached `main` session at login). `--uninstall` nukes plugins + autostart, leaves `~/.tmux.conf` alone.
- **Never overwrites an existing `~/.tmux.conf`** — prints the four lines to add. An earlier draft used a header marker to detect "we own this file", which broke when the marker was *appended* to a hand-rolled config: re-runs clobbered the prefix rebind.
- **Headless plugin install needs a live tmux server.** `tpm/bin/install_plugins` reads its path from `tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH` (tmux's global env, not bash). A throwaway `_tpm_init` session running `sleep 30` keeps a server alive.
- **Autostart spawns `tmux new-session -d -s main`, not `start-server`** — a server with zero sessions exits immediately; `main` is a placeholder and continuum adds saved sessions on top at server start.
- **Continuum saves every 15 min.** Faster = disk churn (resurrect's pane-content capture isn't free on big scrollback). First save lands ~15 min after first real use — don't reboot inside that window expecting state.

Usage: sessions auto-restore at login via `@continuum-restore 'on'` + the autostart `.desktop`. Manual save `prefix + Ctrl-s`, restore `prefix + Ctrl-r`. State at `~/.tmux/resurrect/last` (+ `pane_contents.tar.gz` from `@resurrect-capture-pane-contents 'on'`). Re-attach with `tmux a`; `tmux ls` shows `main` plus restored sessions.

## `install-tmux-dim.sh` — build patched tmux with inactive-pane dim

Builds tmux 3.5a from source with `patches/tmux-dim-inactive-panes.patch` (chud-methodology) into `/usr/local/bin/tmux`, shadowing `/usr/bin/tmux`. Dims every cell of inactive panes: 30% perceptual-luma desaturation + 35% blend toward pane bg. Works for arbitrary ANSI content (lazygit, syntax highlighting) — `window-style` alone only touches cells using terminal default colors. No runtime knobs; factors are baked into the patch. `--uninstall` removes the `/usr/local` binary only. Override with `TMUX_VERSION=3.5a`.
- **`patch --dry-run -p1` before the real apply is non-optional** — future tmux drift past the hunks would otherwise yield a tmux with no dimming and no error.
- **Stamp `/usr/local/share/tmux-dim.version`** — same-version re-run is a no-op.
- **Installs to `/usr/local`, not `/usr/bin`** — `/usr/local/bin` precedes `/usr/bin`, so an apt upgrade of distro tmux can't clobber it and `--uninstall` reverts cleanly.
- **Build deps probed individually**: `cc make pkg-config patch curl tar` via `command -v`; `libevent-dev libncurses-dev bison` via `dpkg -s`.

Sanity: `which tmux` → `/usr/local/bin/tmux`; `cat /usr/local/share/tmux-dim.version`. Verify by splitting (`prefix + "`) and hopping focus (`prefix + ;`). Existing servers keep running the old binary until `tmux kill-server` (or logout/login). The Neovim companion (`tint.nvim` Lua transform matching the C algorithm byte-for-byte, FocusLost/FocusGained autocmds against double-dimming) is not yet in `nvim-config/` — drop under `lua/plugins/` when adding. `theme-palette.patch` (ANSI16-palette awareness) not vendored: needs build-time `theme_palette.h` generation, overkill outside Nix.

