# steves_debian_setup

Personal setup repo for a fresh MX Linux XFCE install on a ThinkPad T480
(Intel UHD 620, x86_64, Liquorix kernel, X11). The scripts here turn a
clean MX install into the working environment, plus install/launch a
handful of games and apps that don't have first-class Linux delivery.

This single `CLAUDE.md` covers the whole repo — every subfolder used to
have its own, now merged here. Section anchors below mirror the old
file layout: `installers/`, `launchers/`, `autostarts/`, `nord-job/`,
`lineage_vm/`, `installers/discontinued/`.

## Layout

```
installers/    install-*.sh, utils.sh, check-setup.sh   (one-shot setup)
installers/discontinued/  no-longer-recommended scripts (Roblox/Lineage/LXQt/XFCE)
launchers/     stm, rbx, rbxvm, nic-boost               (per-run wrappers)
lineage_vm/    deployed-state docs only                 (Roblox-VM data files live here)
nord-job/      nord-rand + nord-rand.cron               (6-hourly NordVPN rotation)
autostarts/    *.desktop                                 (XFCE autostart)
backup.zshrc   reference copy of ~/.zshrc               (do not source)
```

## Install order on a fresh box

1. `installers/utils.sh` — bulk apt + toolchains + oh-my-zsh + debloat.
   This is the one big bootstrap; everything else assumes it ran.
2. `installers/check-setup.sh` — verifies step 1. Exit 0 means clean.
3. `installers/setup_nordvpn.sh` — only if you want NordVPN; replaces
   the snap version with the official deb repo.
