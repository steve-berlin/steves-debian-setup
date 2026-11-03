# steves_debian_setup

Personal setup repo for a fresh MX Linux install on a ThinkPad T480 (Intel UHD 620, x86_64, Liquorix kernel). Turns a clean MX install into the working environment, plus apps without first-class Linux delivery. **Deployed box now runs MX 25.2 (`MX-25.2_KDE_x64`) with Plasma on Wayland (`kwin_wayland`)** — older notes below that assume XFCE/X11 are marked where it matters. Gaming scripts → [steves-gaming-utils](https://github.com/steve-berlin/steves-gaming-utils); Redmi scripts → [steves-redmi-setup](https://github.com/steve-berlin/steves-redmi-setup).

## Layout

```
installers/       utils.sh check-setup.sh install-anki.sh install-ly.sh check-ly.sh
                  install-music-dl.sh install-mx-frugal.sh setup_nordvpn.sh
                  fix-suspend-freeze.sh fix-mount.sh            [nested CLAUDE.md]
  tmux_setup/     install-tmux-{immortal,dim}.sh                [nested CLAUDE.md]
  patches/        vendored upstream patches (tmux dim)
debloat_scripts/  debloat-{mx,kde,nvidia}.sh                    [nested CLAUDE.md]
launchers/        nic-boost
autostarts/       *.desktop for ~/.config/autostart
nord-job/         nord-rand + nord-rand.cron (6-hourly NordVPN rotation)
nvim-config/      vendored LazyVim starter (utils.sh seeds ~/.config/nvim)
backup.zshrc      reference copy of ~/.zshrc (don't source — tokens stripped)
backup.tmux.conf  stale — live ~/.tmux.conf symlinks into steves-cli-setup (see tmux_setup/)
claude-config/settings.json  reference copy of ~/.claude/settings.json (statusline uses the stable
                  marketplaces path, not the versioned cache hash)
```
Per-script gotchas live in the nested `CLAUDE.md` files marked above — Claude Code loads one only when work touches that directory. New per-script notes go there, not here.

## Install order on a fresh box
1. `installers/utils.sh` — bulk apt + toolchains + oh-my-zsh + seeds nvim. Everything else assumes this ran.
2. `installers/check-setup.sh` — verifies step 1. Exit 0 = clean.
3. `installers/setup_nordvpn.sh` — only if you want NordVPN.
4. App installers (independent): `install-anki.sh`; `install-music-dl.sh`; `install-mx-frugal.sh` (only when *reinstalling the OS* with no USB stick); `install-ly.sh` (prompts before swapping default DM; verify with `check-ly.sh`); `fix-suspend-freeze.sh` (any systemd ≥ 256 laptop, not just Ly boxes); `debloat_scripts/debloat-{mx,nvidia,kde}.sh` (opt-in: KDE needs `plasma-desktop`, nvidia for Intel-iGPU-only boxes).
5. Tmux: `tmux_setup/install-tmux-{immortal,dim}.sh`.
6. NordVPN rotation: `install -m 755 nord-job/nord-rand ~/.local/bin/`; `crontab nord-job/nord-rand.cron`. Then `launchers/nic-boost` → `~/.local/bin/`, `autostarts/*.desktop` → `~/.config/autostart/`.
Not on the install path: `fix-mount.sh` — run it when a mount fails.

## Conventions every installer follows
- `#!/usr/bin/env bash` + `[ -z "${BASH_VERSION:-}" ]` re-exec guard — catches `sh installers/foo.sh` before dash trips on bashisms.
- `set -euo pipefail`. `--dry-run` prints actions, mutates nothing (combinable with mode flags). Idempotent: re-run on an installed box = no-op.
- Standard modes: bare / `--reinstall` / `--uninstall` / `--dry-run`. Per-script notes call out deviations.
- **`set -e` + AND-list trap**: a bare `[[ cond ]] && cmd` (or `(( n )) && cmd`) with a false condition returns non-zero. Mid-function, `set -e` ignores it; but as the **last command of a function** it becomes the function's return status and kills the script at the call site (same as the last line of the script sets its exit code). Since edits move lines around, don't rely on position: use `if` blocks or append `|| true`. Also never rely on a function being called inside a `&&`/`||` list, which suppresses `set -e` for the whole body.
- No creds, no scraping behind logins, no `curl | sudo bash` of unaudited third parties.
- Hard-fail loud on missing deps in a `preflight` block. Sudo called inline, never via script-wide re-exec.
- **Track multi-step work in real time.** ≥3 discrete steps → TaskCreate/TaskUpdate; `in_progress` BEFORE starting, `completed` immediately when done (don't batch). One task per commit for multi-commit work.
- Every script carries its own plain-language (ELI11) comments, kept in sync with the code: a short header (problem, terms, usage, exit codes), and the rest *distributed* — the note on a variable sits above its definition, on a step above that step, on a flag where it's parsed. Short sentences, one idea each. Comment-only edits must leave code untouched: `diff <(git show HEAD:$f | grep -vE '^[[:space:]]*(#|$)') <(grep -vE '^[[:space:]]*(#|$)' $f)` prints nothing. Never put comment lines inside heredocs/multi-line strings, and mind scripts whose `--help` prints fixed header lines (`debloat-nvidia.sh` uses `sed -n '6,10p' "$0"`). The old `docs/*-eli11.md` were folded in and deleted; recover with `git show 204e76b:docs/<script>-eli11.md`.

## Not in this repo
Live `~/.zshrc` (tokens — `backup.zshrc` is the stripped copy). Gaming partitions (`/games/{steam,minecraft}`), Roblox/Steam/Minecraft runtime data, Waydroid/Android-x86 VM state — see sister repos. Live tmux config — see `steves-cli-setup`.

## launchers/

### `nic-boost` — temporary WiFi/EEE perf boost

Runtime-only NIC tweaks for bandwidth-heavy work. They cost battery *exactly when traffic is low* (they remove idle-time hardware napping), so they're opt-in per session: `sudo iw dev <wifi> set power_save off` (~0.3–0.5 W extra at idle); `sudo ethtool --set-eee <eth> eee off` (~0.5 W extra on an idle link). Three shapes: bare (apply, persist); `nic-boost <cmd>` (apply, run, revert on exit via `trap revert EXIT INT TERM` — covers Ctrl-C/kill); `--off` (revert). No modprobe/dispatcher files written — a reboot reverts to driver defaults.

## autostarts/

`.desktop` autostart files for `~/.config/autostart/` (per user) or `/etc/xdg/autostart/` (system). Written for XFCE (which runs `Exec=` and honors `X-GNOME-Autostart-enabled=true` despite the prefix); Plasma reads the same directory.
- **`alacritty-autostart.desktop`**: `alacritty --daemon` keeps one process alive with no window; `alacritty msg create-window` opens windows in it (plain `alacritty` still starts a fresh process). Not `--gapplication-service` — alacritty isn't a GApplication and exits `unexpected argument`. Bare `alacritty` in `Exec=` (no `/usr/bin/`) so a cargo build in `~/.local/bin` (utils.sh 4b) also resolves. `NoDisplay=true` keeps it out of the menu; `Hidden=` must stay `false` — per the autostart spec `Hidden=true` means "deleted" and the entry never runs.
- **`brave-autostart.desktop`**: `brave-browser` at login. Disable on low-RAM machines.
- **`easyeffects.desktop`**: `easyeffects --gapplication-service` (valid here — EasyEffects *is* a GApplication) starts it windowless; later launches attach to the running service. Required for presets (EQ, autogain) to apply to every audio stream from session start.

`nohup` in `Exec=` is defensive — the DE detaches autostart already, but it shields against a stray HUP from the launching shell. A trailing `&` is spec-ignored but harmless.

## nord-job/ — random NordVPN country rotation

Files: `~/.local/bin/nord-rand` (NordLynx, kill switch, threat protection, autoconnect baked into `setup` mode); `nord-rand.cron`; `~/Desktop/nord-rand.log` (ISO-8601, append-only); SD-card backup at `/media/fred/8B35-3F46/nord-rand{,.cron}` (FAT/exFAT drops +x — `chmod +x` after copying back).

Modes: bare `nord-rand` (random country, **skip if already connected**); `force` (disconnect-and-reconnect — **what cron runs**); `setup` (one-time: technology + protections, enables autoconnect, tries `post-quantum`); `kill on|off` (kill switch — `off` is the escape hatch). Cron: `0 */6 * * * $HOME/.local/bin/nord-rand force >/dev/null 2>&1` (output silenced; the script logs internally). **Autoconnect ↔ option-B conflict**: the chosen behavior was "skip if connected", but NordVPN autoconnect keeps the VPN up 24/7, so plain `nord-rand` would never rotate. Cron therefore uses `force`; manual invocations keep the soft skip. Revert to literal option B by dropping `force` from the cron line.

Country list is pulled live every invocation. `list_countries()` strips ANSI, normalizes whitespace/commas to one country per line, drops separator dashes; CLI naming (underscores, e.g. `United_Kingdom`) preserved. Retry tolerates up to `MAX_TRIES` (5) unavailable picks. Restrict the pool (e.g. EU-only) by filtering inside `list_countries`. Prereqs the script doesn't handle: nordvpn daemon + user in the `nordvpn` group; `nordvpn login` once interactively; `nord-rand setup` once after login. Failure modes: kill switch ON + daemon dead → no internet (recover with `nord-rand kill off` or `sudo systemctl restart nordvpnd`); 5 unavailable attempts → exit 1; cron silently drops mail (no MTA) — visibility lives in `~/Desktop/nord-rand.log`.

## nvim-config/ — vendored LazyVim starter

Byte-identical snapshot of the deployed `~/.config/nvim/`; `utils.sh` step 8 seeds from it (`rm -rf` + `cp -a`). Same role as `backup.zshrc`, except this one is deploy-ready as-is (no tokens stripped). Currently upstream LazyVim starter, unmodified: custom plugin specs go under `lua/plugins/`, config under `lua/config/`. `lazy-lock.json` is tracked so plugin versions stay deterministic — commit lockfile changes after upgrading the deployed copy. Re-running `utils.sh` overwrites `~/.config/nvim/` unconditionally; stash hand-tweaks first.

## Removed: installers/discontinued/

Deleted in `baaa81c` (by `utils.sh` step 0's prompt during the 2026-08-02 run). `install-lxqt.sh` dropped LXQt + SDDM alongside XFCE with a bilingual us/ru keyboard, brightnessctl F5/F6, FancyMenu panel, Albert on alt+space, and `xcape` mapping bare-Meta to `XF86LaunchA`; it had no `--uninstall` (purging LXQt from inside LXQt is a TTY-rescue recipe) and overwrote every config unconditionally. `debloat-xfce.sh` stripped XFCE after switching DE, with two hard-fail preflights (session must not be XFCE; `xfwm4` must exist so a "0 packages" exit can't mask a bad invocation); bring XFCE back with `sudo apt install xfce4`. Recover either verbatim: `git show 08a71c5:installers/discontinued/install-lxqt.sh`.
