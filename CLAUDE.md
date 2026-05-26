# steves_debian_setup

Personal setup repo for a fresh MX Linux XFCE install on a ThinkPad T480 (Intel UHD 620, x86_64, Liquorix kernel, X11). Turns a clean MX install into the working environment, plus installs/launches games and apps without first-class Linux delivery.

## Layout

```
installers/                 utils.sh, check-setup.sh, install-anki.sh, setup_nordvpn.sh
  gaming/                   install-{steam,tld,scrcpy,nic-tuning}.sh
  tmux_setup/               install-tmux-{immortal,expose,dim}.sh
  patches/                  vendored upstream patches (tmux dim)
  discontinued/             not on default path; kept for institutional knowledge
debloat_scripts/            debloat-{mx,kde,nvidia,redmi}.sh
launchers/                  stm, rbx, rbxvm, redmi-gaming, nic-boost
autostarts/                 *.desktop for ~/.config/autostart
nord-job/                   nord-rand + nord-rand.cron (6-hourly NordVPN rotation)
nvim-config/                vendored LazyVim starter (utils.sh seeds ~/.config/nvim)
backup.zshrc                reference copy of ~/.zshrc (don't source — tokens stripped)
```

The Android-x86 VM runtime data lives in `~/android-vm/` (qcow2 + ISO, not committed).

## Install order on a fresh box

1. `installers/utils.sh` — bulk apt + toolchains + oh-my-zsh + seeds nvim. Everything else assumes this ran.
2. `installers/check-setup.sh` — verifies step 1. Exit 0 = clean.
3. `installers/setup_nordvpn.sh` — only if you want NordVPN.
4. Game/app installers (each independent): `gaming/install-{steam,tld,scrcpy,nic-tuning}.sh`, `install-anki.sh`, `debloat_scripts/debloat-{mx,nvidia,kde,redmi}.sh` (each opt-in: KDE needs `plasma-desktop`; nvidia for Intel-iGPU-only boxes; redmi needs a Redmi 4A on LineageOS via ADB). Discontinued: `install-{roblox,android-vm,lxqt}.sh`, `check-roblox-prereqs.sh`, `debloat-xfce.sh`.
5. Tmux: `tmux_setup/install-tmux-{immortal,expose,dim}.sh`.
6. NordVPN rotation: `install -m 755 nord-job/nord-rand ~/.local/bin/`; `crontab nord-job/nord-rand.cron`.
7. `launchers/{stm,rbx,rbxvm,redmi-gaming,nic-boost}` → `~/.local/bin/`. The `skl` Minecraft launcher is a zsh alias in `backup.zshrc`.
8. `autostarts/*.desktop` → `~/.config/autostart/`.

## Conventions every installer follows