4. Game/app installers as needed:
   `install-steam.sh`, `install-tld.sh`, `install-anki.sh`,
   `debloat-mx.sh` (strip MX-bundled apps), `debloat-nvidia.sh`
   (purge nvidia/nouveau on Intel-iGPU-only boxes), `debloat-kde.sh`
   (post-install KDE Plasma debloat — only runs if `plasma-desktop`
   is installed).
   Each is independent. Roblox (`install-roblox.sh` +
   `check-roblox-prereqs.sh`), the Android-x86 VM alternative
   (`install-lineage.sh`), the LXQt alt DE (`install-lxqt.sh`), and
   the XFCE-purge counterpart (`debloat-xfce.sh`) all moved to
   `installers/discontinued/` — see the **installers/discontinued/**
   section below for the technical notes.
5. Networking polish: `install-nic-tuning.sh` drops sysctl + NM
   dispatcher tweaks (zero power cost) and deploys `nic-boost`
   to `~/.local/bin/` for opt-in WiFi/EEE temporary boosts.
6. Optional tmux persistence: `install-tmux-immortal.sh` adds tpm
   + tmux-resurrect + tmux-continuum so sessions survive reboots.
7. Optional NordVPN country rotation: `install -m 755 nord-job/nord-rand
   ~/.local/bin/` then `crontab nord-job/nord-rand.cron`. See the
   **nord-job/** section below for modes and the autoconnect/skip
   interaction.
8. `launchers/stm`, `launchers/rbx`, and `launchers/rbxvm` go to
   `~/.local/bin/`. The `skl` Minecraft launcher lives as a zsh alias,
   not a script — see `backup.zshrc` for the exact line.
9. `autostarts/*.desktop` go to `~/.config/autostart/`.

## Conventions every installer follows

- `#!/usr/bin/env bash` shebang, followed by a `[ -z "${BASH_VERSION:-}" ]`
  guard that re-execs under bash. Catches `sh installers/foo.sh` invocations
  before dash trips over `[[`, arrays, or `(( ))` with cryptic errors.
- `set -euo pipefail` at the top, no exceptions.
- `--dry-run` prints actions, mutates nothing. Combinable with other modes.
- Idempotent: re-running on an already-installed box is a no-op, not an error.
- No credentials, no scraping behind logins, no `curl | sudo bash` of
  unaudited third parties (waydroid_script is the one exception, vendored
  under `~/install_roblox/waydroid_script/` by the discontinued Roblox installer).
- Hard-fail loud on missing deps in a `preflight` block; never silently skip.
- Sudo is called inline, never via a script-wide re-exec. The user sees
  every privileged action.

## Gaming-partition assumptions

`/games/steam` (sda3) and `/games/minecraft` (sda4) are mounted via
`/etc/fstab`. The launchers and `install-tld.sh` assume those mountpoints
exist; on a different machine, edit the path constants at the top of each
script. See `~/CLAUDE.md` (user-level, outside this repo) for the disk
layout, fstab entries, and why Steam itself stays in `~/.steam` while only
game *content* lives on `/games/steam`.

## What is intentionally NOT here

- `~/.zshrc` itself (only a backup copy). The live one is generated from
  the user's habits and contains tokens; do not commit it.
- The Roblox APK, Waydroid system image, Steam game data, Minecraft
  worlds — all bulky and fetched on demand by the installers/launchers.
- `~/install_roblox/waydroid_script/` and `~/install_roblox/venv/` —
  cloned/created at runtime by the discontinued `install-roblox.sh`.

---

## installers/

Idempotent, dry-runnable setup scripts. Each is independent — pick the
ones you need on a given box. All follow the conventions above: bash
re-exec guard, `set -euo pipefail`, `--dry-run`, no creds, no scraping
behind logins, hard-fail preflight.

The `discontinued/` subfolder holds scripts no longer on the default
install path (Roblox, Lineage VM, LXQt, XFCE-purge) — see the
**installers/discontinued/** section below for the technical notes.

### `utils.sh` — bulk bootstrap

The one big script. Resolves every dependency referenced by `~/.zshrc`
on a Debian/Ubuntu box: apt packages, oh-my-zsh + plugins, fzf shell
integration, user toolchains (rustup, rbenv, atuin, starship, nvm, deno,
bun, pyenv), Go and neovim from upstream tarballs, third-party installers
(brave, waydroid), pip tools, flatpak + Organic Maps, Claude Code,
NordVPN, tmux config, helper scripts, XFCE + KDE keybindings, and
EasyEffects presets. Numbered sections (1–15) match `check-setup.sh`'s
verification order; step 14 is intentionally a no-op stub — debloat
moved out to `debloat-mx.sh` (general MX bloat) and `debloat-nvidia.sh`
(the old nvidia-purge behaviour). `--dry-run` prints every action without
mutating; for the curl-piped third-party installers and the `cat >
heredoc` helper-script writes it prints a short summary instead of
trying to render the whole pipe.

### `check-setup.sh` — post-bootstrap verifier

Mirrors `utils.sh` step-for-step and prints `[OK]` / `[FAIL]` per check.
Exit 0 if all pass. Use it as the smoke test after `utils.sh` and after
any system upgrade that touches the GPU stack (the iGPU/nouveau check
will catch a regression).

### `install-steam.sh` — Steam from apt + non-free

Adds the i386 architecture and (on Debian) ensures the
`contrib non-free non-free-firmware` components are enabled, then
installs `steam-installer` (Debian) or `steam` (Ubuntu). Modes mirror
`install-tld.sh` / `install-anki.sh`: bare install, `--reinstall`,
`--uninstall`, `--dry-run`. Does NOT touch `libraryfolders.vdf` —
the `stm` launcher registers `/games/steam` on first run.

### `install-tld.sh` — The Long Dark (re)installer

Thin wrapper around Steam's URL handlers for AppID `305620`. Routes all
Steam invocations through `stm` so the perf tweaks (TLP stop, swappiness,
`performance` governor) apply. Modes:
- bare        — install
- `--reinstall` — uninstall first, then install
- `--verify`  — `steam://validate/` (re-hash files against manifests,
                redownload corrupt ones)
- `--dry-run` — orthogonal, combinable with any mode

Preflights before touching Steam: `stm` + `steam` on PATH,
`libraryfolders.vdf` exists, `/games/steam` registered as a library
(redundant with `stm`'s own registration but catches the
Steam-already-running case where `stm` skips it), `/games/steam`
actually mounted (`mountpoint -q`, stricter than `-d`) and writable,
≥12 GiB free. No creds, no scraping. Depends only on `bash`, `grep`,
`awk`, `df`, `mountpoint`, `stm`.

### `install-anki.sh` — official upstream tarball

Why upstream tarball, not apt: Debian's `anki` lags upstream by years.
Anki's official Linux delivery (since 25.07) is the **anki-launcher**
tarball — a tiny launcher that ships its own `install.sh` /
`uninstall.sh` and pulls the real app on first run. This script picks
the newest GitHub release that has the launcher asset, downloads it,
hands off to Anki's installer (which writes `/usr/local`). User decks
at `~/.local/share/Anki2` are never touched.

Modes: `(none)`, `--reinstall`, `--uninstall`, `--dry-run`.

Deps: `bash`, `curl`, `tar` (with `--zstd` — modern GNU tar, or
`apt install zstd`), `awk`, `sudo`. No `jq` — release lookup is pure
`curl | awk`.

Asset regex: `anki-launcher-.*-linux[.]tar[.]zst$`. Use `[.]`, not `\.`
— `awk -v` strips one level of backslash and warns on unknown escape
sequences.

Release lookup walks `/repos/ankitects/anki/releases` newest-first and
takes the first URL matching the asset regex. This skips tags that
haven't shipped binaries yet (common for release candidates). Anonymous
GitHub API rate limit is 60/hr per IP; if you hit it, the symptom is
empty `url` and "No matching launcher asset in recent releases."

Two non-obvious gotchas — do not reintroduce:
1. **Don't `exit` from the awk that parses the GitHub API.** Closing
   the pipe early sends curl SIGPIPE; with `set -o pipefail` the whole
   `url=$(curl … | awk …)` substitution silently fails. Use a `seen`
   flag and let curl finish writing.
2. **Don't `local tmp` for the scratch dir referenced by the EXIT
   trap.** The trap fires after the function returns, by which point
   the local is gone and `set -u` blows up with `tmp: unbound
   variable`. Keep `tmp` at script scope and reference it as
   `${tmp:-}` in the trap.

What gets installed where:

| Path                       | Owner | Purpose                           |
|----------------------------|-------|-----------------------------------|
| `/usr/local/bin/anki`      | root  | launcher entry point              |
| `/usr/local/share/anki/`   | root  | launcher + bundled `uninstall.sh` |
| `~/.local/share/Anki2/`    | user  | profiles, decks, media — **safe** |
| `~/.cache/Anki2/`          | user  | downloaded real app, regeneratable |

### `install-nic-tuning.sh` — permanent NIC tuning (zero power cost)

Drops two artifacts plus the `nic-boost` launcher:

| Path                                                | Purpose                                        |
|-----------------------------------------------------|------------------------------------------------|
| `/etc/sysctl.d/99-nic-tuning.conf`                  | BBR + fq, larger buffers, TFO, MTU probing     |
| `/etc/NetworkManager/dispatcher.d/99-nic-tuning`    | per-eth-iface WoL off + ring buffers max       |
| `~/.local/bin/nic-boost`                            | copied from `launchers/nic-boost` (755)        |

Modes: bare install, `--uninstall` (removes all three), `--dry-run`.
Idempotent. Hard-fails if `ethtool` or `sysctl` are missing.

The split is deliberate: this script only writes settings whose power
cost is zero or negligible. The energy-hungry settings (WiFi
`power_save=0`, ethernet EEE off) cost battery exactly *when traffic
is low* — those live in `launchers/nic-boost` so they're opt-in per
session and revert on reboot. See the **nic-boost** entry in the
launchers section below.

The dispatcher script bails early on wifi (`exit 0` if
`/sys/class/net/$iface/wireless` exists) so it never touches WiFi
power state — kept ethernet-only on purpose.

### `install-tmux-immortal.sh` — persist tmux sessions across reboots

Drops three pieces:

| Path                                          | Purpose                                       |
|-----------------------------------------------|-----------------------------------------------|
| `~/.tmux/plugins/{tpm,tmux-resurrect,tmux-continuum}` | plugin manager + save/restore + autosave |
| `~/.tmux.conf` (only if absent)               | sane defaults + plugin lines + restore=on     |
| `~/.config/autostart/tmux-immortal.desktop`   | starts a detached `main` session at login     |

Modes: bare install, `--uninstall` (nukes plugins + autostart, leaves
`~/.tmux.conf` alone), `--dry-run`. Idempotent.

Decisions worth knowing:

- **Never overwrites an existing `~/.tmux.conf`.** If the file is there,
  the script prints the four `set -g @plugin …` + `run` lines and tells
  you to merge them in by hand. An earlier draft used a header marker
  (`# tmux-immortal-managed`) to detect "we own this file" and overwrite,
  but that broke the moment the user *appended* the marker block to a
  hand-rolled config — re-runs would clobber the prefix rebind. The
  simpler invariant (file exists → no-op) wins.
- **Headless plugin install needs a live tmux server.** `tpm/bin/install_plugins`
  reads its install path via `tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH`,
  which queries tmux's own global env (not the bash env). Setting
  `TMUX_PLUGIN_MANAGER_PATH=…` as a bash var does nothing. Step 4 spins
  up a throwaway `_tpm_init` session running `sleep 30` to keep a server
  alive, `tmux setenv -g`s the path, runs `install_plugins`, then
  `kill-session -t _tpm_init`. Any pre-existing user sessions are
  untouched.
- **Autostart spawns `tmux new-session -d -s main`, not `start-server`.**
  A server with zero sessions exits immediately. `main` is a placeholder
  if continuum has nothing saved yet (harmless empty session); once
  continuum has restore data, it adds the saved sessions on top of
  `main` at server-start time.
- **Continuum saves every 15 min, not faster.** Faster intervals churn
  disk for marginal gain — resurrect's pane-content capture is not free
  on big scrollback. 15 min is the upstream default.

### `debloat-mx.sh` — strip MX Linux bundled apps

Companion script to a fresh MX install (preflights `/etc/mx-version`,
hard-fails on vanilla Debian). Removes MX-specific bloat in seven
groups: one-time welcome (`mx-welcome`/`mx-tour`), misc
(`mx-updater`, `mx-packageinstaller*`, `mx-viewer` ["MX browser"],
`mx-flash`, `mx-codecs`), settings GUIs that duplicate XFCE Settings
(`mx-keyboard`/`mx-locale`/`mx-date-time`/`mx-user`/`mx-menu-editor`/
`mx-system-keyboard*`), niche network helpers (`mx-rsync`,
`mx-samba-config`, `mx-find-shares`, `mx-network-assistant`,
`mx-service-manager`), theme/sound packs
(`mx-artwork`, `mx-faenza-icons`, `mx-select-sound`,
`mx-system-sounds`, `mx-quick-system-info`), `mx-comp-mgr`
(irrelevant once you switch to KDE), and heavyweights from the old
`utils.sh` step 14 (`gimp`, `vlc*`, `libreoffice-*`, `strawberry`,
`gmtp`, `deb-installer`, `qpdfview`, `catfish`, `lo-main-helper`).
Also strips all CD/DVD burning/ripping apps (`xfburn`, `asunder`,
`brasero*`, `k3b*`, `xcdroast`, `gnomebaker`, `mybashburn`).

Mx-* packages NOT touched (still useful): `mx-tools`, `mx-snapshot`,
`mx-cleanup`, `mx-tweak`, `mx-repo-manager`, `mx-iso-dump`,
`mx-software-defaults`, `mx-default-settings`, `mx-keyring`.

Opt-in (commented-out `optional=()` array in the script): `mx-conky`
(only if you run Conky), `mxlive-usb-maker` (redundant with
`mx-iso-dump`), `mx-remastercc`, `mx-installer`.

Modes: bare, `--dry-run`. For the nvidia/nouveau purge that used to
live behind `--intel-only`, run the sibling `debloat-nvidia.sh`.

Implementation note: a single `expand_installed` helper accepts both
literal package names and shell globs (e.g. `'libreoffice-*'`,
`'mx-packageinstaller*'`), enumerates them via `dpkg-query` selectors,
and filters down to installed-only — so re-runs on a debloated box
are no-ops and one apt invocation handles everything.

### `debloat-nvidia.sh` — purge nvidia + nouveau (Intel-iGPU-only boxes)

Standalone counterpart to the old `debloat-mx.sh --intel-only` flow.
Purges `nvidia-*` / `libnvidia-*` / `xserver-xorg-video-nouveau`, writes
`/etc/modprobe.d/blacklist-nouveau.conf` (`blacklist nouveau` +
`options nouveau modeset=0`), reruns `update-initramfs -u`. Saves
~500 MB and frees the iGPU from sharing DRM contention with an unused
nouveau probe at boot.

Modes: bare, `--dry-run`, `--uninstall` (removes the blacklist file
only — drivers themselves untouched; reinstall with apt as needed).

Hard-fail preflight: refuses to run if `lspci -nn -d ::0300/0302/0380`
reports an NVIDIA GPU — purging drivers on a box that actually has a
discrete card drops X to llvmpipe or hangs at boot. No override flag
by design; if you genuinely know better, edit the script.

Shares the `expand_installed` glob/literal helper pattern with
`debloat-mx.sh` and `debloat-kde.sh`. Idempotent: a fully-purged box
re-runs as a no-op.

### `debloat-kde.sh` — strip a Debian/MX KDE Plasma install

Companion to a KDE install (won't run unless `plasma-desktop` is
present — preflight aborts otherwise). Adapted from cl0v3r404's
[Debloat-KDE-Plasma-Debian](https://github.com/cl0v3r404/Debloat-KDE-Plasma-Debian)
(Spanish original); rewritten in English, extended for a thicker
debloat (now covers PIM/Akonadi, Plasma widget addons, niche services
+ Baloo disable), and made idempotent. Modes: bare, `--dry-run`,
`--no-bluetooth` (opt-in: also purges bluedevil/bluez/blueman; off by
default because most laptops have BT hardware worth keeping). No
`--uninstall` — by design; reinstall individual packages with
`sudo apt install <pkg>`.

Removal groups (each enumerated through `expand_installed`, which
accepts shell globs *and* literal names; one apt purge call):
- **legacy KDE apps**: konqueror+plugins, akregator, kmail/korganizer/
  kaddressbook/kontact/kleopatra/kgpg, kdepim-runtime, kwrite, xterm,
  dragonplayer/juk/elisa, goldendict-ng, debian-reference-common,
  khelpcenter
- **CJK/non-Latin input**: full fcitx + fcitx5 stack, mozc (+uim/utils),
  anthy, ibus, xiterm+thai
- **KDE games**: `kdegames` meta + 30+ individual game packages — meta
  removal is the point, otherwise autoremove drags games back next time
- **KDE edutainment**: `kde-edu` meta + cantor/kalzium/kstars/marble/etc.
- **legacy/duplicate utilities**: kfind, kompare, kget, sweeper, k3b,
  kjots/knotes, kruler/kcharselect/kcolorchooser, kbackup, kolourpaint
- **images**: gimp (upstream's call; reinstall on demand)
- **Akonadi PIM stack**: `'akonadi-*'` + `'kdepim-*'` wildcards plus
  `mariadb-server` + `mariadb-server-core` + `default-mysql-server` —
  Akonadi pulls a real RDBMS as a Recommends, and autoremove leaves it
  behind. Without an explicit purge you keep a mariadb daemon running
  forever serving nothing.
- **Plasma extras**: `plasma-widgets-addons`, `plasma-runners-addons`,
  `plasma-wallpapers-addons`, `plasma-dataengines-addons`,
  `kdeplasma-addons` — slims the widget picker + KRunner menu and
  stops background data-engine daemons. Panel/desktop/KWin untouched.
- **services + niche**: kdeconnect (phone sync — reinstall with one
  apt command if you actually use it), krdc/krfb (VNC client/server),
  plasma-vault (encrypted folders), okteta (hex editor), kfontview,
  kdf, kup-backup, kontrast, ksystemlog, kdebugsettings, and
  `'phonon*-backend-vlc'` (dead weight once vlc is gone)
- **cosmetic packs**: `plasma-workspace-wallpapers`,
  `oxygen-icon-theme`, `oxygen-sounds` (Breeze is the default; Oxygen
  is legacy)
- **Debian doc cruft**: `doc-debian`, `'installation-guide-*'`
- **bluetooth (opt-in via `--no-bluetooth`)**: bluedevil, bluez,
  bluez-obexd, blueman, `'libbluetooth*'`

Language filter (dynamic, separate from the static groups):
enumerates installed `kde-l10n-*`, `firefox-esr-l10n-*`,
`thunderbird-l10n-*`, `hunspell-*`, `aspell-*`, `myspell-*`,
`manpages-*`, and `task-*-desktop` packages, keeps anything matching
`*-en|*-en-*|*english*|*-de|*-de-*|*german*` (plus base `manpages` /
`manpages-dev` / `manpages-posix*`), purges the rest. Keyboard
layouts and `xkb-data` are untouched per repo convention — this is a
language-pack purge, not an input-method purge. After the purge,
rewrites `/etc/locale.gen` to just `en_US.UTF-8 UTF-8` + `de_DE.UTF-8
UTF-8` and reruns `locale-gen`.

Plasma config tweaks (per-user, via `kwriteconfig6` / fallback to
`kwriteconfig5`) — runs after the package work, **must be invoked as
the desktop user, NOT under sudo** or configs land in `/root/.config`:
- `ksmserverrc` → `loginMode=emptySession` (no session restore;
  saves 50–100 MB at every login)
- `kdeglobals` → `AnimationDurationFactor=0` (instant transitions)
- `dolphinrc` → `Plugins=imagethumbnail,jpegthumbnail,svgthumbnail,exrthumbnail`
  (keeps image thumbnails, kills the ffmpegthumbs/poppler/taglib
  spawns on every folder browse). Only written when the key isn't
  already set — an earlier draft overwrote unconditionally and wiped
  per-user plugin choices on every re-run.

Defensive pre-step (load-bearing — added after prior versions bricked
the desktop on autoremove cascade): before any purge, the script
`apt-mark manual`s every load-bearing KDE package currently installed
— `plasma-desktop`, `plasma-workspace`, `plasma-framework`,
`kwin-x11/wayland/common`, `sddm`, `systemsettings`, `kio`/`kio-extras`,
`dolphin`, `konsole`, `plasma-nm`, `plasma-pa`, `powerdevil`,
`kscreen`/`kscreenlocker`, `breeze*`, `qt6-wayland`. Without this, the
final `apt autoremove --purge -y` walks the dep graph after the
meta-package removes (`kdegames`, `kde-edu`, kdepim) and can cascade
into core Plasma packages whose only manual rdep was the meta — the
desktop is gone on next login. `apt-mark manual` is idempotent and
reversible (`apt-mark auto <pkg>` to revert).

Holds `kdeaccessibility` before any removes — older Debian releases
list it as a Recommends on KDE metas, and autoremove drops it.

Adds `plasma-discover-backend-flatpak`, `kde-config-flatpak`, and
`kde-config-plymouth` (each filtered through `available_only` so MX's
slimmer repo set doesn't hard-fail when a package isn't carried).

Service tweak (post-removal): runs `balooctl6 disable` (fallback to
`balooctl` for KF5 systems) to turn off the Baloo file indexer.
Doesn't purge `baloo-kf6` itself — KDE apps link against it — just
stops the daemon, which recovers a chunk of CPU + ends SSD churn.
Idempotent: disabling an already-disabled index is a no-op.

Re-runnable: `expand_installed` returns the empty set on a fully-
debloated box, so a second run removes nothing.

### `setup_nordvpn.sh` — replace snap with official deb

Removes any snap-installed nordvpn, runs the official install.sh,
adds the user to the `nordvpn` group. Log out/in afterward for the
group change to take effect.

---

## launchers/

Per-run wrappers that apply the same performance profile before launching
a game. Drop them in `~/.local/bin/` (already on PATH from `~/.zshrc`).

### Shared performance profile

Every launcher (and the `skl` zsh alias for Minecraft) runs the same
three commands first:

```sh
sudo systemctl stop tlp                       # disable thermal/power throttling
sudo sysctl vm.swappiness=10                  # discourage swapping under pressure
sudo cpupower frequency-set -g performance    # pin CPU governor to performance
```

These are reverted on next boot — TLP comes back via its systemd unit,
the kernel resets sysctl/cpupower defaults. Intentional: gaming-only
mode, no permanent change.

### `stm` — Steam launcher

Three things before launching Steam:

1. Apply the perf profile above.
2. Idempotently register `/games/steam` as a Steam library folder in
   `libraryfolders.vdf` — but only when Steam isn't already running
   (writing the VDF under a live Steam process risks corruption).
3. `exec steam` — **not** wrapped in `gamemoderun`. Wrapping the Steam
   client itself breaks CEF rendering because `libgamemodeauto.so` gets
   `LD_PRELOAD`ed into every webhelper subprocess; set
   `gamemoderun %command%` as a per-game launch option instead.

Steam itself (client, runtime, Proton, compat data) stays in `~/.steam`
on `sda2`. Only game content goes on `/games/steam`. Games don't move
automatically: set `/games/steam` as the default library in
Steam Settings → Storage, and move existing games via Properties →
Installed Files → Move Install Folder.

The VDF path is `~/.steam/debian-installation/steamapps/libraryfolders.vdf`
on Debian (the package is `steam-installer`, which installs into
`~/.steam/debian-installation/`). On Ubuntu the package is `steam` and
the path is `~/.steam/steam/steamapps/libraryfolders.vdf` — adjust the
`VDF=` line at the top of `stm` accordingly.

### `rbx` — Roblox-on-Waydroid launcher

Order matters here — the X11/weston step has to land before the session
start, otherwise the session daemon inherits no `WAYLAND_DISPLAY` and
silently has no surface to render to:

1. Starts `waydroid-container.service` if not already running (sudo
   once per reboot).
2. Applies the perf profile (TLP stop, swappiness, governor — same as
   `stm`/`skl`).
3. On X11, spawns nested `weston --socket=wayland-1` at 1600x900,
   waits for the socket to appear under `$XDG_RUNTIME_DIR`, then
   exports `WAYLAND_DISPLAY=wayland-1`. Pinning the socket name
   (rather than letting weston pick) keeps the next step deterministic.
   On Wayland, no-op.
4. `setsid`-detaches `waydroid session start` (logs to
   `/tmp/rbx-session.log`) and polls `waydroid status` for
   `Session: RUNNING` (up to 180 s). Waydroid has two runtimes: the
   system container (owns the Android processes) and a per-user
   session daemon (clipboard, input, surface creation, `app launch`
   IPC). `waydroid app launch` silently no-ops if the session is not
   `RUNNING`, hence the poll. Note: `waydroid session status` is NOT
   a command — `session` only takes `start`/`stop`. Use `waydroid status`
   (top-level) and grep its output.

   Two reasons for the long timeout + `setsid`: first-time Android
   cold boot on a T480 routinely takes 60-120 s (much longer than the
   30 s the script used to allow). And if rbx exits while the
   background `session start` is still running, the launcher's job
   table tears down weston too — the wayland socket vanishes mid-boot
   and the LXC bind-mount of `/run/user/$UID/wayland-1` hard-fails
   (visible in `/var/lib/waydroid/waydroid.log`). `setsid` for both
   weston and `session start` keeps them alive across rbx exit, so a
   timed-out launch leaves the system in a recoverable state instead
   of needing a reboot.
5. `exec waydroid app launch com.roblox.client`. Override the package
   via `$RBX_PKG`.

Add the alias to `~/.zshrc`:

```sh
alias rbx='~/install_roblox/rbx'
```

(Or symlink `rbx` into `~/.local/bin/`; pick one.)

### `rbxvm` — LineageOS / Android-x86 VM launcher (Roblox)

Boots the Roblox-only Android-x86 VM provisioned by
`installers/install-lineage.sh`. Same perf profile as `stm`/`rbx`/`skl`,
then a single `exec qemu-system-x86_64` under KVM.

Order:

1. Preflight: `qemu-system-x86_64`/`qemu-img`/`sudo`/`systemctl`/`stat`
   on PATH; `/dev/kvm` present; `$LINEAGE_VM_DIR/disk.qcow2` exists.
   Hard-fails loud — no silent fallback to TCG (would be unplayable).
2. Apply the perf profile (TLP stop, swappiness, governor — same as
   `stm`/`rbx`/`skl`). Skipped under `RBXVM_DRY=1` so the dry-run is
   safe from a non-TTY context (sudo prompt would block).
3. **First-boot ISO heuristic.** `stat -c%s disk.qcow2 < 1 MiB`
   decides whether to attach `-cdrom $ISO -boot order=dc,menu=on`. A
   fresh `qemu-img create -f qcow2 8G` is ~200 KB on disk; once the
   guest installs Android-x86 the file grows past 1 MB long before
   the first reboot. After install the cdrom is omitted entirely so
   a stray reboot can't drop the user back into the Android-x86
   installer GRUB (which would wipe the guest).
4. `exec qemu-system-x86_64` with: `-cpu host -smp 4 -m 4096
   -machine q35`; `virtio` disk with `discard=unmap` (lets the qcow2
   shrink as the guest TRIMs); `virtio-vga-gl` + `-display gtk,gl=on`
   for iGPU GL passthrough; `virtio-tablet` for absolute mouse
   coordinates (relative-input on Android-x86 drifts); `intel-hda` +
   `hda-output` over `-audiodev pa,…` (PipeWire's PulseAudio compat
   layer); `virtio-net` user-mode NAT (no host port forwarding).

Env knobs:
- `RBXVM_DRY=1` — print the assembled qemu command and exit. Used by
  the install smoke test and when tuning `-cpu`/`-smp`/resource flags.
- `LINEAGE_VM_DIR=<path>` — point at a non-default VM directory
  (default: `$HOME/lineage_vm`). The installer honors the same var.
- `RBXVM_NO_AUTOSTART=1` — skip the ADB-driven Roblox autostart and just
  drop you at Android's home screen (useful for guest maintenance).
- `RBXVM_AUTOSTART_PKG=<pkg>` — override the package to launch (default
  `com.roblox.client`).

### `rbxvm` ADB autostart

After QEMU launches, `rbxvm` backgrounds a watcher that polls
`adb connect 127.0.0.1:5555` for ~180 s and, once the guest's package
manager answers, `monkey`-launches the Roblox `LAUNCHER` intent. The
QEMU netdev line forwards host loopback 5555 → guest 5555 explicitly
for this. Best-effort by design: if the guest hasn't been installed
yet (first boot), or ADB-over-network isn't enabled inside the guest,
or Roblox isn't sideloaded, the loop times out cleanly and emits a
single warning — the VM keeps running and you tap Roblox by hand.

Guest-side one-time setup (do this inside the VM after sideloading
Roblox — see the **LineageOS VM (Roblox-only)** section below for
the full recipe): Settings → System → About → tap Build number 7×
→ Developer options → enable USB debugging; then in any Android
terminal app, run `setprop service.adb.tcp.port 5555 && stop adbd
&& start adbd` (persist across reboot by appending
`persist.service.adb.tcp.port=5555` to `/system/build.prop`; needs
the writable /system you picked at install time).

`adb` lives in the `adb` Debian package and is pulled in by
`install-lineage.sh`. If it's missing at launch time `rbxvm` warns and
skips the autostart — it doesn't hard-fail.

Resource sizing is split with the installer: `RAM_MB` (4096) and
`VCPUS` (4) live here; `DISK_SIZE` (8 GB) lives in
`install-lineage.sh`. Deliberately tight — Roblox is the only
workload and the real perf ceiling is the iGPU doing GL passthrough.

Non-obvious gotchas — do not reintroduce:

- **Don't switch `-audiodev pa,…` to `-audiodev pipewire,…` without
  testing.** Older qemu builds compile pipewire support out and the
  failure mode is silent (no audio + no error). The `pa` driver
  works against PipeWire's PulseAudio compat layer on this box.
- **Don't drop the ISO heuristic for an always-on `-cdrom`.** That
  lets a stray reboot land in the Android-x86 installer GRUB on a
  pre-installed disk and wipe the guest. If a manual override is
  needed, add an `RBXVM_FORCE_ISO=1` env var rather than tearing out
  the heuristic.
- **Graphics fallback is manual, not auto-detected.** If the guest
  hangs at the splash, swap `-device virtio-vga-gl -display gtk,gl=on`
  for `-device VGA -display gtk` (software rendering — Roblox tanks
  but it boots). Don't auto-detect: the failure mode is "hang", which
  isn't a clean signal.

### `nic-boost` — temporary WiFi/EEE perf boost

Runtime-only NIC tweaks for bandwidth-heavy work. Deployed by
`installers/install-nic-tuning.sh` into `~/.local/bin/nic-boost`.
Lives here, not in the permanent NIC installer, because both settings
cost battery *exactly when traffic is low* (they remove idle-time
hardware napping):

```
sudo iw dev <wifi> set power_save off    # ~0.3-0.5 W extra at idle
sudo ethtool --set-eee <eth> eee off     # ~0.5 W extra on idle link
```

Three call shapes:

| Invocation                | Behavior                                       |
|---------------------------|------------------------------------------------|
| `nic-boost`               | apply, persist until reboot or manual `--off`  |
| `nic-boost <command...>`  | apply, run command, revert on its exit         |
| `nic-boost --off`         | revert manually (settings back to defaults)    |

The wrapped form sets a `trap revert EXIT INT TERM` so the revert
fires even on Ctrl-C or kill. No modprobe/dispatcher files are ever
written — settings revert on reboot automatically because the kernel
re-applies driver defaults. This is the same on/off pattern as
`stm`/`rbx` for TLP/governor (gaming-only, no permanent change).

### `skl` — Minecraft (zsh alias, not a script)

Lives in `~/.zshrc` as a one-liner because there's nothing to wrap
beyond the perf tweaks and the SKlauncher jar:

```sh
alias skl='sudo systemctl stop tlp; sudo sysctl vm.swappiness=10; \
  sudo cpupower frequency-set -g performance; \
  gamemoderun java -jar ~/Desktop/SKlauncher-3.2.18.jar --workDir /games/minecraft'
```

Updated from earlier broken versions: `sudo tlp stop` (invalid tlp
subcommand) and `/mnt/minecraft` (stale mountpoint, now `/games/minecraft`).

### Gotchas common to all launchers

- First launch after reboot pays warm-up cost (Steam: a few seconds for
  client + library scan; Waydroid: 30–60 s for container).
- The TLP stop is sticky until reboot. If you want TLP back without
  rebooting, `sudo systemctl start tlp` after closing the game.
- `cpupower` requires `linux-cpupower` (or `linux-tools-$(uname -r)`)
  to be installed. `utils.sh` installs both, with the
  `linux-tools-$(uname -r)` fallback for non-Liquorix kernels.
- The launchers assume `sudo` is configured to NOT prompt for password
  for these specific commands, OR you accept the prompt every launch.
  If the prompt is annoying, add a sudoers drop-in for
  `systemctl stop tlp`, `sysctl vm.swappiness=10`, and
  `cpupower frequency-set -g performance` — but limit to those exact
  commands, never NOPASSWD a whole class.

---

## autostarts/

XFCE autostart `.desktop` files. Drop into `~/.config/autostart/` (per
user) or `/etc/xdg/autostart/` (system-wide).

XFCE reads `[Desktop Entry]` files from these dirs at session start and
runs `Exec=` for each. `X-GNOME-Autostart-enabled=true` is honored by
XFCE too despite the GNOME prefix.

### `alacritty-autostart.desktop` — terminal as a service

Starts `alacritty --gapplication-service` at login so subsequent
`alacritty` invocations open a window against the already-running
service (faster spawn, shared font/config cache). `Hidden=true` and
`NoDisplay=true` keep the entry out of the application menu so users
can't accidentally toggle it off from Settings → Session and Startup.

### `brave-autostart.desktop` — browser at login

Plain `brave-browser` at login. `StartupNotify=true` so the cursor
shows the launching state. Visible in the Session and Startup UI on
purpose — you may want to disable this on a low-RAM machine.

### `easyeffects.desktop` — audio EQ as a service

Same `--gapplication-service` pattern as alacritty: start once at
login, all subsequent `easyeffects` calls attach to the running
service. Required if you want presets (EQ, autogain, etc.) to apply
to every audio stream from session start, not from the first time you
open the EasyEffects GUI.

### Autostart notes

- The `nohup` in the `Exec=` lines is defensive — XFCE's session
  manager already detaches autostart processes, but `nohup` ensures
  a stray HUP from a logout-of-the-launching-shell can't kill them.
- Trailing `&` inside `Exec=` is ignored by the .desktop spec but
  harmless; the literal command is run via the spec's own fork.

---

## nord-job/ — random NordVPN country rotation

### Files

- `~/.local/bin/nord-rand` — the script (chmod +x, NordLynx, kill switch, threat protection, autoconnect baked into `setup` mode)
- `nord-rand.cron` (this dir) — crontab snippet, installed via `crontab nord-rand.cron`
- `~/Desktop/nord-rand.log` — every action timestamped (ISO-8601), append-only, no rotation
- `/media/fred/8B35-3F46/nord-rand` and `nord-rand.cron` — backup copies on SD card (FAT/exFAT drops the +x bit; `chmod +x` after copy back)

### Modes

- `nord-rand` — pick a random country from whatever `nordvpn countries` returns; **skip if already connected**
- `nord-rand force` — same, but disconnect-and-reconnect even when connected. **This is what cron runs.**
- `nord-rand setup` — one-time NordVPN config. Requires prior `nordvpn login`. Disconnects, sets technology + protections, enables autoconnect, tries `post-quantum` (ignored on older clients).
- `nord-rand kill on|off` — toggle kill switch. `off` is the escape hatch when you need plain internet.

### Cron

`0 */6 * * * /home/fred/.local/bin/nord-rand force >/dev/null 2>&1` — every 6 hours (00, 06, 12, 18). Output silenced because the script logs internally.

### The autoconnect ↔ option-B conflict

User picked "skip if already connected" (option B) but also enabled NordVPN's autoconnect. Autoconnect keeps the VPN up 24/7, so plain `nord-rand` would never rotate. Resolution: cron uses `force`; manual invocations still default to soft skip. To revert to literal option B, drop the word `force` from the cron line — `crontab -e`.

### Country list

Pulled live from `nordvpn countries` at every invocation — no hardcoded array. `list_countries()` strips ANSI colour codes, normalises whitespace/commas to one country per line, and drops separator dashes; the CLI's own naming (underscores for spaces, e.g. `United_Kingdom`) is preserved. Retry loop tolerates up to `MAX_TRIES` (5) unavailable picks. To restrict the pool (e.g. EU-only), pipe through an `awk`/`grep` filter inside `list_countries`.

### Prereqs not handled by the script

- `nordvpn` daemon installed and user in the `nordvpn` group
- `nordvpn login` run interactively at least once (browser flow)
- `nord-rand setup` run once after login

### Failure modes worth knowing

- Kill switch ON + VPN daemon dead/crashed → no internet at all. Recover with `nord-rand kill off` or `sudo systemctl restart nordvpnd`.
- 5 connect attempts all hit unavailable countries → script exits 1, log shows `fail: MAX_TRIES attempts exhausted`. Re-run, or narrow the pool by filtering inside `list_countries`.
- Cron silently dropping mail because no MTA: expected. All visibility is in `~/Desktop/nord-rand.log`.

---

## LineageOS VM (Roblox-only)

A QEMU/KVM-backed Android-x86 VM dedicated to running Roblox. Same
"stop TLP / drop swappiness / pin governor" perf profile as `stm`,
`rbx`, `skl` — see `~/CLAUDE.md`.

The `lineage_vm/` directory holds the VM's data files. The installer
and launcher live elsewhere:

| File                | Path                                                              |
|---------------------|-------------------------------------------------------------------|
| Installer           | `~/steves_debian_setup/installers/install-lineage.sh`             |
| Launcher            | `~/.local/bin/rbxvm`                                                |
| Disk image          | `/home/fred/lineage_vm/disk.qcow2`  (8 GB ceiling, qcow2 sparse)  |
| Install ISO         | `/home/fred/lineage_vm/android-x86.iso`  (~700 MB)                |

### Why Android-x86 and not literal LineageOS

LineageOS does not ship an official x86_64 image — every desktop
"LineageOS-style" distro (Bliss OS, LineageOS-x86) is a fork of the
upstream **Android-x86** project. The installer defaults to
**Android-x86 9.0-r2** (the newest stable release) because:

- Bliss OS, the obvious LineageOS-derived alternative, is currently
  under a "temporary LOCKDOWN" (blissos.org as of 2026-05). No fresh
  builds available.
- Android-x86 9.0-r2 is Android 9 (Pie) — old, but Roblox-Android still
  supports it and the boot story under KVM is well-trodden.

To swap in a fork build later (e.g. when Bliss OS comes back), pass
`LINEAGE_ISO_URL=<https://...iso>` to the installer. The launcher does
not care what's on the ISO — it just attaches it to the CD-ROM slot.

