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
launchers/        nic-boost  ufw-focus (+ ufw-focus.list.example)
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
6. NordVPN rotation: `install -m 755 nord-job/nord-rand ~/.local/bin/`; `crontab nord-job/nord-rand.cron`. Then `launchers/{nic-boost,ufw-focus}` → `~/.local/bin/` (and `ufw-focus.list.example` → `~/.config/ufw-focus/allow.list`), `autostarts/*.desktop` → `~/.config/autostart/`.
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

Runtime-only NIC tweaks for bandwidth-heavy work. They cost battery *exactly when traffic is low* (they remove idle-time hardware napping), so they're opt-in per session: `sudo iw dev <wifi> set power_save off` (~0.3–0.5 W extra at idle); `sudo ethtool --set-eee <eth> eee off` (~0.5 W extra on an idle link). Three shapes: bare (apply, persist); `nic-boost <cmd>` (apply, run, revert on exit via `trap 'set_nic on' EXIT INT TERM` — covers Ctrl-C/kill); `--off` (revert, takes no command). Plus `--dry-run` and `--` (end of options). Appends `/usr/sbin:/sbin` to `PATH` — `iw` lives there, and before 2026-11-03 `command -v iw` failed for a normal user so the WiFi half silently never ran. Preflight hard-fails on missing `sudo`/`iw`/`ethtool` (each only if needed). No modprobe/dispatcher files written — a reboot reverts to driver defaults.

### `ufw-focus` — website allowlist ("productivity mode")

Flips ufw's outgoing default to deny and allows only the IPs of the sites in `~/.config/ufw-focus/allow.list` (or `--list FILE` / `$UFW_FOCUS_LIST`). Modes: bare (on, or refresh — re-resolves DNS, replaces rules), `--off`, `--status`, `--dry-run`. Revert design: every rule carries comment `ufw-focus`; `--off` deletes rules found by that tag in `ufw status numbered` (bottom-up, so numbers don't shift) and restores the pre-focus outgoing default + ufw active/inactive from `/var/lib/ufw-focus/state`, written only on the first enable (a refresh must not overwrite it). Last-resort manual undo: `sudo ufw default allow outgoing`.
- Always allowed: DNS 53, DHCP 67/udp, NTP 123/udp, NordLynx 51820/udp, OpenVPN 1194, Tailscale 41641/udp, RFC1918 + 100.64/10, and `api.nordvpn.com` (nord-rand's 6-hourly reconnect). Dropping 51820 would kill the tunnel and the NordVPN kill switch would then cut everything.
- IP-level only: no wildcards, CDN IPs drift (re-run to refresh), established connections survive (restart browser). Each name is also tried as `www.<name>`.
- ufw output is localized (box is German) — all parsing goes through `LC_ALL=C`.
- After enabling it curls a non-listed probe (`example.com`…); if that loads, another firewall (NordVPN's) accepts first and it warns. **Not yet run for real** — needs sudo; only `--dry-run` verified as of 2026-11-03.
- Resolve loop: each `getent | awk` ends in `|| true` — under `set -e`+`pipefail` the first unresolvable name otherwise silently ended the loop.

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
