# steves_debian_setup

Personal setup repo for a fresh MX Linux XFCE install on a ThinkPad T480 (Intel UHD 620, x86_64, Liquorix kernel, X11). Turns a clean MX install into the working environment, plus a few apps without first-class Linux delivery. Gaming-specific scripts moved to [steves-gaming-utils](https://github.com/steve-berlin/steves-gaming-utils); Redmi-specific scripts moved to [steves-redmi-setup](https://github.com/steve-berlin/steves-redmi-setup).

## Layout

```
installers/                 utils.sh, check-setup.sh, install-anki.sh, setup_nordvpn.sh
  tmux_setup/               install-tmux-{immortal,expose,dim}.sh
  patches/                  vendored upstream patches (tmux dim)
  discontinued/             not on default path; kept for institutional knowledge
debloat_scripts/            debloat-{mx,kde,nvidia}.sh
launchers/                  nic-boost
autostarts/                 *.desktop for ~/.config/autostart
nord-job/                   nord-rand + nord-rand.cron (6-hourly NordVPN rotation)
nvim-config/                vendored LazyVim starter (utils.sh seeds ~/.config/nvim)
backup.zshrc                reference copy of ~/.zshrc (don't source — tokens stripped)
backup.tmux.conf            reference copy of ~/.tmux.conf (prefix C-a + tpm/resurrect/continuum/expose)
```

## Install order on a fresh box

1. `installers/utils.sh` — bulk apt + toolchains + oh-my-zsh + seeds nvim. Everything else assumes this ran.
2. `installers/check-setup.sh` — verifies step 1. Exit 0 = clean.
3. `installers/setup_nordvpn.sh` — only if you want NordVPN.
4. App installers (each independent): `install-anki.sh`, `debloat_scripts/debloat-{mx,nvidia,kde}.sh` (each opt-in: KDE needs `plasma-desktop`; nvidia for Intel-iGPU-only boxes). Discontinued: `install-lxqt.sh`, `debloat-xfce.sh`.
5. Tmux: `tmux_setup/install-tmux-{immortal,expose,dim}.sh`.
6. NordVPN rotation: `install -m 755 nord-job/nord-rand ~/.local/bin/`; `crontab nord-job/nord-rand.cron`.
7. `launchers/nic-boost` → `~/.local/bin/`.
8. `autostarts/*.desktop` → `~/.config/autostart/`.

## Conventions every installer follows

- `#!/usr/bin/env bash` + `[ -z "${BASH_VERSION:-}" ]` re-exec guard — catches `sh installers/foo.sh` before dash trips on bashisms.
- `set -euo pipefail`. `--dry-run` prints actions, mutates nothing (combinable with mode flags). Idempotent: re-run on an installed box = no-op.
- Standard modes: bare / `--reinstall` / `--uninstall` / `--dry-run`. Per-script notes call out deviations.
- No creds, no scraping behind logins, no `curl | sudo bash` of unaudited third parties.
- Hard-fail loud on missing deps in a `preflight` block. Sudo called inline, never via script-wide re-exec.
- **Track multi-step work in real time.** Tasks with ≥3 discrete steps use TaskCreate/TaskUpdate; mark `in_progress` BEFORE starting a step, `completed` immediately when done (don't batch). For multi-commit work, one task per commit so progress maps 1:1 to git history. Surfaces partial-failure state and avoids "what was Claude in the middle of" ambiguity on interruption.

## Not in this repo

Live `~/.zshrc` (tokens — `backup.zshrc` is the stripped copy). Gaming partitions (`/games/{steam,minecraft}`), Roblox/Steam/Minecraft runtime data, and Waydroid/Android-x86 VM state are documented in the sister gaming/redmi repos.

---

## installers/

### `utils.sh` — bulk bootstrap

Resolves every dep referenced by `~/.zshrc`: apt packages, oh-my-zsh + plugins, fzf, user toolchains (rustup, rbenv, atuin, starship, nvm, deno, bun, pyenv), Go + neovim tarballs, third-party installers (brave, waydroid), pip tools, flatpak + Organic Maps, Claude Code, NordVPN, tmux config, helper scripts, XFCE + KDE keybindings, EasyEffects presets. **Step 0** (before any install) offers via a y/N prompt to delete `installers/discontinued/` — interactive-tty only; `--dry-run` and non-interactive/piped runs keep the scripts. **Step 8** seeds `~/.config/nvim/` from vendored `nvim-config/` via `rm -rf` + `cp -a` (was an upstream `git clone LazyVim/starter`); overwrites unconditionally. Sections 1–15 match `check-setup.sh`'s verification order; step 14 is a no-op stub (debloat moved to `debloat_scripts/`). `shr` helper prints a short summary in `--dry-run` instead of the whole pipe for curl-piped installers + heredoc writes.

### `check-setup.sh` — post-bootstrap verifier

Mirrors `utils.sh` step-for-step, prints `[OK]`/`[FAIL]`. Exit 0 if all pass. Run after `utils.sh` or after any system upgrade touching the GPU stack (iGPU/nouveau check catches regression).

### `install-anki.sh` — official upstream tarball

Debian's `anki` lags by years. Since 25.07, Anki's official Linux delivery is the **anki-launcher** tarball — tiny launcher pulls the real app on first run. Script picks newest GitHub release with the launcher asset, hands off to Anki's installer (writes `/usr/local`). User decks at `~/.local/share/Anki2` untouched. Deps: `bash curl tar` (with `--zstd` — modern GNU tar, or `apt install zstd`), `awk sudo`. No `jq` — release lookup is `curl | awk`. Asset regex: `anki-launcher-.*-linux[.]tar[.]zst$` (use `[.]`, not `\.` — `awk -v` strips one backslash). GitHub anon API rate limit 60/hr per IP; symptom is empty `url`.

Gotchas — do not reintroduce:
1. **Don't `exit` from the awk parsing the GitHub API.** Closing the pipe early sends curl SIGPIPE; with `pipefail` the `url=$(curl … | awk …)` substitution silently fails. Use a `seen` flag, let curl finish writing.
2. **Don't `local tmp` for the scratch dir referenced by the EXIT trap.** Trap fires after the function returns, local is gone, `set -u` blows up with `tmp: unbound variable`. Keep `tmp` at script scope, reference as `${tmp:-}` in the trap.

Layout: `/usr/local/bin/anki`, `/usr/local/share/anki/`, `~/.local/share/Anki2/` (decks/media), `~/.cache/Anki2/` (downloaded real app, regeneratable).

### `setup_nordvpn.sh` — replace snap with official deb

Removes snap nordvpn, runs official install.sh, adds user to `nordvpn` group. Log out/in for the group change.

---

## installers/tmux_setup/

### `install-tmux-immortal.sh` — persist tmux sessions across reboots

Drops `~/.tmux/plugins/{tpm,tmux-resurrect,tmux-continuum}`; `~/.tmux.conf` (only if absent); `~/.config/autostart/tmux-immortal.desktop` (starts detached `main` session at login). `--uninstall` nukes plugins + autostart, leaves `~/.tmux.conf` alone.

- **Never overwrites an existing `~/.tmux.conf`.** Prints the four lines to add. An earlier draft used a header marker to detect "we own this file" + overwrite, but broke when the user *appended* the marker to a hand-rolled config — re-runs clobbered the prefix rebind.
- **Headless plugin install needs a live tmux server.** `tpm/bin/install_plugins` reads its path via `tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH` (tmux's global env, not bash). Throwaway `_tpm_init` session running `sleep 30` keeps a server alive during install.
- **Autostart spawns `tmux new-session -d -s main`, not `start-server`.** A server with zero sessions exits immediately; `main` is a placeholder, continuum adds saved sessions on top at server-start.
- **Continuum saves every 15 min.** Faster = disk churn for marginal gain (resurrect's pane-content capture isn't free on big scrollback).

Usage: sessions auto-restore at login because `@continuum-restore 'on'` + the autostart `.desktop` together fire continuum's restore hook on server start. Manual save `prefix + Ctrl-s`, manual restore `prefix + Ctrl-r` (resurrect defaults). State at `~/.tmux/resurrect/last` (+ `pane_contents.tar.gz` since `@resurrect-capture-pane-contents 'on'`). Re-attach after login with `tmux a`; `tmux ls` should show `main` (autostart placeholder) plus any restored sessions. First save lands ~15 min after first real use — don't reboot inside that window expecting state.

### `install-tmux-expose.sh` — Mission Control-style session switcher

Cargo-installs `tmux-expose` (cesarferreira/tmux.expose, Rust TUI with live text thumbnails) + registers the TPM plugin line in `~/.tmux.conf`. `--uninstall` strips the plugin line via `sed`. Preflight: `cargo` on PATH (fails loud if `utils.sh` rustup section hasn't run). Plugin line inserted *before* the `run '…/tpm/tpm'` line because tpm only manages plugins declared above its run-tpm call. Same throwaway-tmux-session dance as immortal for headless TPM install. Idempotent.

Usage: `Alt+e` (root key table, no prefix) opens a fullscreen popup. Inside: arrow keys move, type any letter to fuzzy-filter session names, Backspace edits the query, Enter switches, Esc/Ctrl-C (or `Alt+e` again) quits without switching. Mouse click also switches. No `hjkl` and no `q` — upstream dropped both. Override the binding with `set -g @tmux-expose-key 's'` + `set -g @tmux-expose-key-table 'prefix'` (or any other key table) *before* the `@plugin` line. Override the grid shape with `set -g @tmux-expose-command 'tmux-expose --columns 2'` (or `--thumbnail-width N`). Anchor + size knobs: `@tmux-expose-anchor` (`center`/`top`/`bottom`/`left`/`right`) + `@tmux-expose-{width,height}` (e.g. `'50%'`). CLI sanity check outside the plugin: `tmux-expose` standalone in any pane gives the same UI without the popup wrapper — use when debugging keybinds.

### `install-tmux-dim.sh` — build patched tmux with inactive-pane dim

Builds tmux 3.5a from source with `patches/tmux-dim-inactive-panes.patch` (chud-methodology) into `/usr/local/bin/tmux`, shadowing `/usr/bin/tmux`. Dims every cell in inactive panes via perceptual-luma desaturation (30%) + blend toward pane bg (35%). Works for arbitrary ANSI content (lazygit, syntax highlighting) — `window-style` alone only affects cells using terminal default colors. `--uninstall` removes the `/usr/local` binary only. Override pinned version with `TMUX_VERSION=3.5a`.

- **`patch --dry-run -p1` non-optional before the real apply.** Future tmux drift past the hunks would otherwise silently produce a tmux with no dimming and no error.
- **Stamp at `/usr/local/share/tmux-dim.version`.** Re-run with same `TMUX_VERSION` is a no-op.
- **Installs to `/usr/local`, not `/usr/bin`.** `/usr/local/bin` precedes `/usr/bin`; apt upgrade of distro `tmux` can't clobber, `--uninstall` cleanly reverts.
- **Build deps probed individually.** `cc make pkg-config patch curl tar` via `command -v`; `libevent-dev libncurses-dev bison` via `dpkg -s`.

Usage: no opt-in — the patched binary at `/usr/local/bin/tmux` shadows distro tmux and dims every inactive pane automatically. Sanity: `which tmux` → `/usr/local/bin/tmux`; `cat /usr/local/share/tmux-dim.version` → pinned version stamp. Verify behavior by splitting (`prefix + "`) and hopping focus (`prefix + ;`) — the unfocused pane visibly desaturates. No runtime config knobs: dim factors are baked into the patch (30% luma desat + 35% blend toward pane bg). Existing tmux servers continue running the old `/usr/bin/tmux` until restarted — `tmux kill-server` (or log out + back in, which the autostart respawns) to pick up the patched binary.

The Neovim companion (`tint.nvim` Lua transform matching the C algorithm byte-for-byte, FocusLost/FocusGained autocmds to prevent double-dimming) is not yet in `nvim-config/`. Drop under `lua/plugins/` when adding. `theme-palette.patch` (ANSI16-palette awareness) not vendored — requires build-time `theme_palette.h` gen, overkill outside Nix.

---

## installers/patches/

- **`tmux-dim-inactive-panes.patch`** — origin: chud-methodology (anonymous.4open.science/r/chud-methodology-1477). Adds `colour_dim()` to `colour.c`, a `dim_inactive` flag on `struct tty`, and hooks in `screen-redraw.c`/`screen-write.c`/`tty.c` that set/clear it around per-pane draws. Applied by `tmux_setup/install-tmux-dim.sh` against the tmux 3.5a tarball; `patch --dry-run` first so future tmux drift fails loud instead of producing a silently unpatched binary.

---

## debloat_scripts/

All `--dry-run`-able and idempotent. Share an `expand_installed` helper that accepts literals + globs (e.g. `'libreoffice-*'`), enumerates via `dpkg-query`, filters to installed-only — one apt purge call, re-runs are no-ops.

### `debloat-mx.sh` — strip MX Linux bundled apps

Preflights `/etc/mx-version` (hard-fails on vanilla Debian). Removes in inline-commented groups in a single `to_remove` array: welcome (`mx-welcome`/`-tour`); misc (`mx-updater`, `-packageinstaller*`, `-viewer`, `-flash`, `-codecs`); settings GUIs duplicating XFCE Settings (`mx-keyboard`/`-locale`/`-date-time`/`-user`/`-menu-editor`/`-system-keyboard*`); niche network helpers (`mx-rsync`, `-samba-config`, `-find-shares`, `-network-assistant`, `-service-manager`); theme/sound packs (`mx-artwork`, `-faenza-icons`, `-select-sound`, `-system-sounds`, `-quick-system-info`); `mx-comp-mgr`; heavyweights from old `utils.sh` step 14 (`gimp`, `vlc*`, `libreoffice-*`, `strawberry`, `gmtp`, `deb-installer`, `qpdfview`, `catfish`, `lo-main-helper`); CD/DVD burn/rip (`xfburn`, `asunder`, `brasero*`, `k3b*`, `xcdroast`, `gnomebaker`, `mybashburn`). Kept: `mx-tools`, `-snapshot`, `-cleanup`, `-tweak`, `-repo-manager`, `-iso-dump`, `-software-defaults`, `-default-settings`, `-keyring`. Opt-in (commented): `mx-conky`, `mxlive-usb-maker`, `mx-remastercc`, `mx-installer`. For old `--intel-only`, see `debloat-nvidia.sh`.

### `debloat-nvidia.sh` — purge nvidia + nouveau (Intel-iGPU-only boxes)

Standalone counterpart to old `debloat-mx.sh --intel-only`. Purges `nvidia-*`/`libnvidia-*`/`xserver-xorg-video-nouveau`, writes `/etc/modprobe.d/blacklist-nouveau.conf` (`blacklist nouveau` + `options nouveau modeset=0`), reruns `update-initramfs -u`. Saves ~500 MB and frees the iGPU from DRM contention. `--uninstall` removes blacklist only. Hard-fail preflight refuses if `lspci -nn -d ::0300/0302/0380` reports an NVIDIA GPU — purging on a box with a discrete card drops X to llvmpipe or hangs at boot. No override flag by design.

### `debloat-kde.sh` — strip a Debian/MX KDE Plasma install

Won't run unless `plasma-desktop` is present. Adapted from cl0v3r404's [Debloat-KDE-Plasma-Debian](https://github.com/cl0v3r404/Debloat-KDE-Plasma-Debian), rewritten in English, extended for PIM/Akonadi, Plasma widget addons, niche services + Baloo disable, made idempotent. `--no-bluetooth` also purges bluedevil/bluez/blueman (off by default — most laptops want BT). No `--uninstall` — reinstall individual packages.

Removal groups: legacy KDE apps (konqueror+plugins, akregator, kmail/korganizer/kaddressbook/kontact/kleopatra/kgpg, kdepim-runtime, kwrite, xterm, dragonplayer/juk/elisa, goldendict-ng, debian-reference-common, khelpcenter); CJK/non-Latin input (full fcitx + fcitx5, mozc +uim/utils, anthy, ibus, xiterm+thai); `kdegames` meta + 30+ packages (meta removal is the point — autoremove drags games back otherwise); `kde-edu` meta; legacy utilities (kfind, kompare, kget, sweeper, k3b, kjots/knotes, kruler/kcharselect/kcolorchooser, kbackup, kolourpaint); gimp; services + niche (kdeconnect, krdc/krfb, plasma-vault, okteta, kfontview, kdf, kup-backup, kontrast, ksystemlog, kdebugsettings, `'phonon*-backend-vlc'`); cosmetic (`plasma-workspace-wallpapers`, `oxygen-icon-theme`, `oxygen-sounds`); Debian doc cruft (`doc-debian`, `'installation-guide-*'`); bluetooth via `--no-bluetooth`. **Akonadi PIM stack**: `'akonadi-*'` + `'kdepim-*'` plus `mariadb-server`/`-server-core`/`default-mysql-server` — Akonadi pulls a real RDBMS as Recommends, autoremove leaves it behind. **Plasma extras**: `plasma-widgets-addons`/`-runners-addons`/`-wallpapers-addons`/`-dataengines-addons`/`kdeplasma-addons` — slims widget picker + KRunner, stops background data-engine daemons. Panel/desktop/KWin untouched.

Language filter (dynamic): enumerates installed `kde-l10n-*`/`firefox-esr-l10n-*`/`thunderbird-l10n-*`/`hunspell-*`/`aspell-*`/`myspell-*`/`manpages-*`/`task-*-desktop`; keeps anything matching `*-en|*-en-*|*english*|*-de|*-de-*|*german*` (plus base `manpages`/`-dev`/`-posix*`), purges the rest. Keyboard layouts + `xkb-data` untouched — language-pack purge, not input-method. After: rewrites `/etc/locale.gen` to `en_US.UTF-8 UTF-8` + `de_DE.UTF-8 UTF-8` and reruns `locale-gen`.

Plasma config tweaks (per-user, `kwriteconfig6` / fallback `kwriteconfig5`) — **invoke as desktop user, NOT sudo** or configs land in `/root/.config`: `ksmserverrc` → `loginMode=emptySession` (no session restore; saves 50–100 MB at every login); `kdeglobals` → `AnimationDurationFactor=0`; `dolphinrc` → `Plugins=imagethumbnail,jpegthumbnail,svgthumbnail,exrthumbnail` (keeps image thumbs, kills ffmpegthumbs/poppler/taglib spawns on folder browse — only written when key not already set; earlier draft overwrote and wiped per-user plugin choices).

**Defensive pre-step (load-bearing — added after prior versions bricked the desktop on autoremove cascade):** before any purge, `apt-mark manual`s every load-bearing KDE package installed — `plasma-desktop`, `plasma-workspace`, `plasma-framework`, `kwin-x11/wayland/common`, `sddm`, `systemsettings`, `kio`/`kio-extras`, `dolphin`, `konsole`, `plasma-nm`, `plasma-pa`, `powerdevil`, `kscreen`/`kscreenlocker`, `breeze*`, `qt6-wayland`. Without this, final `apt autoremove --purge -y` cascades into core Plasma packages whose only manual rdep was a removed meta — desktop gone next login. Idempotent + reversible (`apt-mark auto <pkg>`). Also: holds `kdeaccessibility` (older Debian lists it Recommends on KDE metas, autoremove drops it); adds `plasma-discover-backend-flatpak`, `kde-config-flatpak`, `kde-config-plymouth` (filtered through `available_only` so MX's slimmer repos don't hard-fail when missing).

Post-removal: `balooctl6 disable` (fallback `balooctl` for KF5) stops the Baloo file indexer — doesn't purge `baloo-kf6` (KDE apps link against it), just stops the daemon, recovering CPU + ending SSD churn.

---

## launchers/

### `nic-boost` — temporary WiFi/EEE perf boost

Runtime-only NIC tweaks for bandwidth-heavy work. Settings cost battery *exactly when traffic is low* (remove idle-time hardware napping), so opt-in per session: `sudo iw dev <wifi> set power_save off` (~0.3-0.5 W extra at idle); `sudo ethtool --set-eee <eth> eee off` (~0.5 W extra on idle link). Three shapes: bare (apply, persist); `nic-boost <cmd>` (apply, run cmd, revert on exit via `trap revert EXIT INT TERM` — covers Ctrl-C/kill); `--off` (revert). No modprobe/dispatcher files written — settings revert on reboot via kernel driver defaults.

---

## autostarts/

XFCE `.desktop` autostart files for `~/.config/autostart/` (per user) or `/etc/xdg/autostart/` (system). XFCE runs `Exec=`; `X-GNOME-Autostart-enabled=true` is honored despite the prefix.

- **`alacritty-autostart.desktop`**: `alacritty --gapplication-service` so subsequent invocations attach to the running service. `Hidden=true` + `NoDisplay=true` keep it out of the application menu so users can't accidentally toggle it off in Session and Startup.
- **`brave-autostart.desktop`**: `brave-browser` at login. Disable on low-RAM machines.
- **`easyeffects.desktop`**: same `--gapplication-service` pattern. Required for presets (EQ, autogain) to apply to every audio stream from session start.

`nohup` in `Exec=` is defensive — XFCE detaches autostart already, but `nohup` shields against a stray HUP from the launching shell. Trailing `&` is spec-ignored but harmless.

---

## nord-job/ — random NordVPN country rotation

Files: `~/.local/bin/nord-rand` (NordLynx, kill switch, threat protection, autoconnect baked into `setup` mode); `nord-rand.cron`; `~/Desktop/nord-rand.log` (ISO-8601, append-only); SD-card backup at `/media/fred/8B35-3F46/nord-rand{,.cron}` (FAT/exFAT drops +x — `chmod +x` after copy back).

Modes: bare `nord-rand` (random country, **skip if already connected**); `force` (disconnect-and-reconnect — **what cron runs**); `setup` (one-time config: technology + protections, enables autoconnect, tries `post-quantum`); `kill on|off` (kill switch — `off` is the escape hatch). Cron: `0 */6 * * * $HOME/.local/bin/nord-rand force >/dev/null 2>&1` (output silenced; script logs internally).

**Autoconnect ↔ option-B conflict**: user picked "skip if connected" but also enabled NordVPN autoconnect, which keeps VPN up 24/7 so plain `nord-rand` would never rotate. Cron uses `force`; manual invocations default to soft skip. Revert to literal option B by dropping `force` from the cron line.

Country list pulled live every invocation. `list_countries()` strips ANSI, normalizes whitespace/commas to one country per line, drops separator dashes; CLI naming (underscores, e.g. `United_Kingdom`) preserved. Retry tolerates up to `MAX_TRIES` (5) unavailable picks. Restrict pool (e.g. EU-only) by filtering inside `list_countries`. Prereqs the script doesn't handle: nordvpn daemon + user in `nordvpn` group; `nordvpn login` run interactively once; `nord-rand setup` once after login.

Failure modes: kill switch ON + daemon dead → no internet (recover with `nord-rand kill off` or `sudo systemctl restart nordvpnd`); 5 attempts all unavailable → exit 1; cron silently drops mail (no MTA) — visibility in `~/Desktop/nord-rand.log`.

---

## nvim-config/ — vendored LazyVim starter

Byte-identical snapshot of deployed `~/.config/nvim/`. `installers/utils.sh` step 8 seeds `~/.config/nvim/` from this dir (`rm -rf` + `cp -a`). Same role as `backup.zshrc`: the in-repo copy is canonical. Unlike `backup.zshrc` (tokens stripped), `nvim-config/` is deploy-ready as-is.

Currently upstream LazyVim starter, unmodified. Custom plugin specs under `lua/plugins/`, config under `lua/config/`. `lazy-lock.json` tracked so plugin versions stay deterministic — commit lockfile changes after upgrading on deployed copy. Re-running `utils.sh` overwrites `~/.config/nvim/` unconditionally; stash local hand-tweaks first. tint.nvim companion to the chud tmux dim patch (see `tmux_setup/install-tmux-dim.sh`) is now feasible to drop in.

---

## installers/discontinued/

Scripts kept on disk for institutional knowledge. Not on the default install path; still pass `bash -n`.

### `install-lxqt.sh` — LXQt + bilingual keyboard + Albert

Drops `lxqt + sddm` alongside XFCE (pick at SDDM login). Pre-seeds: bilingual us/ru keyboard (Meta+Space toggle), F5/F6 brightness via `brightnessctl`, bottom panel with FancyMenu, Albert as alt+space launcher, `xcape` autostart turning bare-Meta tap into `XF86LaunchA` (menu on Super alone). No `--uninstall` — purging LXQt while logged into LXQt is a TTY-rescue recipe. Albert from upstream OBS repo (key under `/etc/apt/keyrings/albert.gpg`); skipped if on PATH. Every config file overwritten unconditionally — hand-edits to `~/.config/{lxqt,albert}/*.conf` + the two `~/.config/autostart/*.desktop` entries don't survive rerun.

### `debloat-xfce.sh` — strip XFCE after switching to another DE

Two hard-fail preflights: active session must NOT be XFCE (refuses if `$XDG_CURRENT_DESKTOP` is `*xfce*`); XFCE must be installed (`xfwm4` check, so a "0 packages" exit can't mask a bad invocation). Removal: metas (`xfce4`, `task-xfce-desktop`, `xfce4-goodies`); core (xfwm4, xfdesktop4, xfconf, xfce4-session/settings/panel/notifyd/appfinder/power-manager); wildcards (`'xfce4-*'`, `'libxfce4*'`, `'thunar-*'`); apps (thunar, mousepad, ristretto, parole, orage); `'xubuntu-*'`. Bring back: `sudo apt install xfce4`.