- `#!/usr/bin/env bash` + `[ -z "${BASH_VERSION:-}" ]` re-exec guard — catches `sh installers/foo.sh` before dash trips on bashisms.
- `set -euo pipefail`. `--dry-run` prints actions, mutates nothing (combinable with mode flags). Idempotent: re-run on an installed box = no-op.
- Standard modes: bare / `--reinstall` / `--uninstall` / `--dry-run`. Per-script notes call out deviations.
- No creds, no scraping behind logins, no `curl | sudo bash` of unaudited third parties (waydroid_script under `~/install_roblox/` is the one exception, in the discontinued Roblox installer).
- Hard-fail loud on missing deps in a `preflight` block. Sudo called inline, never via script-wide re-exec.
- **Track multi-step work in real time.** Tasks with ≥3 discrete steps use TaskCreate/TaskUpdate; mark `in_progress` BEFORE starting a step, `completed` immediately when done (don't batch). For multi-commit work, one task per commit so progress maps 1:1 to git history. Surfaces partial-failure state and avoids "what was Claude in the middle of" ambiguity on interruption.

## Gaming partitions

`/games/steam` (sda3) + `/games/minecraft` (sda4) mounted via `/etc/fstab`. Launchers + `gaming/install-tld.sh` hard-code those paths; edit constants at script top on a different box. See `~/CLAUDE.md` for disk layout and why Steam itself stays in `~/.steam` while only game *content* lives on `/games/steam`.

## Not in this repo

Live `~/.zshrc` (tokens — `backup.zshrc` is the stripped copy); Roblox APK, Waydroid image, Steam game data, Minecraft worlds (fetched on demand); `~/install_roblox/{waydroid_script,venv}/` (runtime-created); VM disk + ISO under `~/android-vm/` (created by `install-android-vm.sh`).

---

## installers/

### `utils.sh` — bulk bootstrap

Resolves every dep referenced by `~/.zshrc`: apt packages, oh-my-zsh + plugins, fzf, user toolchains (rustup, rbenv, atuin, starship, nvm, deno, bun, pyenv), Go + neovim tarballs, third-party installers (brave, waydroid), pip tools, flatpak + Organic Maps, Claude Code, NordVPN, tmux config, helper scripts, XFCE + KDE keybindings, EasyEffects presets. **Step 8** seeds `~/.config/nvim/` from vendored `nvim-config/` via `rm -rf` + `cp -a` (was an upstream `git clone LazyVim/starter`); overwrites unconditionally. Sections 1–15 match `check-setup.sh`'s verification order; step 14 is a no-op stub (debloat moved to `debloat_scripts/`). `shr` helper prints a short summary in `--dry-run` instead of the whole pipe for curl-piped installers + heredoc writes.

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

## installers/gaming/

### `install-steam.sh` — Steam from apt + non-free

Adds i386 + (on Debian) `contrib non-free non-free-firmware`, installs `steam-installer` (Debian) / `steam` (Ubuntu). Does NOT touch `libraryfolders.vdf` — `stm` registers `/games/steam` on first run.

### `install-tld.sh` — The Long Dark (re)installer

Wraps Steam URL handlers for AppID `305620`, routes through `stm` so the perf profile applies. `--verify` does `steam://validate/` (re-hash + redownload corrupt). Preflights: `stm`+`steam` on PATH, `libraryfolders.vdf` exists, `/games/steam` library registered (redundant with `stm` but catches Steam-already-running), mounted (`mountpoint -q`, stricter than `-d`) + writable + ≥12 GiB free.

### `install-scrcpy.sh` — upstream scrcpy, shadowing distro under /usr/local

Debian's `scrcpy` lags by 6-12 months, missing v3 features (virtual-display, audio passthrough, camera mirroring) that pair with `rbxvm` and Waydroid. Fetches prebuilt `scrcpy-linux-x86_64-vX.Y.Z.tar.gz` into `/usr/local/share/scrcpy/` with a thin wrapper at `/usr/local/bin/scrcpy`. `/usr/local/bin` precedes `/usr/bin` so upstream wins.

- **Runtime deps via `apt install scrcpy`.** Distro Depends covers `adb`/`libav*`/`libsdl2-2.0-0`/`libusb-1.0-0` without pinning sonames that drift. Trixie **dropped scrcpy**; fallback `adb ffmpeg libsdl2-2.0-0 libusb-1.0-0 libv4l-0` fires on every Trixie install (`libv4l-0` → `libv4l-0t64` per t64 transition).
- **Shadow, don't replace.** `/usr/bin/scrcpy` stays as fallback; `--uninstall` reverts cleanly. On Trixie no distro scrcpy → `--uninstall` leaves the box with none.
- **Don't symlink `$BIN`→`$SHARE/scrcpy`.** v4.0 is a static binary locating `scrcpy-server` via XDG/`/usr/local/share/scrcpy` (symlink-safe). v3.x is a shell wrapper doing `cd "$(dirname ${0})"` + `exec ./scrcpy-bin` with `LD_LIBRARY_PATH=$PWD` — symlink would resolve `dirname` to `/usr/local/bin` and break it. Thin wrapper `exec`s the bundled entrypoint at its real `$SHARE` path so either layout works.
- **`sudo chown -R root:root $SHARE` after `cp -a`** — `cp -a` preserves tarball uid (typically 1000).
- **Same awk/SIGPIPE gotcha as `install-anki.sh`.** Stamp at `/usr/local/share/scrcpy.version` (re-run is no-op; `--reinstall` forces). Asset regex: `scrcpy-linux-x86_64-v[0-9].*[.]tar[.]gz$`.

### `install-nic-tuning.sh` — permanent NIC tuning (zero power cost)

Drops `/etc/sysctl.d/99-nic-tuning.conf` (BBR + fq, larger buffers, TFO, MTU probing); `/etc/NetworkManager/dispatcher.d/99-nic-tuning` (per-eth-iface WoL off + ring buffers max); `~/.local/bin/nic-boost` (copied from `launchers/nic-boost`, 755). `--uninstall` removes all three. Hard-fails on missing `ethtool`/`sysctl`.

Split is deliberate: this script only writes zero-power-cost settings. Energy-hungry settings (WiFi `power_save=0`, ethernet EEE off) cost battery *exactly when traffic is low* — those live in `nic-boost` (opt-in per session, revert on reboot). Dispatcher bails early on wifi (`exit 0` if `/sys/class/net/$iface/wireless` exists) — ethernet-only on purpose.

---

## installers/tmux_setup/

### `install-tmux-immortal.sh` — persist tmux sessions across reboots

Drops `~/.tmux/plugins/{tpm,tmux-resurrect,tmux-continuum}`; `~/.tmux.conf` (only if absent); `~/.config/autostart/tmux-immortal.desktop` (starts detached `main` session at login). `--uninstall` nukes plugins + autostart, leaves `~/.tmux.conf` alone.

- **Never overwrites an existing `~/.tmux.conf`.** Prints the four lines to add. An earlier draft used a header marker to detect "we own this file" + overwrite, but broke when the user *appended* the marker to a hand-rolled config — re-runs clobbered the prefix rebind.
- **Headless plugin install needs a live tmux server.** `tpm/bin/install_plugins` reads its path via `tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH` (tmux's global env, not bash). Throwaway `_tpm_init` session running `sleep 30` keeps a server alive during install.
- **Autostart spawns `tmux new-session -d -s main`, not `start-server`.** A server with zero sessions exits immediately; `main` is a placeholder, continuum adds saved sessions on top at server-start.
- **Continuum saves every 15 min.** Faster = disk churn for marginal gain (resurrect's pane-content capture isn't free on big scrollback).

### `install-tmux-expose.sh` — Mission Control-style session switcher

Cargo-installs `tmux-expose` (cesarferreira/tmux.expose, Rust TUI with live text thumbnails) + registers the TPM plugin line in `~/.tmux.conf`. Default binding `Alt+e` opens a fullscreen grid; arrows/`hjkl` move, Enter switches, q/Esc quits. `--uninstall` strips the plugin line via `sed`. Preflight: `cargo` on PATH (fails loud if `utils.sh` rustup section hasn't run). Plugin line inserted *before* the `run '…/tpm/tpm'` line because tpm only manages plugins declared above its run-tpm call. Same throwaway-tmux-session dance as immortal for headless TPM install. Idempotent.

### `install-tmux-dim.sh` — build patched tmux with inactive-pane dim

Builds tmux 3.5a from source with `patches/tmux-dim-inactive-panes.patch` (chud-methodology) into `/usr/local/bin/tmux`, shadowing `/usr/bin/tmux`. Dims every cell in inactive panes via perceptual-luma desaturation (30%) + blend toward pane bg (35%). Works for arbitrary ANSI content (lazygit, syntax highlighting) — `window-style` alone only affects cells using terminal default colors. `--uninstall` removes the `/usr/local` binary only. Override pinned version with `TMUX_VERSION=3.5a`.

- **`patch --dry-run -p1` non-optional before the real apply.** Future tmux drift past the hunks would otherwise silently produce a tmux with no dimming and no error.
- **Stamp at `/usr/local/share/tmux-dim.version`.** Re-run with same `TMUX_VERSION` is a no-op.
- **Installs to `/usr/local`, not `/usr/bin`.** `/usr/local/bin` precedes `/usr/bin`; apt upgrade of distro `tmux` can't clobber, `--uninstall` cleanly reverts.
- **Build deps probed individually.** `cc make pkg-config patch curl tar` via `command -v`; `libevent-dev libncurses-dev bison` via `dpkg -s`.

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

### `debloat-redmi.sh` — disable LineageOS preinstalled apps on a Redmi 4A

Drives ADB to `pm disable-user --user 0` a curated list on a connected Redmi 4A (`rolex`). No root, no bootloader unlock; every action reversible with `--restore`. Modes: bare (SAFE list), `--include-optional`, `--restore`, `--list-only`, `--dry-run`. Preflight hard-fails: `adb` on PATH; exactly one authorized device (multi-device → prints serials, set `ANDROID_SERIAL`); `getprop ro.product.device` == `rolex`.

- **SAFE** (default): FOSS-replaceable, disabling does NOT break the phone — `jelly`, `email`, `gallery3d`, `eleven`, `messaging`, `audiofx`, `setupwizard`, `fmradio`, legacy `soundrecorder`.
- **OPTIONAL**: `calculator2`, `deskclock`, `org.lineageos.recorder`. `org.lineageos.trebuchet` commented out — disabling the default launcher with no replacement locks you out of the home screen.

Gotchas — do not reintroduce:
- **`adb shell` stdout uses CRLF.** Naive `sed 's/^package://'` leaves a stray `\r`; `grep -Fxq` then silently misses every match and reports every package as "not installed". Pipe through `tr -d '\r'` BEFORE the sed.
- **Use `pm disable-user --user 0`, not `pm uninstall --user 0`.** disable-user is reversible without sideloading the APK; uninstall is reversible only via factory reset or APK push.
- **Re-enable via `pm enable --user 0`, not bare `pm enable`.** Older pm silently no-ops bare `pm enable <pkg>` for things disabled per-user; `--user 0` matches the disable form.

---

## launchers/

Per-run wrappers; drop in `~/.local/bin/` (on PATH from `~/.zshrc`). Every launcher (and the `skl` alias) runs the **shared perf profile** first: `sudo systemctl stop tlp` (disable throttling); `sudo sysctl vm.swappiness=10`; `sudo cpupower frequency-set -g performance`. Reverted on next boot (TLP comes back via systemd; kernel resets defaults). Gaming-only, no permanent change.

### `stm` — Steam launcher

Apply perf profile, idempotently register `/games/steam` in `libraryfolders.vdf` (only when Steam isn't running — writing VDF under live Steam risks corruption), then `exec steam`. **Not** wrapped in `gamemoderun` — wrapping the Steam client breaks CEF rendering because `libgamemodeauto.so` gets `LD_PRELOAD`ed into every webhelper subprocess; use `gamemoderun %command%` as per-game launch option instead.

Steam itself stays in `~/.steam` on sda2; only game content goes on `/games/steam`. Set `/games/steam` as default in Settings → Storage; move existing games via Properties → Installed Files → Move Install Folder. VDF path is `~/.steam/debian-installation/steamapps/libraryfolders.vdf` on Debian (`steam-installer`); on Ubuntu it's `~/.steam/steam/steamapps/libraryfolders.vdf` — adjust `VDF=` at the top of `stm`.

### `rbx` — Roblox-on-Waydroid launcher

Order matters — the X11/weston step must land before session start, else the session daemon inherits no `WAYLAND_DISPLAY` and silently has no surface:

1. Start `waydroid-container.service` if not running (sudo, once per reboot). Apply perf profile.
2. On X11: spawn nested `weston --socket=wayland-1` at 1600x900, wait for socket under `$XDG_RUNTIME_DIR`, export `WAYLAND_DISPLAY=wayland-1`. Pinning the socket name keeps step 3 deterministic. On Wayland, no-op.
3. `setsid`-detach `waydroid session start` (logs to `/tmp/rbx-session.log`), poll `waydroid status` for `Session: RUNNING` (up to 180 s). `waydroid app launch` silently no-ops if session not `RUNNING`. **`waydroid session status` is NOT a command** — `session` only takes `start`/`stop`; use top-level `waydroid status`.

   Long timeout + `setsid` reasons: Android cold boot on T480 routinely takes 60-120 s (30 s was too short). If rbx exits while `session start` is still running, the launcher's job table tears down weston too — wayland socket vanishes mid-boot, LXC bind-mount of `/run/user/$UID/wayland-1` hard-fails. `setsid` keeps both alive across rbx exit; a timed-out launch is recoverable.
4. `exec waydroid app launch com.roblox.client`. Override via `$RBX_PKG`.

### `rbxvm` — Android-x86 VM launcher (Roblox)

Boots the Roblox-only Android-x86 VM provisioned by `installers/discontinued/install-android-vm.sh`. Apply perf profile (skipped under `RBXVM_DRY=1` — non-TTY sudo prompt would block), then `exec qemu-system-x86_64` under KVM. Preflight hard-fails on missing `qemu-system-x86_64`/`qemu-img`/`sudo`/`systemctl`/`stat`, missing `/dev/kvm`, or missing `$ANDROID_VM_DIR/disk.qcow2` — no silent fallback to TCG.

QEMU flags: `-cpu host -smp 4 -m 4096 -machine q35`; `virtio` disk with `discard=unmap`; `virtio-vga-gl` + `-display gtk,gl=on` for iGPU GL passthrough; `virtio-tablet` for absolute mouse; `intel-hda` + `hda-output` over `-audiodev pa,…` (PipeWire PA compat); `virtio-net` user-mode NAT with hostfwd loopback `5555` → guest `5555`.

**First-boot ISO heuristic** (load-bearing): `stat -c%s disk.qcow2 < 1 MiB` decides whether to attach `-cdrom $ISO -boot order=dc,menu=on`. Fresh `qemu-img create -f qcow2 8G` is ~200 KB; once the guest installs, the file grows past 1 MB long before first reboot. After install the cdrom is omitted so a stray reboot can't land in the installer GRUB and wipe the guest.

**ADB autostart**: backgrounded watcher polls `adb connect 127.0.0.1:5555` for ~180 s; on success, `monkey -p com.roblox.client -c LAUNCHER 1`. Best-effort: timeout → warning, VM keeps running, tap by hand. Missing `adb` → warn + skip.

Env: `RBXVM_DRY=1`; `ANDROID_VM_DIR=<path>` (default `~/android-vm`); `RBXVM_NO_AUTOSTART=1`; `RBXVM_AUTOSTART_PKG=<pkg>` (default `com.roblox.client`); `RBXVM_FORCE_ISO=1`. Sizing split: `RAM_MB`/`VCPUS` here, `DISK_SIZE` in `install-android-vm.sh`.

Gotchas — do not reintroduce:
- **Don't switch `-audiodev pa,…` to `pipewire`.** Older qemu builds compile pipewire out; silent failure (no audio, no error). `pa` works against PipeWire's PA compat layer.
- **Don't drop the ISO heuristic for always-on `-cdrom`.** Stray reboot would land in installer GRUB and wipe the guest. Use `RBXVM_FORCE_ISO=1` for manual override.
- **Graphics fallback is manual.** Hang at splash → swap `virtio-vga-gl` + `gtk,gl=on` for `VGA` + `gtk` (software, Roblox tanks but boots). Failure mode is "hang", no clean signal.
- **`virtio-tablet`** required — Android-x86's relative-input is rough.

### `nic-boost` — temporary WiFi/EEE perf boost

Runtime-only NIC tweaks for bandwidth-heavy work. Deployed by `gaming/install-nic-tuning.sh`. Lives here, not in the permanent NIC installer, because both settings cost battery *exactly when traffic is low* (remove idle-time hardware napping): `sudo iw dev <wifi> set power_save off` (~0.3-0.5 W extra at idle); `sudo ethtool --set-eee <eth> eee off` (~0.5 W extra on idle link). Three shapes: bare (apply, persist); `nic-boost <cmd>` (apply, run cmd, revert on exit via `trap revert EXIT INT TERM` — covers Ctrl-C/kill); `--off` (revert). No modprobe/dispatcher files written — settings revert on reboot via kernel driver defaults.

### `redmi-gaming` — apply/revert gaming profile on a connected Redmi 4A

Host-side ADB toggle for a per-session gaming profile on LineageOS Redmi 4A (`rolex`). Same apply/revert as `nic-boost`. Non-root tweaks (always): animation scales `0.5x` (largest perceived-perf win on a 2 GB / SD425; `0.5` not `0` so touch feedback stays legible); `settings put global low_power 0` (bail out of LOS battery saver); `am force-stop` of `HEAVY` apps (`com.google.android.gms`, `com.android.vending` — no-ops if not installed). Root-only (require Magisk `su` OR `adb root` via LOS Developer Options → "Rooted debugging"; otherwise skipped): all CPUs pinned to `performance` (SD425's schedutil ramp is conservative enough to cost frames); GPU governor pinned (`/sys/class/kgsl/kgsl-3d0`). Revert restores `1.0` scales + stock governors (`schedutil`/`interactive` CPU; `msm-adreno-tz` GPU).

Gotchas: **guard `adb root` with `(( ! dry ))`** — restarts adbd as root + bounces USB connection; running under `--dry-run` defeats "no side effects". Magisk `su` is side-effect-free, tried first. **`adb shell "su -c '$*'"`** works for no-`'` commands but is brittle if a future tweak embeds a quote — switch to heredoc-via-stdin if so.

### `skl` — Minecraft (zsh alias)

In `~/.zshrc`: `alias skl='sudo systemctl stop tlp; sudo sysctl vm.swappiness=10; sudo cpupower frequency-set -g performance; gamemoderun java -jar ~/Desktop/SKlauncher-3.2.18.jar --workDir /games/minecraft'`. Updated from broken versions: `sudo tlp stop` (invalid tlp subcommand) and `/mnt/minecraft` (stale mountpoint).

### Gotchas common to all launchers

- First launch after reboot pays warm-up (Steam: few seconds for library scan; Waydroid: 30–60 s for container).
- TLP stop is sticky until reboot. `sudo systemctl start tlp` brings it back.
- `cpupower` requires `linux-cpupower` (or `linux-tools-$(uname -r)`); `utils.sh` installs both, latter as fallback for non-Liquorix kernels.
- Launchers assume `sudo` is NOPASSWD for `systemctl stop tlp`, `sysctl vm.swappiness=10`, `cpupower frequency-set -g performance` exactly — never NOPASSWD a whole class.

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

Scripts kept on disk for institutional knowledge (kernel binder probing, Bliss OS history, X11/Wayland nesting, Android-x86 first-boot dance). Not on the default install path; still pass `bash -n`.

### `install-roblox.sh` — interactive Waydroid + APK setup

8 sections, each prefaced by ELI5 + y/N prompt. `-y` skips prompts. Tuned for MX XFCE on T480; warns instead of bails on mismatched hardware.

- **VANILLA image, not GAPPS** — Roblox accepts email + 2FA; save ~300 MB.
- **Weston for X11** — Waydroid is a Wayland client. `weston` is the upstream-recommended nested compositor (<5 MB), spawned by `rbx` when `$XDG_SESSION_TYPE != wayland`.
- **libndk via casualsnek/waydroid_script** — Roblox APK is arm64, T480 is x86_64; `libndk_translation` bridges. Run inside script-local venv so nothing leaks into system Python.
- **Pixel 5 device spoof** — default Waydroid props identify as `emulator`, Roblox integrity check rejects. Pixel 5 is the waydroid_script default, known-accepted.
- **`persist.waydroid.multi_windows=true`** — load-bearing for `rbx`. Without it, `waydroid app launch` renders only inside full Android desktop; launcher would need `waydroid show-full-ui` + manual tap.
- **APK from uptodown** — setup tries two regex shapes (HTML changed twice), falls back to manual-download message on Cloudflare challenge (HTTP 200, so re-check ZIP magic bytes).
- **Step 3 installs `lzip` before `waydroid init`.** Vendor images are `.lzip`-compressed; `init` shells out to `lzip`. Debian `waydroid` package doesn't depend on it — fresh box hits half-populated `/var/lib/waydroid` and fails partway.
- **`sh` re-exec guard at top.** Now repo convention.

Binder gotchas (Step 1):
- **Hard-fails on missing `CONFIG_ANDROID_BINDER_IPC`.** Binder is the Android IPC mechanism. Debian stock builds `=m`, Liquorix 6.19 builds it off. Three-way probe: `/sys/module/binder_linux`, `binder` in `/proc/filesystems` (built-in signature), `binder_linux.ko*` under `/lib/modules/$(uname -r)`. All miss → exit with `sudo apt install linux-image-amd64 && sudo reboot`. Earlier `lsmod`+`modinfo` fallback silently warned-and-continued, burning a 500 MB image download before failing at `waydroid init`.
- **Fixes `vndbinder`/`hwbinder` device discovery.** Waydroid needs three IPC domains (`binder` app/framework, `hwbinder` HALs, `vndbinder` vendor) — three security contexts, not aliases. Most desktop kernels build with `CONFIG_ANDROID_BINDER_DEVICES="binder"` and disable `CONFIG_ANDROID_BINDERFS`, so init fails with `Binder node "vndbinder" for waydroid not found`. Fix: `binder_linux` module param `devices=` (charp) overrides the static list. Step 1 checks `/dev/{binder,hwbinder,vndbinder}`; if any missing, writes `/etc/modprobe.d/waydroid-binder.conf` with `options binder_linux devices=binder,hwbinder,vndbinder`, `rmmod`s, `modprobe`s. Built-in binder (`=y`) cannot be rebound — add `binder_linux.devices=binder,hwbinder,vndbinder` to GRUB cmdline and reboot.

Layout (`~/install_roblox/`, runtime-populated): `roblox.apk`, `waydroid_script/`, `venv/`. Waydroid container state under `/var/lib/waydroid` — tied to kernel, no split-partition story.

### `check-roblox-prereqs.sh` — pre-flight gate for `install-roblox.sh`

Standalone preflight. `[OK]/[FAIL]` style; exit 0 if every hard condition met, 1 if any fails; soft conditions print `[WARN]` without flipping exit. Hard: (1) kernel name does NOT contain `liquorix`/`zen` (those disable `CONFIG_ANDROID_BINDER_IPC`; reboot into stock); (2) `CONFIG_ANDROID_BINDER_IPC=m` in `/boot/config-$(uname -r)` (`=y` → `[WARN]`, works but needs kernel cmdline arg); (3) `waydroid` on PATH; (4) `getent hosts ota.waydro.id` resolves. Soft: waydroid-container running, sudo cached, stdin TTY, X11 vs Wayland session.

### `install-android-vm.sh` — QEMU/KVM + Android-x86 ISO + qcow2 disk (Roblox VM)

Provisions host side of the Roblox VM that `rbxvm` boots. Three idempotent actions: (1) `apt-get install qemu-system-x86 qemu-system-gui qemu-utils ovmf adb` — only missing ones (`dpkg-query` short-circuits). `qemu-system-gui` is load-bearing (GTK display + virgl renderer for `-display gtk,gl=on`); `adb` saves `rbxvm`'s autostart an apt round-trip. (2) `curl` Android-x86 9.0-r2 ISO (~700 MB, SourceForge mirror) to `$ANDROID_VM_DIR/android-x86.iso`. (3) `qemu-img create -f qcow2 … 8G` at `$ANDROID_VM_DIR/disk.qcow2` (sparse ~200 KB until guest writes). Each step skips if present.

Hard preflights: `/dev/kvm` exists; `curl`/`sudo`/`apt-get`/`stat` on PATH. Env: `ANDROID_ISO_URL=<url>` (fork swap — Bliss OS slot once their lockdown lifts), `ANDROID_VM_DIR=<path>` (default `~/android-vm`). Installer's `apt-get` is NOT NOPASSWD.

**Why Android-x86, not literal LineageOS:** LineageOS ships no official x86_64 image — Bliss OS, LineageOS-x86 etc. are forks of upstream Android-x86. Defaults to 9.0-r2 because Bliss OS is under "temporary LOCKDOWN" (blissos.org as of 2026-05). Android 9 (Pie), old but Roblox-Android still supports it and the KVM boot story is well-trodden.

**Resource sizing — 4 vCPU / 4 GiB RAM / 8 GiB qcow2:** smoothness ceiling is the host iGPU (UHD 620) doing GL passthrough. 4 vCPU (Roblox-on-Android is 1-2 thread bound); 4096 MB (Roblox's recommended); 8 GB covers ~3 GB Android-x86 + Roblox APK + ~1 GB asset cache.

**First-boot dance:** `rbxvm` boots with `-cdrom android-x86.iso -boot order=dc` (first boot only, per the ISO heuristic). GRUB default is **Live mode** — arrow down to **Installation**. Partition virtio disk (`sda`) as one ext4, install GRUB, install system as **read-write** ("/system" prompt — pick yes so updates + app installs stick). Power off (don't reboot — installer CD still attached for *this* QEMU process; killing QEMU + re-running `rbxvm` drops the ISO).

**Roblox install — Play Store not bundled:** sideload APKMirror Roblox APK via browser, OR install Aurora Store.

**Boot-straight-into-Roblox via ADB autostart — guest setup:** Settings → About tablet → tap *Build number* 7×; Developer options → *USB debugging* on (RSA prompt on first host `adb connect` → *Always allow*). Then in guest shell: `setprop service.adb.tcp.port 5555 && stop adbd && start adbd`; persist with `echo 'persist.service.adb.tcp.port=5555' | su -c 'tee -a /system/build.prop'`. Read-only `/system` makes the persist line silently no-op (autostart works this boot, breaks next) — pick **read-write** in the install dance.

### `install-lxqt.sh` — LXQt + bilingual keyboard + Albert

Drops `lxqt + sddm` alongside XFCE (pick at SDDM login). Pre-seeds: bilingual us/ru keyboard (Meta+Space toggle), F5/F6 brightness via `brightnessctl`, bottom panel with FancyMenu, Albert as alt+space launcher, `xcape` autostart turning bare-Meta tap into `XF86LaunchA` (menu on Super alone). No `--uninstall` — purging LXQt while logged into LXQt is a TTY-rescue recipe. Albert from upstream OBS repo (key under `/etc/apt/keyrings/albert.gpg`); skipped if on PATH. Every config file overwritten unconditionally — hand-edits to `~/.config/{lxqt,albert}/*.conf` + the two `~/.config/autostart/*.desktop` entries don't survive rerun.

### `debloat-xfce.sh` — strip XFCE after switching to another DE

Two hard-fail preflights: active session must NOT be XFCE (refuses if `$XDG_CURRENT_DESKTOP` is `*xfce*`); XFCE must be installed (`xfwm4` check, so a "0 packages" exit can't mask a bad invocation). Removal: metas (`xfce4`, `task-xfce-desktop`, `xfce4-goodies`); core (xfwm4, xfdesktop4, xfconf, xfce4-session/settings/panel/notifyd/appfinder/power-manager); wildcards (`'xfce4-*'`, `'libxfce4*'`, `'thunar-*'`); apps (thunar, mousepad, ristretto, parole, orage); `'xubuntu-*'`. Bring back: `sudo apt install xfce4`.