### Resource sizing — 4 vCPU / 4 GiB RAM / 8 GiB qcow2

Deliberately tight; Roblox is the only workload. The real ceiling for
smoothness is the **host iGPU** (T480 UHD 620) doing GL passthrough via
`virtio-vga-gl` — no amount of vCPU/RAM/disk fixes that. Sizing logic:

- **4 vCPU**: Roblox-on-Android is typically 1-2 thread bound; 4 leaves
  host headroom on a 16-logical-CPU box.
- **4096 MB RAM**: matches Roblox's recommended Android spec.
- **8 GB disk**: qcow2 is sparse (~200 KB at create), so the ceiling
  is free. 8 GB covers the ~3 GB Android-x86 install + Roblox APK and
  asset cache (~1 GB) with room for app/system updates over time.
  5-6 GB was the user's first instinct; bumped to 8 GB on the
  reasoning that sparse means raising the ceiling costs nothing on
  the host until the guest actually writes.

Override at the source if needed: `RAM_MB` and `VCPUS` in `rbxvm`,
`DISK_SIZE` in `install-lineage.sh`.

### First-boot install dance

1. `rbxvm` boots the VM with `-cdrom android-x86.iso -boot order=dc`.
   The CD is *only* attached on first boot — `rbxvm` detects "no OS
   installed yet" via `stat -c%s disk.qcow2 < 1 MiB` (a freshly created
   qcow2 is ~200 KB; once Android-x86 is installed it grows past a
   megabyte well before the first reboot).
2. GRUB's default highlight is **Live mode**. Arrow down to
   **Installation** — easy to miss.
3. Partition the virtio disk (`sda`) as one ext4, install GRUB, install
   the system as **read-write** (the menu calls this "/system" — pick
   yes for writable so updates and app installs stick).
4. Power the VM off (don't reboot — once you reboot inside Android, the
   installer's CD is still attached for *this* QEMU process; only
   killing QEMU and re-running `rbxvm` drops the ISO).
5. `rbxvm` on subsequent runs boots straight from disk. The ISO file
   stays in `/home/fred/lineage_vm` in case you want to `--reinstall`.

### Roblox install — Play Store is not bundled

Android-x86 ships without Google Play Services. To install Roblox:

- Sideload the **APKMirror** Roblox APK over a browser inside the
  guest, OR
- Install **Aurora Store** (anonymous Play Store proxy) and pull
  Roblox from there.

The Roblox Android app's HW requirements are easy to meet — the actual
runtime ceiling is the GL passthrough perf, not CPU/RAM.

### Boot-straight-into-Roblox via ADB autostart

`rbxvm` runs a best-effort ADB watcher after launching QEMU: it
`adb connect`s to host 5555 (forwarded by QEMU's `-netdev … hostfwd=…`
to the guest's 5555), waits for the package manager, then sends
`monkey -p com.roblox.client -c LAUNCHER 1`. End result: a few seconds
after `rbxvm` exits its startup, the Roblox loading screen is on
screen — no manual tap. If anything fails (guest not installed yet,
ADB-over-network not enabled, Roblox not sideloaded), `rbxvm` warns and
keeps the VM running so you can fix it.

One-time guest-side setup to make autostart fire:

1. **Enable Developer options:** Settings → System → About tablet →
   tap *Build number* 7 times.
2. **Enable USB debugging:** Settings → System → Developer options →
   *USB debugging* on. (The "Allow USB debugging?" RSA fingerprint
   prompt appears the first time the host `adb connect`s — tap *Always
   allow from this computer*.)
3. **Turn on ADB-over-network and persist it across reboots.** Open a
   guest terminal app (Termux works, or use the host once via USB
   debugging to run `adb shell`) and run:

   ```sh
   setprop service.adb.tcp.port 5555
   stop adbd && start adbd
   # To persist across guest reboots:
   echo 'persist.service.adb.tcp.port=5555' | su -c 'tee -a /system/build.prop'
   ```

   The `/system` edit requires the writable `/system` you picked
   during the install dance ("install as read-write" at the system
   step). Read-only `/system` makes the persist line silently no-op,
   so autostart works the same boot but breaks on the next.

Skip autostart with `RBXVM_NO_AUTOSTART=1 rbxvm`; override the package
with `RBXVM_AUTOSTART_PKG=<pkg>` (e.g. to test against an alternate
build).

### LineageOS VM — non-obvious gotchas (do not reintroduce)

These are the loaded-foot guns; mirror style of the `rbx` section in
the parent `~/CLAUDE.md`.

- **`stat -c%s "$DISK" < 1048576` heuristic** is load-bearing.
  Replacing it with always-on `-cdrom` lets users accidentally pick
  "Installation" from GRUB on a subsequent boot and wipe their guest
  setup. Replacing it with no-`-cdrom` breaks the first-run install
  path. If you want to expose a manual override, add an `RBXVM_FORCE_ISO=1`
  env var rather than tearing out the heuristic.
- **Graphics path: `virtio-vga-gl` + `-display gtk,gl=on`**. This is
  what the host iGPU can actually accelerate. If Android-x86 hangs at
  the splash, the fallback is `-vga std -display gtk` (software
  rendering, no GL, watch Roblox tank). The fallback is not auto-
  detected; you'd edit `rbxvm` to swap the two `-device`/`-display`
  lines, or wire it up as an env override.
- **Sudo:** `rbxvm`'s `systemctl stop tlp` / `sysctl` / `cpupower`
  appear NOPASSWD on this box (same as `stm`/`rbx`). The installer's
  `apt-get` is **not** NOPASSWD — `install_pkgs()` checks
  `dpkg-query` first and only invokes `sudo apt-get` if a package is
  actually missing. As of writing all three (`qemu-system-x86`,
  `qemu-utils`, `ovmf`) are present, so the install path never asks
  for a password.
- **`-boot order=dc`** means CD first then disk. Combined with the ISO
  heuristic above, GRUB on first boot is the Android-x86 installer
  GRUB. After install (ISO detached), `-boot` is omitted entirely and
  QEMU's default order finds the qcow2's GRUB.
- **Audio device choice:** `-audiodev pa,...` works against
  PipeWire's PulseAudio compat layer. Don't switch to `-audiodev
  pipewire,...` without testing — older qemu builds compile pipewire
  support out, and the failure mode is silent (no audio + no error).
- **`virtio-tablet`**: needed for absolute mouse positioning. Without
  it the guest pointer drifts because Android-x86's relative-input
  driver is rough.
- **RBXVM_DRY=1**: prints the assembled qemu command without launching.
  Used by the install smoke test and useful when tuning `-cpu`/`-smp`/
  resource flags.

### LineageOS VM operations cheatsheet

```
# Fresh install (one-time):
~/steves_debian_setup/installers/install-lineage.sh

# Launch the VM:
rbxvm

# Inspect what qemu command rbxvm would run, without launching:
RBXVM_DRY=1 rbxvm

# Try a Bliss OS build (once it returns) instead of Android-x86:
LINEAGE_ISO_URL=https://.../BlissOS-x86_64.iso \
  ~/steves_debian_setup/installers/install-lineage.sh --reinstall

# Wipe and start over:
~/steves_debian_setup/installers/install-lineage.sh --reinstall

# Tear down (keeps QEMU packages):
~/steves_debian_setup/installers/install-lineage.sh --uninstall
```

---

## installers/discontinued/

Scripts kept on disk for the institutional knowledge they encode (kernel
binder probing, Bliss OS history, X11/Wayland nesting tricks) but no
longer recommended for fresh setups. Reasons vary per script — see each
section. They still pass `bash -n` and may still work on the right box;
they're just not on the default install path.

### `install-roblox.sh` — interactive Waydroid + APK setup

8 sections, each prefaced by an ELI5 and a y/N prompt. Flags: `-y`
skips prompts, `--dry-run` prints actions instead of running them.
Tuned for MX XFCE on a ThinkPad T480 (Intel UHD 620, x86_64, X11);
on mismatched hardware/distros it warns instead of bailing, so it
stays usable elsewhere.

Decisions worth knowing:

- **VANILLA system image, not GAPPS** — Roblox accepts email + 2FA
  login now, so Play Services is not needed and you save ~300 MB.
- **Weston for X11** — Waydroid is a Wayland client; XFCE is X11.
  `weston` is the upstream-recommended nested compositor (<5 MB),
  spawned automatically by `rbx` when `$XDG_SESSION_TYPE != wayland`.
- **libndk via casualsnek/waydroid_script** — Roblox APK is arm64,
  T480 is x86_64; `libndk_translation` bridges the two.
  waydroid_script is the de-facto community installer. Run inside a
  script-local venv so nothing leaks into system Python.
- **Pixel 5 device spoof** — default Waydroid props identify the
  device as `emulator`, which the Roblox integrity check rejects
  outright. Pixel 5 is the waydroid_script default and is
  known-accepted at time of writing.
- **`persist.waydroid.multi_windows=true`** — load-bearing for `rbx`.
  Without it, `waydroid app launch` renders only inside the full
  Android desktop, so the launcher would have to call
  `waydroid show-full-ui` and you'd tap Roblox by hand every time.
- **APK from uptodown** — unmodified vendor APKs. Setup tries two
  regex shapes for the real download URL (uptodown has changed its
  HTML twice) and falls back to a manual-download message when it
  hits a Cloudflare challenge — those return HTTP 200, so we
  re-check the file's ZIP magic bytes before declaring success.
- **Step 3 installs `lzip` before `waydroid init`.** Waydroid's
  system + vendor images are `.lzip`-compressed and `init` shells out
  to the external `lzip` binary to extract them. The Debian `waydroid`
  package does not depend on lzip, so a fresh box hits a half-populated
  `/var/lib/waydroid` and the init fails partway through. Step 3 checks
  for lzip and offers to apt-install it before running init.
- **Top of the script re-execs under bash if invoked as `sh
  install-roblox.sh`.** The script uses `[[`, `((`, and `[Yy]*` glob
  matching, all of which dash treats as unknown commands. Crucially,
  `set -e` does **not** fire on bashism failures inside `if` conditions,
  so dash limps along making wrong decisions (e.g. `ask` returns false
  even when the user types `y`) instead of erroring out at line 1.
  The guard uses POSIX `[ -z "${BASH_VERSION:-}" ]` so it parses under
  either shell. (This pattern is now repo convention — every active
  installer adopts it; see the **Conventions every installer follows**
  section above.)
- **Step 1's binder check hard-fails when the kernel is missing
  `CONFIG_ANDROID_BINDER_IPC`.** Binder is the Android IPC mechanism;
  the entire Android userland inside Waydroid talks through it. It
  lives upstream in mainline Linux but is a config option distros
  toggle: Debian stock (`linux-image-amd64`) builds it `=m`, Liquorix
  6.19 builds it off. The previous check looked at `/sys/module/binder_linux`
  and `lsmod`, but a not-compiled-in kernel exposes neither, and the
  fallback `modinfo` branch silently warned-and-continued — burning a
  500 MB image download before failing at `waydroid init`. The new
  three-way probe checks (a) `/sys/module/binder_linux`, (b)
  `binder` in `/proc/filesystems` (built-in signature), (c)
  `binder_linux.ko*` under `/lib/modules/$(uname -r)` (loadable
  module on disk). All three miss → exit with the actionable fix
  (`sudo apt install linux-image-amd64 && sudo reboot` boots into the
  Debian kernel alongside Liquorix; DKMS or a kernel rebuild are the
  harder ones). No "override and continue" escape hatch — if you
  genuinely know better than the probe, edit the script.
- **Step 1 also fixes the `vndbinder`/`hwbinder` device-discovery
  case.** Even when binder *is* loaded, waydroid needs three separate
  binder IPC domains: `binder` (app/framework), `hwbinder` (HALs),
  `vndbinder` (vendor processes). They are three security contexts,
  not aliases. Most desktop kernels build with
  `CONFIG_ANDROID_BINDER_DEVICES="binder"` (one device) and disable
  `CONFIG_ANDROID_BINDERFS` (no dynamic creation), so `waydroid init`
  fails with `Binder node "vndbinder" for waydroid not found`. The
  fix: `binder_linux` has a module parameter `devices=` (charp) that
  overrides the kernel's static list. Step 1 checks for `/dev/binder`,
  `/dev/hwbinder`, `/dev/vndbinder`; if any are missing, it writes
  `/etc/modprobe.d/waydroid-binder.conf` with
  `options binder_linux devices=binder,hwbinder,vndbinder`,
  `rmmod`s, and `modprobe`s. Idempotent because the missing-device
  check skips the whole block on rerun. Built-in binder (`=y`) cannot
  be rebound this way — in that case the script tells the user to add
  `binder_linux.devices=binder,hwbinder,vndbinder` to GRUB's kernel
  command line and reboot.

Roblox-specific layout (`~/install_roblox/`, populated at runtime):

```
roblox.apk           uptodown-sourced APK
waydroid_script/     cloned casualsnek/waydroid_script (step 5)
venv/                local Python venv for waydroid_script
```

Waydroid container state lives under `/var/lib/waydroid` (system image)
and `/var/lib/waydroid/data` (app data), **not** in `/games/`. Unlike
Steam/Minecraft content, an Android container is tied to the kernel and
`/var` is the conventional path, so there is no split-partition story
here.

### `check-roblox-prereqs.sh` — pre-flight gate for `install-roblox.sh`

Standalone preflight that mirrors the conditions list for the Roblox
installer so users can run it before the 8-step interactive script
instead of bailing partway through. Same `[OK]/[FAIL]` style as
`check-setup.sh`; exits 0 if every hard condition is met, 1 if any
fails. Soft conditions print `[WARN]` without flipping the exit code.

Hard checks:
1. Running kernel name does NOT contain `liquorix`/`zen` (those builds
   disable `CONFIG_ANDROID_BINDER_IPC` entirely; reboot into stock).
2. `CONFIG_ANDROID_BINDER_IPC=m` in `/boot/config-$(uname -r)`. `=y`
   downgrades to a `[WARN]` (works, but you'll need to add a kernel
   cmdline arg).
3. `waydroid` binary on PATH.
4. `getent hosts ota.waydro.id` resolves (image host reachable).

Soft checks: waydroid-container running (installer stops it),
sudo cached, stdin TTY, X11 vs Wayland session.

### `install-lineage.sh` — QEMU/KVM + Android-x86 ISO + qcow2 disk

Provisions the host side of the Roblox-only "LineageOS" VM that
`launchers/rbxvm` boots. Three actions, each idempotent:

1. `apt-get install` `qemu-system-x86 qemu-system-gui qemu-utils ovmf`
   — but only the missing ones (`dpkg-query` short-circuits the apt
   round-trip and its sudo prompt when everything is already there).
   `qemu-system-gui` is the load-bearing one: it ships the GTK display
   and virgl renderer that `rbxvm`'s `-display gtk,gl=on` needs.
2. `curl` the Android-x86 9.0-r2 ISO (~700 MB, follows the SourceForge
   mirror redirect) to `$LINEAGE_VM_DIR/android-x86.iso`. Skips if
   already present and non-empty.
3. `qemu-img create -f qcow2 … 8G` at `$LINEAGE_VM_DIR/disk.qcow2`.
   qcow2 is sparse — the file is ~200 KB on disk until the guest
   actually writes. Skips if a disk already exists.

Modes: bare install, `--reinstall` (wipe disk+ISO then redo),
`--uninstall` (wipe disk+ISO, keep QEMU packages), `--dry-run`.
Hard preflights: `/dev/kvm` exists; `curl`/`sudo`/`apt-get`/`stat`
on PATH.

Why Android-x86 and not literal LineageOS: LineageOS ships no official
x86_64 image — every desktop "LineageOS-style" build (Bliss OS,
LineageOS-x86) forks the upstream Android-x86 project. 9.0-r2 is the
newest stable Android-x86 release; Bliss OS would be the obvious
LineageOS-derived alternative but is under a "temporary LOCKDOWN" as
of 2026-05 with no fresh builds available.

Env overrides:
- `LINEAGE_ISO_URL=<https://...iso>` — swap in a fork build (drop a
  Bliss OS URL here when their lockdown lifts).
- `LINEAGE_VM_DIR=<path>` — install to a non-default directory
  (default: `$HOME/lineage_vm`). The launcher honors the same var.

Resource sizing is split between this script and `rbxvm`:
`DISK_SIZE` lives here (8 GB ceiling, sparse so it costs nothing
until used); `RAM_MB` (4096) and `VCPUS` (4) live in `rbxvm`.
Deliberately tight — Roblox is the only workload, and the real perf
ceiling is the host iGPU doing GL passthrough, not vCPU/RAM/disk.

Post-install handoff: the script prints the GRUB-menu / partition /
install-as-read-write / power-off-don't-reboot dance. Full step list
in the **LineageOS VM (Roblox-only)** section above (the deployed-state
doc — covers first-boot install, Roblox sideload, ADB-over-network
setup for autostart, gotchas, and an operations cheatsheet). Play
Store is not bundled — sideload Roblox via APKMirror or pull it
through Aurora Store inside the guest.

### `install-lxqt.sh` — alternative DE: LXQt + bilingual keyboard + Albert

Drops an `lxqt + sddm` desktop alongside XFCE (pick at SDDM login).
Pre-seeds: bilingual us/ru keyboard (Meta+Space toggle), F5/F6
brightness via `brightnessctl`, a bottom panel with FancyMenu in the
left slot, Albert as the alt+space launcher, and an `xcape` autostart
that turns a bare-Meta tap into `XF86LaunchA` so the menu opens on
Super alone. Modes: bare, `--dry-run`. No `--uninstall` — purging
LXQt while logged into LXQt is a recipe for a TTY-rescue session;
recover by hand if needed.

Albert comes from the upstream OBS repo (signed key under
`/etc/apt/keyrings/albert.gpg`). Skipped if `albert` is already on
PATH. Every config file is overwritten unconditionally — the script
treats `~/.config/lxqt/*.conf`, `~/.config/albert/albert.conf`, and
the two `~/.config/autostart/*.desktop` entries as derived artifacts,
not user state. Hand-edits to those files do not survive a rerun.

### `debloat-xfce.sh` — strip XFCE after you've switched to another DE

Parallel to `debloat-mx.sh` / `debloat-kde.sh`. Idempotent,
`--dry-run`-able. Two hard-fail preflights:
1. **Active session must NOT be XFCE.** Checks `$XDG_CURRENT_DESKTOP`
   case-insensitively. Refuses if `*xfce*` — removing XFCE packages
   while it's the live desktop kills the session.
2. **XFCE must be installed somewhere.** Checks for `xfwm4`. Refuses
   otherwise — a clean "0 packages" exit would mask a bad invocation.

Removal groups:
- **metas**: `xfce4`, `task-xfce-desktop`, `xfce4-goodies`
- **core**: xfwm4, xfdesktop4, xfconf, xfce4-session, xfce4-settings,
  xfce4-panel, xfce4-notifyd, xfce4-appfinder, xfce4-power-manager
- **wildcards**: `'xfce4-*'`, `'libxfce4*'`, `'thunar-*'` — catches
  the long tail of panel plugins (clipman/pulseaudio/whiskermenu/
  statusnotifier/genmon/sensors/fsguard/netload/weather/...), goodies,
  and the libxfce4* runtime libs
- **apps**: thunar, mousepad, ristretto, parole, orage
- **xubuntu**: `'xubuntu-*'` (no-op on Debian/MX; covered just in case)

To bring XFCE back: `sudo apt install xfce4`.
