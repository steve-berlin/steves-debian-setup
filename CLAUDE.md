# steves_debian_setup

Personal setup repo for a fresh MX Linux XFCE install on a ThinkPad T480
(Intel UHD 620, x86_64, Liquorix kernel, X11). Scripts here turn a clean
MX install into the working environment, plus install/launch games and
apps that don't have first-class Linux delivery.

This single `CLAUDE.md` covers the whole repo. Section anchors mirror
the old per-subfolder layout: `installers/`, `launchers/`, `autostarts/`,
`nord-job/`, `lineage_vm/`, `installers/discontinued/`.

## Layout

```
installers/    install-*.sh, utils.sh, check-setup.sh   (one-shot setup)
installers/patches/        vendored patches (e.g. tmux dim-inactive-panes)
installers/discontinued/   no-longer-recommended scripts (Roblox/Lineage/LXQt/XFCE)
launchers/     stm, rbx, rbxvm, nic-boost               (per-run wrappers)
lineage_vm/    deployed-state docs only                 (Roblox-VM data files live here)
nord-job/      nord-rand + nord-rand.cron               (6-hourly NordVPN rotation)
autostarts/    *.desktop                                 (XFCE autostart)
backup.zshrc   reference copy of ~/.zshrc               (do not source)
```

## Install order on a fresh box

1. `utils.sh` — bulk apt + toolchains + oh-my-zsh + debloat. Big bootstrap;
   everything else assumes it ran.
2. `check-setup.sh` — verifies step 1. Exit 0 = clean.
3. `setup_nordvpn.sh` — only if you want NordVPN; replaces snap with deb repo.
4. Game/app installers as needed (each independent):
   `install-steam.sh`, `install-tld.sh`, `install-anki.sh`,
   `install-scrcpy.sh` (Android screen-mirror for rbxvm/Waydroid),
   `debloat-mx.sh`, `debloat-nvidia.sh` (Intel-iGPU-only boxes),
   `debloat-kde.sh` (only if `plasma-desktop` is installed),
   `debloat-redmi.sh` (only if a Redmi 4A on LineageOS is connected via ADB).
   Discontinued: `install-roblox.sh`, `check-roblox-prereqs.sh`,
   `install-lineage.sh`, `install-lxqt.sh`, `debloat-xfce.sh` —
   see **installers/discontinued/**.
5. Networking: `install-nic-tuning.sh` (sysctl + NM dispatcher, zero
   power cost) and `nic-boost` (opt-in WiFi/EEE boost).
6. Tmux stack (each independent, all idempotent):
   - `install-tmux-immortal.sh` — tpm + tmux-resurrect + tmux-continuum.
   - `install-tmux-expose.sh` — Mission Control-style session switcher
     (cargo-installs `tmux-expose` + registers TPM plugin).
   - `install-tmux-dim.sh` — builds a patched tmux 3.5a with the
     chud-methodology inactive-pane dim into `/usr/local/bin`.
7. NordVPN rotation: `install -m 755 nord-job/nord-rand ~/.local/bin/`
   then `crontab nord-job/nord-rand.cron`. See **nord-job/**.
8. `launchers/{stm,rbx,rbxvm,nic-boost}` → `~/.local/bin/`. The `skl`
   Minecraft launcher is a zsh alias — see `backup.zshrc`.
9. `autostarts/*.desktop` → `~/.config/autostart/`.

## Conventions every installer follows

- `#!/usr/bin/env bash` shebang then a `[ -z "${BASH_VERSION:-}" ]` guard
  that re-execs under bash — catches `sh installers/foo.sh` before dash
  trips over `[[`, arrays, or `(( ))`.
- `set -euo pipefail`, no exceptions.
- `--dry-run` prints actions, mutates nothing. Combinable with other modes.
- Idempotent: re-run on installed box = no-op, not error.
- No creds, no scraping behind logins, no `curl | sudo bash` of unaudited
  third parties (waydroid_script is the one exception, vendored under
  `~/install_roblox/waydroid_script/` by the discontinued Roblox installer).
- Hard-fail loud on missing deps in a `preflight` block.
- Sudo called inline, never via script-wide re-exec.

## Gaming-partition assumptions

`/games/steam` (sda3) and `/games/minecraft` (sda4) mounted via `/etc/fstab`.
Launchers + `install-tld.sh` assume those paths; edit the path constants
at the top of each script on a different box. See `~/CLAUDE.md` (user-level)
for the disk layout, fstab entries, and why Steam itself stays in `~/.steam`
while only game *content* lives on `/games/steam`.

## What is intentionally NOT here

- `~/.zshrc` itself (only a backup copy). The live one contains tokens.
- Roblox APK, Waydroid system image, Steam game data, Minecraft worlds
  — fetched on demand.
- `~/install_roblox/waydroid_script/` and `~/install_roblox/venv/` —
  runtime-created by the discontinued `install-roblox.sh`.

---

## installers/

Each independent; all follow the conventions above. The `discontinued/`
subfolder holds scripts no longer on the default install path (kept for
the institutional knowledge they encode — see that section).

### `utils.sh` — bulk bootstrap

The one big script. Resolves every dependency referenced by `~/.zshrc`:
apt packages, oh-my-zsh + plugins, fzf, user toolchains (rustup, rbenv,
atuin, starship, nvm, deno, bun, pyenv), Go + neovim tarballs, third-party
installers (brave, waydroid), pip tools, flatpak + Organic Maps, Claude
Code, NordVPN, tmux config, helper scripts, XFCE + KDE keybindings,
EasyEffects presets. Numbered sections (1–15) match `check-setup.sh`'s
verification order; step 14 is a no-op stub — debloat moved out to
`debloat-mx.sh` and `debloat-nvidia.sh`. `--dry-run` prints every action;
for curl-piped installers and `cat > heredoc` writes it prints a short
summary instead of the whole pipe.

### `check-setup.sh` — post-bootstrap verifier

Mirrors `utils.sh` step-for-step, prints `[OK]`/`[FAIL]`. Exit 0 if all
pass. Use after `utils.sh` and after any system upgrade touching the GPU
stack (iGPU/nouveau check catches regression).

### `install-steam.sh` — Steam from apt + non-free

Adds i386 + (on Debian) `contrib non-free non-free-firmware`, then
installs `steam-installer` (Debian) / `steam` (Ubuntu). Modes: bare,
`--reinstall`, `--uninstall`, `--dry-run`. Does NOT touch
`libraryfolders.vdf` — `stm` registers `/games/steam` on first run.

### `install-tld.sh` — The Long Dark (re)installer

Wraps Steam URL handlers for AppID `305620`, routes through `stm` so the
perf profile applies. Modes: bare / `--reinstall` (uninstall first) /
`--verify` (`steam://validate/`, re-hash + redownload corrupt) /
`--dry-run`. Preflights: `stm`+`steam` on PATH, `libraryfolders.vdf`
exists, `/games/steam` library registered (redundant with `stm` but
catches the Steam-already-running case), mounted (`mountpoint -q`,
stricter than `-d`) + writable + ≥12 GiB free. Deps: `bash grep awk df
mountpoint stm`.

### `install-anki.sh` — official upstream tarball

Debian's `anki` lags upstream by years. Since 25.07, Anki's official
Linux delivery is the **anki-launcher** tarball — tiny launcher with
its own `install.sh`/`uninstall.sh`, pulls the real app on first run.
Script picks newest GitHub release with the launcher asset, hands off
to Anki's installer (writes `/usr/local`). User decks at
`~/.local/share/Anki2` are never touched. Modes: bare, `--reinstall`,
`--uninstall`, `--dry-run`. Deps: `bash curl tar` (with `--zstd` — modern
GNU tar, or `apt install zstd`), `awk sudo`. No `jq` — release lookup is
pure `curl | awk`.

Asset regex: `anki-launcher-.*-linux[.]tar[.]zst$`. Use `[.]`, not `\.`
— `awk -v` strips one backslash and warns on unknown escapes. Release
lookup walks `/repos/ankitects/anki/releases` newest-first, takes first
match — skips tags without binaries (release candidates). Anonymous
GitHub API rate limit is 60/hr per IP; symptom is empty `url`.

Non-obvious gotchas — do not reintroduce:
1. **Don't `exit` from the awk that parses the GitHub API.** Closing the
   pipe early sends curl SIGPIPE; with `set -o pipefail` the whole
   `url=$(curl … | awk …)` substitution silently fails. Use a `seen`
   flag, let curl finish writing.
2. **Don't `local tmp` for the scratch dir referenced by the EXIT trap.**
   Trap fires after function returns, local is gone, `set -u` blows up
   with `tmp: unbound variable`. Keep `tmp` at script scope, reference
   it as `${tmp:-}` in the trap.

Layout: `/usr/local/bin/anki` (root, launcher), `/usr/local/share/anki/`
(root, launcher + bundled uninstaller), `~/.local/share/Anki2/` (user,
profiles/decks/media — safe), `~/.cache/Anki2/` (user, downloaded real
app, regeneratable).

### `install-scrcpy.sh` — upstream scrcpy, shadowing distro under /usr/local

Debian's `scrcpy` lags upstream by 6-12 months and misses v3 features
(virtual-display, audio passthrough, camera mirroring) that pair with
the `rbxvm` and Waydroid workflows. Fetches the prebuilt
`scrcpy-linux-x86_64-vX.Y.Z.tar.gz` from Genymobile's GitHub releases
and installs into `/usr/local/share/scrcpy/` with a thin wrapper at
`/usr/local/bin/scrcpy`. `/usr/local/bin` precedes `/usr/bin` on default
Debian PATH so the upstream binary wins. Modes: bare, `--reinstall`,
`--uninstall`, `--dry-run`.

Decisions:
- **Runtime deps via `apt install scrcpy`.** The distro package's
  Depends list covers `adb`, `libav*`, `libsdl2-2.0-0`, `libusb-1.0-0`
  across Debian/MX/Ubuntu without us pinning sonames that drift between
  releases. Fallback (`adb ffmpeg libsdl2-2.0-0 libusb-1.0-0 libv4l-0`)
  fires only if `apt install scrcpy` fails (older repo).
- **Shadow, don't replace.** Same pattern as `install-tmux-dim.sh` —
  distro `/usr/bin/scrcpy` stays in place as a fallback; `--uninstall`
  reverts to it cleanly (no apt reinstall needed).
- **Don't symlink `$BIN`→`$SHARE/scrcpy`.** Upstream's bundled wrapper
  does `cd "$(dirname ${0})"` then execs `./scrcpy-bin` with
  `LD_LIBRARY_PATH=$PWD`. A symlink would resolve `dirname` to
  `/usr/local/bin` and break the lib path. Write a thin shell wrapper
  that `exec`s the bundled wrapper at its real path under `$SHARE`.
- **Don't `exit` from the awk that parses the GitHub API.** Same gotcha
  as `install-anki.sh` — SIGPIPE to curl + `pipefail` would silently
  wipe the substitution. Use a `seen` flag instead.
- **Stamp at `/usr/local/share/scrcpy.version`.** Re-run with the same
  upstream version is a no-op; use `--reinstall` to force.

Anonymous GitHub API rate limit is 60/hr per IP; symptom is an empty
`url`. Asset regex: `scrcpy-linux-x86_64-v[0-9].*[.]tar[.]gz$` — uses
`[.]` not `\.` for awk-safety (same reason as `install-anki.sh`).

### `install-nic-tuning.sh` — permanent NIC tuning (zero power cost)

Drops: `/etc/sysctl.d/99-nic-tuning.conf` (BBR + fq, larger buffers,
TFO, MTU probing); `/etc/NetworkManager/dispatcher.d/99-nic-tuning`
(per-eth-iface WoL off + ring buffers max); `~/.local/bin/nic-boost`
(copied from `launchers/nic-boost`, 755). Modes: bare, `--uninstall`
(removes all three), `--dry-run`. Hard-fails if `ethtool`/`sysctl`
missing.

Split is deliberate: this script only writes settings whose power cost
is zero. Energy-hungry settings (WiFi `power_save=0`, ethernet EEE off)
cost battery exactly *when traffic is low* — those live in `nic-boost`
(opt-in per session, revert on reboot). Dispatcher bails early on wifi
(`exit 0` if `/sys/class/net/$iface/wireless` exists) — ethernet-only on
purpose.

### `install-tmux-immortal.sh` — persist tmux sessions across reboots

Drops: `~/.tmux/plugins/{tpm,tmux-resurrect,tmux-continuum}`;
`~/.tmux.conf` (only if absent); `~/.config/autostart/tmux-immortal.desktop`
(starts detached `main` session at login). Modes: bare, `--uninstall`
(nukes plugins + autostart, leaves `~/.tmux.conf` alone), `--dry-run`.

Decisions:
- **Never overwrites an existing `~/.tmux.conf`.** Prints the four lines
  to add and tells you to merge by hand. An earlier draft used a header
  marker to detect "we own this file" + overwrite, but broke when the
  user *appended* the marker to a hand-rolled config — re-runs clobbered
  the prefix rebind. File exists → no-op wins.
- **Headless plugin install needs a live tmux server.**
  `tpm/bin/install_plugins` reads its install path via
  `tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH` (tmux's global env,
  not bash). Setting it as a bash var does nothing. Throwaway
  `_tpm_init` session running `sleep 30` keeps a server alive while
  install runs.
- **Autostart spawns `tmux new-session -d -s main`, not `start-server`.**
  A server with zero sessions exits immediately. `main` is a placeholder;
  continuum adds saved sessions on top of it at server-start time.
- **Continuum saves every 15 min.** Faster = disk churn for marginal
  gain (resurrect's pane-content capture isn't free on big scrollback).

### `install-tmux-expose.sh` — Mission Control-style session switcher

Cargo-installs `tmux-expose` (cesarferreira/tmux.expose, Rust TUI with
live text thumbnails of each session) + registers the TPM plugin line in
`~/.tmux.conf`. Default binding: `Alt+e` opens a fullscreen popup of all
sessions as a grid; arrow keys / `hjkl` move, Enter switches, q/Esc
quits. Modes: bare, `--reinstall` (forces `cargo install --force`),
`--uninstall` (also strips the plugin line via `sed`), `--dry-run`.

Preflight: `cargo` on PATH — fails loud if `utils.sh` (rustup section)
hasn't run. Plugin line is inserted *before* the `run '…/tpm/tpm'` line
because tpm only manages plugins declared above its run-tpm call. Same
throwaway-tmux-session dance as `install-tmux-immortal.sh` for headless
TPM install. Idempotent: grep skips both the cargo bump and the conf
edit if already installed.

### `install-tmux-dim.sh` — build patched tmux with inactive-pane dim

Builds tmux 3.5a from source with `patches/tmux-dim-inactive-panes.patch`
(chud-methodology) and installs to `/usr/local/bin/tmux`, shadowing
`/usr/bin/tmux` without removing it. The patch dims every cell in
inactive panes via perceptual-luma desaturation (30%) + blend toward
the pane's default bg (35%). Works for arbitrary ANSI-colored content
(lazygit, syntax highlighting) — `window-style` alone only affects
cells using the terminal default colors. Modes: bare, `--reinstall`,
`--uninstall` (removes `/usr/local` binary only, distro tmux untouched),
`--dry-run`. Override pinned version with `TMUX_VERSION=3.5a`.

Decisions:
- **`patch --dry-run -p1` is non-optional, before the real apply.**
  A future tmux release that drifts past the hunks would otherwise
  silently produce a tmux with no dimming and no error.
- **Stamp file at `/usr/local/share/tmux-dim.version`.** Idempotency
  check matches both `-x /usr/local/bin/tmux` and stamp content; re-run
  with the same `TMUX_VERSION` is a no-op (use `--reinstall` to force).
- **Installs to `/usr/local`, not replaces `/usr/bin/tmux`.** `/usr/local/bin`
  precedes `/usr/bin` on default Debian PATH, so the patched binary wins.
  An apt upgrade of the distro `tmux` package can't clobber the patched
  one; `--uninstall` cleanly reverts to the distro version with no apt
  reinstall needed.
- **Build deps probed individually.** `cc make pkg-config patch curl tar`
  via `command -v`; `libevent-dev libncurses-dev bison` via `dpkg -s`
  (no binary to probe). Only missing ones trigger `apt-get install`.

The optional Neovim-side companion to chud-methodology (a `tint.nvim`
Lua transform matching the C algorithm byte-for-byte, plus
FocusLost/FocusGained autocmds to prevent double-dimming when tmux
already dims the whole pane) is not installed — no `~/.config/nvim/` on
this box. The full Lua snippet is in the chud README; drop it under
`require('tint').setup{ transforms = { ... } }` if/when nvim config is
added. `theme-palette.patch` (the optional second patch making tmux
aware of the terminal's ANSI16 palette) is not vendored — it requires
generating a `theme_palette.h` from the active theme at build time,
which is overkill outside a Nix flow.

### `debloat-mx.sh` — strip MX Linux bundled apps

Preflights `/etc/mx-version`, hard-fails on vanilla Debian. Removes
MX-specific bloat in inline-commented groups in a single `to_remove`
array: welcome (`mx-welcome`/`mx-tour`), misc (`mx-updater`,
`mx-packageinstaller*`, `mx-viewer` ["MX browser"], `mx-flash`,
`mx-codecs`), settings GUIs duplicating XFCE Settings (`mx-keyboard`/
`mx-locale`/`mx-date-time`/`mx-user`/`mx-menu-editor`/
`mx-system-keyboard*`), niche network helpers (`mx-rsync`,
`mx-samba-config`, `mx-find-shares`, `mx-network-assistant`,
`mx-service-manager`), theme/sound packs (`mx-artwork`,
`mx-faenza-icons`, `mx-select-sound`, `mx-system-sounds`,
`mx-quick-system-info`), `mx-comp-mgr` (irrelevant once you switch to
KDE), and heavyweights from old `utils.sh` step 14 (`gimp`, `vlc*`,
`libreoffice-*`, `strawberry`, `gmtp`, `deb-installer`, `qpdfview`,
`catfish`, `lo-main-helper`). Also all CD/DVD burning/ripping apps
(`xfburn`, `asunder`, `brasero*`, `k3b*`, `xcdroast`, `gnomebaker`,
`mybashburn`).

Kept (still useful): `mx-tools`, `mx-snapshot`, `mx-cleanup`,
`mx-tweak`, `mx-repo-manager`, `mx-iso-dump`, `mx-software-defaults`,
`mx-default-settings`, `mx-keyring`. Opt-in (commented out): `mx-conky`,
`mxlive-usb-maker` (redundant with `mx-iso-dump`), `mx-remastercc`,
`mx-installer`. Modes: bare, `--dry-run`. For nvidia/nouveau purge that
used to be `--intel-only`, see `debloat-nvidia.sh`.

`expand_installed` helper accepts literals + globs (e.g.
`'libreoffice-*'`), enumerates via `dpkg-query`, filters to
installed-only — re-runs on debloated box are no-ops and one apt call
handles everything.

### `debloat-nvidia.sh` — purge nvidia + nouveau (Intel-iGPU-only boxes)

Standalone counterpart to old `debloat-mx.sh --intel-only`. Purges
`nvidia-*`/`libnvidia-*`/`xserver-xorg-video-nouveau`, writes
`/etc/modprobe.d/blacklist-nouveau.conf` (`blacklist nouveau` +
`options nouveau modeset=0`), reruns `update-initramfs -u`. Saves
~500 MB and frees the iGPU from DRM contention with an unused nouveau
probe at boot. Modes: bare, `--dry-run`, `--uninstall` (removes blacklist
file only — drivers themselves untouched).

Hard-fail preflight: refuses if `lspci -nn -d ::0300/0302/0380` reports
an NVIDIA GPU — purging drivers on a box with a discrete card drops X
to llvmpipe or hangs at boot. No override flag by design. Shares the
`expand_installed` helper with `debloat-mx.sh` / `debloat-kde.sh`.

### `debloat-kde.sh` — strip a Debian/MX KDE Plasma install

Won't run unless `plasma-desktop` is present. Adapted from cl0v3r404's
[Debloat-KDE-Plasma-Debian](https://github.com/cl0v3r404/Debloat-KDE-Plasma-Debian)
(Spanish original), rewritten in English, extended for PIM/Akonadi,
Plasma widget addons, niche services + Baloo disable, made idempotent.
Modes: bare, `--dry-run`, `--no-bluetooth` (also purges
bluedevil/bluez/blueman; off by default — most laptops have BT hardware
worth keeping). No `--uninstall` by design; reinstall individual
packages.

Removal groups (each through `expand_installed`, one apt purge call):
- **legacy KDE apps**: konqueror+plugins, akregator, kmail/korganizer/
  kaddressbook/kontact/kleopatra/kgpg, kdepim-runtime, kwrite, xterm,
  dragonplayer/juk/elisa, goldendict-ng, debian-reference-common,
  khelpcenter
- **CJK/non-Latin input**: full fcitx + fcitx5 stack, mozc (+uim/utils),
  anthy, ibus, xiterm+thai
- **KDE games**: `kdegames` meta + 30+ individual packages (meta removal
  is the point — autoremove drags games back otherwise)
- **KDE edutainment**: `kde-edu` meta + cantor/kalzium/kstars/marble/etc.
- **legacy/duplicate utilities**: kfind, kompare, kget, sweeper, k3b,
  kjots/knotes, kruler/kcharselect/kcolorchooser, kbackup, kolourpaint
- **images**: gimp (upstream's call; reinstall on demand)
- **Akonadi PIM stack**: `'akonadi-*'` + `'kdepim-*'` wildcards plus
  `mariadb-server`/`mariadb-server-core`/`default-mysql-server` —
  Akonadi pulls a real RDBMS as Recommends, autoremove leaves it behind.
  Without explicit purge you keep a mariadb daemon serving nothing.
- **Plasma extras**: `plasma-widgets-addons`, `plasma-runners-addons`,
  `plasma-wallpapers-addons`, `plasma-dataengines-addons`,
  `kdeplasma-addons` — slims widget picker + KRunner, stops background
  data-engine daemons. Panel/desktop/KWin untouched.
- **services + niche**: kdeconnect (phone sync), krdc/krfb (VNC),
  plasma-vault, okteta, kfontview, kdf, kup-backup, kontrast,
  ksystemlog, kdebugsettings, `'phonon*-backend-vlc'`
- **cosmetic packs**: `plasma-workspace-wallpapers`, `oxygen-icon-theme`,
  `oxygen-sounds` (Breeze is default; Oxygen is legacy)
- **Debian doc cruft**: `doc-debian`, `'installation-guide-*'`
- **bluetooth (opt-in via `--no-bluetooth`)**: bluedevil, bluez,
  bluez-obexd, blueman, `'libbluetooth*'`

Language filter (dynamic): enumerates installed `kde-l10n-*`,
`firefox-esr-l10n-*`, `thunderbird-l10n-*`, `hunspell-*`, `aspell-*`,
`myspell-*`, `manpages-*`, `task-*-desktop`; keeps anything matching
`*-en|*-en-*|*english*|*-de|*-de-*|*german*` (plus base `manpages` /
`manpages-dev` / `manpages-posix*`), purges the rest. Keyboard layouts
and `xkb-data` untouched per repo convention — this is a language-pack
purge, not an input-method purge. After: rewrites `/etc/locale.gen` to
`en_US.UTF-8 UTF-8` + `de_DE.UTF-8 UTF-8` and reruns `locale-gen`.

Plasma config tweaks (per-user, via `kwriteconfig6` / fallback
`kwriteconfig5`) — **invoke as desktop user, NOT sudo** or configs land
in `/root/.config`:
- `ksmserverrc` → `loginMode=emptySession` (no session restore; saves
  50–100 MB at every login)
- `kdeglobals` → `AnimationDurationFactor=0` (instant transitions)
- `dolphinrc` → `Plugins=imagethumbnail,jpegthumbnail,svgthumbnail,exrthumbnail`
  (keeps image thumbs, kills ffmpegthumbs/poppler/taglib spawns on
  folder browse). Only written when key not already set — earlier draft
  overwrote and wiped per-user plugin choices on re-run.

**Defensive pre-step (load-bearing — added after prior versions bricked
the desktop on autoremove cascade):** before any purge, `apt-mark manual`s
every load-bearing KDE package currently installed — `plasma-desktop`,
`plasma-workspace`, `plasma-framework`, `kwin-x11/wayland/common`,
`sddm`, `systemsettings`, `kio`/`kio-extras`, `dolphin`, `konsole`,
`plasma-nm`, `plasma-pa`, `powerdevil`, `kscreen`/`kscreenlocker`,
`breeze*`, `qt6-wayland`. Without this, final `apt autoremove --purge -y`
walks the dep graph after the meta-package removes (`kdegames`,
`kde-edu`, kdepim) and cascades into core Plasma packages whose only
manual rdep was the meta — desktop gone on next login. `apt-mark manual`
is idempotent + reversible (`apt-mark auto <pkg>`).

Also: holds `kdeaccessibility` before removes (older Debian lists it as
Recommends on KDE metas, autoremove drops it); adds
`plasma-discover-backend-flatpak`, `kde-config-flatpak`,
`kde-config-plymouth` (each filtered through `available_only` so MX's
slimmer repos don't hard-fail when a package isn't carried).

Service tweak (post-removal): `balooctl6 disable` (fallback `balooctl`
for KF5) turns off the Baloo file indexer. Doesn't purge `baloo-kf6` —
KDE apps link against it — just stops the daemon, recovering CPU +
ending SSD churn. Idempotent.

### `debloat-redmi.sh` — disable LineageOS preinstalled apps on a Redmi 4A

Host-side script that drives ADB to `pm disable-user --user 0` a curated
list of LineageOS preinstalled apps on a connected Redmi 4A (`rolex`).
No root, no bootloader unlock needed; every action reversible with
`--restore`. Modes: bare (disable SAFE list), `--include-optional` (add
the OPTIONAL list), `--restore` (re-enable everything this script
touches), `--list-only` (show pkg + status), `--dry-run`.

Preflight (hard-fails):
- `adb` on PATH (`apt install adb`).
- Exactly one authorized device — multi-device case prints serials and
  tells the user to set `ANDROID_SERIAL`.
- `getprop ro.product.device` == `rolex` — refuses to run on a
  different phone (the package list is Redmi-4A LineageOS-specific).

Lists in inline-commented arrays (same pattern as `debloat-kde.sh`):
- **SAFE** (default): apps with FOSS replacements, disabling does NOT
  break phone functionality — `jelly` (browser), `email`, `gallery3d`,
  `eleven` (music), `messaging` (SMS), `audiofx`, `setupwizard`,
  `fmradio`, legacy `soundrecorder`.
- **OPTIONAL** (`--include-optional`): `calculator2`, `deskclock`,
  `org.lineageos.recorder` — useful only if replacements are already
  installed. `org.lineageos.trebuchet` is in the file but commented
  out — disabling the default launcher with no replacement set as
  default locks the user out of the home screen.

Non-obvious gotchas — do not reintroduce:
- **`adb shell` stdout uses CRLF.** A naive `sed 's/^package://'` leaves
  a stray `\r` at the end of every package name; `grep -Fxq` then
  silently misses every match and the script reports every package as
  "not installed" no matter what's on the device. Pipe through `tr -d
  '\r'` BEFORE the sed.
- **Use `pm disable-user --user 0`, not `pm uninstall --user 0`.**
  disable-user is reversible without sideloading the APK; uninstall is
  reversible only via factory reset or APK push.
- **Re-enable via `pm enable --user 0`, not bare `pm enable`.** Older
  pm versions silently no-op `pm enable <pkg>` for things disabled
  per-user; `--user 0` matches the disable form.

### `setup_nordvpn.sh` — replace snap with official deb

Removes snap nordvpn, runs official install.sh, adds user to `nordvpn`
group. Log out/in for group change to take effect.

---

## launchers/

Per-run wrappers that apply the same perf profile before launching a
game. Drop in `~/.local/bin/` (already on PATH from `~/.zshrc`).

### Shared performance profile

Every launcher (and `skl` zsh alias) runs first:

```sh
sudo systemctl stop tlp                       # disable thermal/power throttling
sudo sysctl vm.swappiness=10                  # discourage swapping
sudo cpupower frequency-set -g performance    # pin CPU governor
```

Reverted on next boot (TLP comes back via systemd, kernel resets
sysctl/cpupower defaults). Intentional: gaming-only mode, no permanent
change.

### `stm` — Steam launcher

1. Apply perf profile.
2. Idempotently register `/games/steam` in `libraryfolders.vdf` — but
   only when Steam isn't running (writing VDF under live Steam risks
   corruption).
3. `exec steam` — **not** wrapped in `gamemoderun`. Wrapping the Steam
   client breaks CEF rendering because `libgamemodeauto.so` gets
   `LD_PRELOAD`ed into every webhelper subprocess; set
   `gamemoderun %command%` as per-game launch option instead.

Steam itself stays in `~/.steam` on sda2; only game content goes on
`/games/steam`. Games don't move automatically: set `/games/steam` as
default library in Steam Settings → Storage, move existing games via
Properties → Installed Files → Move Install Folder.

VDF path is `~/.steam/debian-installation/steamapps/libraryfolders.vdf`
on Debian (package `steam-installer`). On Ubuntu the package is `steam`
and path is `~/.steam/steam/steamapps/libraryfolders.vdf` — adjust the
`VDF=` line at the top of `stm`.

### `rbx` — Roblox-on-Waydroid launcher

Order matters — the X11/weston step must land before session start, else
the session daemon inherits no `WAYLAND_DISPLAY` and silently has no
surface:

1. Starts `waydroid-container.service` if not running (sudo, once per
   reboot).
2. Apply perf profile.
3. On X11: spawn nested `weston --socket=wayland-1` at 1600x900, wait
   for socket under `$XDG_RUNTIME_DIR`, export
   `WAYLAND_DISPLAY=wayland-1`. Pinning the socket name keeps the next
   step deterministic. On Wayland, no-op.
4. `setsid`-detach `waydroid session start` (logs to
   `/tmp/rbx-session.log`), poll `waydroid status` for
   `Session: RUNNING` (up to 180 s). Waydroid has two runtimes: the
   system container (Android processes) and a per-user session daemon
   (clipboard, input, surface creation, `app launch` IPC).
   `waydroid app launch` silently no-ops if session not `RUNNING`, hence
   the poll. **Note: `waydroid session status` is NOT a command** —
   `session` only takes `start`/`stop`; use top-level `waydroid status`
   and grep its output.

   Long timeout + `setsid` reasons: first-time Android cold boot on T480
   routinely takes 60-120 s (was 30 s — too short). And if rbx exits
   while background `session start` is still running, the launcher's job
   table tears down weston too — wayland socket vanishes mid-boot and
   the LXC bind-mount of `/run/user/$UID/wayland-1` hard-fails (visible
   in `/var/lib/waydroid/waydroid.log`). `setsid` for both keeps them
   alive across rbx exit; a timed-out launch is recoverable instead of
   needing reboot.
5. `exec waydroid app launch com.roblox.client`. Override via `$RBX_PKG`.

Alias: `alias rbx='~/install_roblox/rbx'` in `~/.zshrc` (or symlink
into `~/.local/bin/`).

### `rbxvm` — LineageOS / Android-x86 VM launcher (Roblox)

Boots the Roblox-only Android-x86 VM provisioned by `install-lineage.sh`.
Same perf profile, then one `exec qemu-system-x86_64` under KVM.

1. Preflight: `qemu-system-x86_64`/`qemu-img`/`sudo`/`systemctl`/`stat`
   on PATH; `/dev/kvm` present; `$LINEAGE_VM_DIR/disk.qcow2` exists.
   Hard-fails — no silent fallback to TCG (unplayable).
2. Apply perf profile. Skipped under `RBXVM_DRY=1` (non-TTY sudo prompt
   would block).
3. **First-boot ISO heuristic.** `stat -c%s disk.qcow2 < 1 MiB` decides
   whether to attach `-cdrom $ISO -boot order=dc,menu=on`. A fresh
   `qemu-img create -f qcow2 8G` is ~200 KB; once the guest installs
   Android-x86 the file grows past 1 MB long before first reboot. After
   install the cdrom is omitted so a stray reboot can't land in the
   installer GRUB and wipe the guest.
4. `exec qemu-system-x86_64` with `-cpu host -smp 4 -m 4096 -machine
   q35`; `virtio` disk with `discard=unmap` (qcow2 shrinks as guest
   TRIMs); `virtio-vga-gl` + `-display gtk,gl=on` for iGPU GL
   passthrough; `virtio-tablet` for absolute mouse (Android-x86's
   relative-input drifts); `intel-hda` + `hda-output` over
   `-audiodev pa,…` (PipeWire PA compat); `virtio-net` user-mode NAT.

Env knobs: `RBXVM_DRY=1` (print qemu command + exit; used by smoke test
and `-cpu`/`-smp` tuning); `LINEAGE_VM_DIR=<path>` (default
`$HOME/lineage_vm`; installer honors same var); `RBXVM_NO_AUTOSTART=1`
(skip ADB-driven Roblox autostart, drop to Android home);
`RBXVM_AUTOSTART_PKG=<pkg>` (override package, default
`com.roblox.client`).

**ADB autostart**: after QEMU launches, a backgrounded watcher polls
`adb connect 127.0.0.1:5555` for ~180 s; once guest package manager
answers, `monkey -p com.roblox.client -c LAUNCHER 1`. QEMU netdev
forwards host loopback 5555 → guest 5555 explicitly for this.
Best-effort: timeout → single warning, VM keeps running, you tap by
hand. Guest-side one-time setup (see LineageOS VM section): enable
Developer options + USB debugging, then `setprop service.adb.tcp.port
5555 && stop adbd && start adbd`; persist with
`echo 'persist.service.adb.tcp.port=5555' >> /system/build.prop` (needs
the writable `/system` picked at install time). `adb` from the `adb`
Debian package, pulled in by `install-lineage.sh`; missing at launch →
warn + skip (no hard-fail).

Resource sizing split with installer: `RAM_MB` (4096), `VCPUS` (4) here;
`DISK_SIZE` (8 GB) in `install-lineage.sh`. Tight by design — Roblox is
the only workload; real perf ceiling is the iGPU doing GL passthrough.

Non-obvious gotchas — do not reintroduce:
- **Don't switch `-audiodev pa,…` to `pipewire`.** Older qemu builds
  compile pipewire support out, failure mode is silent (no audio + no
  error). `pa` works against PipeWire's PulseAudio compat layer.
- **Don't drop the ISO heuristic for always-on `-cdrom`.** A stray
  reboot would land in the Android-x86 installer GRUB on a pre-installed
  disk and wipe the guest. For manual override, add `RBXVM_FORCE_ISO=1`
  env var, don't tear out the heuristic.
- **Graphics fallback is manual.** If guest hangs at splash, swap
  `-device virtio-vga-gl -display gtk,gl=on` for `-device VGA -display
  gtk` (software rendering, Roblox tanks but it boots). Don't
  auto-detect — failure mode is "hang", not a clean signal.

### `nic-boost` — temporary WiFi/EEE perf boost

Runtime-only NIC tweaks for bandwidth-heavy work. Deployed by
`install-nic-tuning.sh` into `~/.local/bin/nic-boost`. Lives here, not
in the permanent NIC installer, because both settings cost battery
*exactly when traffic is low* (remove idle-time hardware napping):

```
sudo iw dev <wifi> set power_save off    # ~0.3-0.5 W extra at idle
sudo ethtool --set-eee <eth> eee off     # ~0.5 W extra on idle link
```

Three shapes: `nic-boost` (apply, persist until reboot/`--off`);
`nic-boost <cmd>` (apply, run cmd, revert on exit — `trap revert EXIT
INT TERM` covers Ctrl-C/kill); `nic-boost --off` (revert manually). No
modprobe/dispatcher files written — settings revert on reboot via kernel
driver defaults. Same on/off pattern as `stm`/`rbx` for TLP/governor.

### `redmi-gaming` — apply/revert gaming profile on a connected Redmi 4A

Host-side ADB-driven toggle for a per-session gaming profile on a
LineageOS Redmi 4A (`rolex`). Same apply/revert pattern as `nic-boost`
— two shapes: bare (apply, persist until reverted) and `--off` (revert
to LineageOS defaults). `--dry-run` prints every `adb shell` command.

Non-root tweaks (always run):
- Animation scales `0.5x` on window/transition/animator (largest
  perceived-perf win on a 2 GB / SD425 phone; `0.5` not `0` so
  touch-target feedback stays legible).
- `settings put global low_power 0` — explicitly bail out of LineageOS
  battery saver, which throttles CPU + bg sync.
- `am force-stop` of `HEAVY` apps (`com.google.android.gms`,
  `com.android.vending` by default — both no-ops if not installed).

Root-only tweaks (require Magisk `su` OR `adb root` via LOS Developer
Options → "Rooted debugging"; skipped with a `skip (root needed): …`
note if neither is available):
- All CPUs pinned to `performance` governor (SD425's
  schedutil/interactive ramp is conservative enough to cost frames in
  touch-heavy games).
- GPU governor pinned to `performance` (`/sys/class/kgsl/kgsl-3d0`).

Revert restores `1.0` animation scales and the stock rolex governors
(`schedutil` on CPU, falling back to `interactive` on older LOS;
`msm-adreno-tz` on GPU).

Non-obvious gotchas — do not reintroduce:
- **Guard `adb root` with `(( ! dry ))`.** `adb root` restarts adbd as
  root and bounces the USB connection; running it under `--dry-run`
  defeats the "no side effects" contract. The Magisk `su` path is
  side-effect-free and tried first.
- **`adb shell "su -c '$*'"` works for the no-`'` commands here but
  is brittle if a future tweak embeds a single quote.** If you add one,
  switch that call to heredoc-via-stdin.

### `skl` — Minecraft (zsh alias, not a script)

Lives in `~/.zshrc`:

```sh
alias skl='sudo systemctl stop tlp; sudo sysctl vm.swappiness=10; \
  sudo cpupower frequency-set -g performance; \
  gamemoderun java -jar ~/Desktop/SKlauncher-3.2.18.jar --workDir /games/minecraft'
```

Updated from earlier broken versions: `sudo tlp stop` (invalid tlp
subcommand) and `/mnt/minecraft` (stale mountpoint, now
`/games/minecraft`).

### Gotchas common to all launchers

- First launch after reboot pays warm-up (Steam: a few seconds for
  library scan; Waydroid: 30–60 s for container).
- TLP stop is sticky until reboot. `sudo systemctl start tlp` after the
  game to get it back without rebooting.
- `cpupower` requires `linux-cpupower` (or `linux-tools-$(uname -r)`).
  `utils.sh` installs both, with `linux-tools-$(uname -r)` fallback for
  non-Liquorix kernels.
- Launchers assume `sudo` is NOPASSWD for these specific commands OR
  you accept the prompt every launch. Sudoers drop-in: limit to
  `systemctl stop tlp`, `sysctl vm.swappiness=10`,
  `cpupower frequency-set -g performance` exactly — never NOPASSWD a
  whole class.

---

## autostarts/

XFCE `.desktop` autostart files. Drop into `~/.config/autostart/` (per
user) or `/etc/xdg/autostart/` (system-wide). XFCE reads `[Desktop
Entry]` files and runs `Exec=`. `X-GNOME-Autostart-enabled=true` is
honored despite the GNOME prefix.

- **`alacritty-autostart.desktop`**: starts
  `alacritty --gapplication-service` so subsequent invocations attach to
  the running service (faster spawn, shared font/config cache).
  `Hidden=true` + `NoDisplay=true` keep it out of the application menu
  so users can't accidentally toggle it off in Session and Startup.
- **`brave-autostart.desktop`**: plain `brave-browser` at login.
  `StartupNotify=true` so the cursor shows launching state. Visible in
  Session and Startup UI — disable on low-RAM machines.
- **`easyeffects.desktop`**: same `--gapplication-service` pattern as
  alacritty. Required if you want presets (EQ, autogain) to apply to
  every audio stream from session start, not from first GUI open.

Notes:
- `nohup` in `Exec=` is defensive — XFCE's session manager already
  detaches autostart processes, but `nohup` ensures a stray HUP from
  the launching shell can't kill them.
- Trailing `&` inside `Exec=` is ignored by the .desktop spec but
  harmless.

---

## nord-job/ — random NordVPN country rotation

Files:
- `~/.local/bin/nord-rand` — the script (NordLynx, kill switch, threat
  protection, autoconnect baked into `setup` mode)
- `nord-rand.cron` — crontab snippet, installed via `crontab
  nord-rand.cron`
- `~/Desktop/nord-rand.log` — ISO-8601 timestamped, append-only, no
  rotation
- `/media/fred/8B35-3F46/nord-rand` + `.cron` — SD-card backup
  (FAT/exFAT drops +x bit; `chmod +x` after copy back)

Modes:
- `nord-rand` — pick random country from `nordvpn countries`, **skip if
  already connected**
- `nord-rand force` — same, but disconnect-and-reconnect even when
  connected. **This is what cron runs.**
- `nord-rand setup` — one-time config. Requires prior `nordvpn login`.
  Sets technology + protections, enables autoconnect, tries
  `post-quantum` (ignored on older clients).
- `nord-rand kill on|off` — toggle kill switch. `off` is the escape
  hatch for plain internet.

Cron: `0 */6 * * * /home/fred/.local/bin/nord-rand force >/dev/null
2>&1` — every 6 hours. Output silenced because the script logs
internally.

**Autoconnect ↔ option-B conflict**: user picked "skip if connected"
(option B) but also enabled NordVPN autoconnect. Autoconnect keeps VPN
up 24/7, so plain `nord-rand` would never rotate. Resolution: cron uses
`force`; manual invocations default to soft skip. Revert to literal
option B by dropping `force` from the cron line.

Country list: pulled live from `nordvpn countries` every invocation —
no hardcoded array. `list_countries()` strips ANSI, normalizes
whitespace/commas to one country per line, drops separator dashes; CLI
naming (underscores for spaces, e.g. `United_Kingdom`) preserved. Retry
tolerates up to `MAX_TRIES` (5) unavailable picks. To restrict pool
(e.g. EU-only), filter inside `list_countries`.

Prereqs not handled by the script: nordvpn daemon installed + user in
`nordvpn` group; `nordvpn login` run interactively at least once
(browser flow); `nord-rand setup` run once after login.

Failure modes worth knowing:
- Kill switch ON + VPN daemon dead → no internet. Recover with
  `nord-rand kill off` or `sudo systemctl restart nordvpnd`.
- 5 attempts all hit unavailable countries → exit 1, log shows
  `fail: MAX_TRIES attempts exhausted`. Re-run or narrow pool.
- Cron silently dropping mail (no MTA): expected. Visibility is in
  `~/Desktop/nord-rand.log`.

---

## LineageOS VM (Roblox-only)

QEMU/KVM-backed Android-x86 VM dedicated to Roblox. Same perf profile
as `stm`/`rbx`/`skl` (see `~/CLAUDE.md`). `lineage_vm/` holds the VM's
data files; installer + launcher live elsewhere:

| File         | Path                                                      |
|--------------|-----------------------------------------------------------|
| Installer    | `~/steves_debian_setup/installers/install-lineage.sh`     |
| Launcher     | `~/.local/bin/rbxvm`                                      |
| Disk image   | `/home/fred/lineage_vm/disk.qcow2` (8 GB ceiling, sparse) |
| Install ISO  | `/home/fred/lineage_vm/android-x86.iso` (~700 MB)         |

### Why Android-x86 and not literal LineageOS

LineageOS does not ship an official x86_64 image — every desktop
"LineageOS-style" distro (Bliss OS, LineageOS-x86) is a fork of upstream
**Android-x86**. Installer defaults to **Android-x86 9.0-r2** (newest
stable) because Bliss OS is under "temporary LOCKDOWN" (blissos.org as
of 2026-05, no fresh builds). Android-x86 9.0-r2 is Android 9 (Pie) —
old, but Roblox-Android still supports it and the boot story under KVM
is well-trodden. To swap in a fork build later, pass `LINEAGE_ISO_URL=`.
The launcher doesn't care what's on the ISO — just attaches it to
CD-ROM.

### Resource sizing — 4 vCPU / 4 GiB RAM / 8 GiB qcow2

Tight by design; Roblox is the only workload. Real ceiling for
smoothness is the **host iGPU** (T480 UHD 620) doing GL passthrough via
`virtio-vga-gl` — no vCPU/RAM/disk count fixes that. Logic: 4 vCPU
(Roblox-on-Android is 1-2 thread bound; 4 leaves host headroom);
4096 MB RAM (Roblox's recommended Android spec); 8 GB disk (qcow2 is
sparse ~200 KB at create, ceiling is free — covers ~3 GB Android-x86
install + Roblox APK and asset cache ~1 GB with room for updates).
Override: `RAM_MB`/`VCPUS` in `rbxvm`, `DISK_SIZE` in
`install-lineage.sh`.

### First-boot install dance

1. `rbxvm` boots with `-cdrom android-x86.iso -boot order=dc`. CD only
   attached on first boot (ISO heuristic above).
2. GRUB default is **Live mode**. Arrow down to **Installation** —
   easy to miss.
3. Partition virtio disk (`sda`) as one ext4, install GRUB, install
   system as **read-write** (menu calls this "/system" — pick yes so
   updates and app installs stick).
4. Power off (don't reboot — installer's CD is still attached for *this*
   QEMU process; only killing QEMU and re-running `rbxvm` drops the
   ISO).
5. Subsequent runs boot from disk. ISO stays in `/home/fred/lineage_vm`
   for `--reinstall`.

### Roblox install — Play Store is not bundled

Android-x86 ships without Google Play Services. To install Roblox:
sideload the **APKMirror** Roblox APK over a browser inside the guest,
OR install **Aurora Store** (anonymous Play Store proxy) and pull from
there. Roblox-Android's HW requirements are easy; runtime ceiling is GL
passthrough perf.

### Boot-straight-into-Roblox via ADB autostart

See `rbxvm` section above. Guest-side one-time setup:

1. **Developer options**: Settings → System → About tablet → tap *Build
   number* 7×.
2. **USB debugging**: Settings → System → Developer options → *USB
   debugging* on. "Allow USB debugging?" RSA prompt appears first time
   host `adb connect`s — tap *Always allow*.
3. **ADB-over-network + persist**:
   ```sh
   setprop service.adb.tcp.port 5555
   stop adbd && start adbd
   # Persist across guest reboots:
   echo 'persist.service.adb.tcp.port=5555' | su -c 'tee -a /system/build.prop'
   ```
   `/system` edit requires the writable `/system` from install dance.
   Read-only `/system` makes the persist line silently no-op — autostart
   works this boot, breaks next.

Skip with `RBXVM_NO_AUTOSTART=1 rbxvm`; override package with
`RBXVM_AUTOSTART_PKG=<pkg>`.

### Non-obvious gotchas (do not reintroduce)

- **`stat -c%s "$DISK" < 1048576` heuristic** is load-bearing — replacing
  with always-on `-cdrom` lets users accidentally pick "Installation"
  from GRUB and wipe their setup; replacing with no-`-cdrom` breaks
  first-run install. For manual override use `RBXVM_FORCE_ISO=1`.
- **Graphics path: `virtio-vga-gl` + `-display gtk,gl=on`** — what the
  iGPU can accelerate. Hang at splash → swap for `-vga std -display gtk`
  (software, no GL). Not auto-detected; failure mode is "hang" — no
  clean signal.
- **Sudo**: `rbxvm`'s `systemctl stop tlp`/`sysctl`/`cpupower` are
  NOPASSWD on this box (like `stm`/`rbx`). Installer's `apt-get` is
  NOT NOPASSWD — `install_pkgs()` `dpkg-query`-checks first, only
  invokes `sudo apt-get` if a package is missing.
- **`-boot order=dc`** = CD then disk. Combined with ISO heuristic, GRUB
  on first boot is the installer GRUB; after install (ISO detached),
  `-boot` is omitted and QEMU's default order finds the qcow2's GRUB.
- **Audio**: `-audiodev pa,…` works against PipeWire's PulseAudio compat.
  Don't switch to `pipewire,…` without testing (older qemu compiles
  pipewire support out, silent fail).
- **`virtio-tablet`** needed for absolute mouse — Android-x86's
  relative-input is rough.
- **`RBXVM_DRY=1`**: print assembled qemu command without launching.

### Operations cheatsheet

```
# Fresh install (one-time):
~/steves_debian_setup/installers/install-lineage.sh

# Launch:
rbxvm

# Inspect command without launching:
RBXVM_DRY=1 rbxvm

# Swap to Bliss OS (once it returns):
LINEAGE_ISO_URL=https://.../BlissOS-x86_64.iso \
  ~/steves_debian_setup/installers/install-lineage.sh --reinstall

# Wipe + start over:
~/steves_debian_setup/installers/install-lineage.sh --reinstall

# Tear down (keeps QEMU packages):
~/steves_debian_setup/installers/install-lineage.sh --uninstall
```

---

## installers/patches/

Vendored upstream patches applied at build time by specific installers.

- **`tmux-dim-inactive-panes.patch`** — origin: chud-methodology
  (anonymous.4open.science/r/chud-methodology-1477). Adds `colour_dim()`
  to `colour.c` (perceptual-luma desaturate 30% + blend 35% toward
  target bg), a `dim_inactive` flag on `struct tty`, and hooks in
  `screen-redraw.c` / `screen-write.c` / `tty.c` that set/clear it
  around per-pane draws. Applied by `install-tmux-dim.sh` against the
  tmux 3.5a release tarball; the script does a `patch --dry-run` first
  so a future tmux drift fails loud instead of producing a silently
  unpatched binary.

---

## installers/discontinued/

Scripts kept on disk for institutional knowledge (kernel binder
probing, Bliss OS history, X11/Wayland nesting tricks) but not on the
default install path. They still pass `bash -n` and may still work on
the right box.

### `install-roblox.sh` — interactive Waydroid + APK setup

8 sections, each prefaced by ELI5 + y/N prompt. Flags: `-y` skips
prompts, `--dry-run` prints actions. Tuned for MX XFCE on T480 (Intel
UHD 620, x86_64, X11); on mismatched hardware/distros warns instead of
bailing.

Decisions:
- **VANILLA system image, not GAPPS** — Roblox accepts email + 2FA, so
  Play Services not needed, save ~300 MB.
- **Weston for X11** — Waydroid is a Wayland client; XFCE is X11.
  `weston` is upstream-recommended nested compositor (<5 MB), spawned
  by `rbx` when `$XDG_SESSION_TYPE != wayland`.
- **libndk via casualsnek/waydroid_script** — Roblox APK is arm64,
  T480 is x86_64; `libndk_translation` bridges. waydroid_script is the
  de-facto community installer. Run inside script-local venv so nothing
  leaks into system Python.
- **Pixel 5 device spoof** — default Waydroid props identify as
  `emulator`, Roblox integrity check rejects. Pixel 5 is the
  waydroid_script default and known-accepted at time of writing.
- **`persist.waydroid.multi_windows=true`** — load-bearing for `rbx`.
  Without it, `waydroid app launch` renders only inside full Android
  desktop, launcher would need `waydroid show-full-ui` + manual tap.
- **APK from uptodown** — unmodified vendor APKs. Setup tries two regex
  shapes (uptodown HTML changed twice), falls back to manual-download
  message on Cloudflare challenge (those return HTTP 200, so we re-check
  ZIP magic bytes before declaring success).
- **Step 3 installs `lzip` before `waydroid init`**. System+vendor
  images are `.lzip`-compressed and `init` shells out to external
  `lzip`. The Debian `waydroid` package doesn't depend on lzip — fresh
  box hits half-populated `/var/lib/waydroid` and init fails partway.
- **`sh` re-exec guard at top.** Script uses `[[`, `((`, `[Yy]*` glob
  matching — all unknown commands to dash. `set -e` does **not** fire
  on bashism failures inside `if` conditions, so dash limps along making
  wrong decisions (e.g. `ask` returns false on `y`) instead of erroring
  at line 1. Guard uses POSIX `[ -z "${BASH_VERSION:-}" ]`. (Now repo
  convention — see **Conventions**.)
- **Step 1's binder check hard-fails on missing
  `CONFIG_ANDROID_BINDER_IPC`**. Binder is the Android IPC mechanism;
  whole Android userland in Waydroid talks through it. Mainline Linux,
  but distros toggle: Debian stock builds `=m`, Liquorix 6.19 builds it
  off. Previous check looked at `/sys/module/binder_linux` + `lsmod`,
  but a not-compiled-in kernel exposes neither; fallback `modinfo`
  branch silently warned-and-continued — burning a 500 MB image download
  before failing at `waydroid init`. New three-way probe: (a)
  `/sys/module/binder_linux`, (b) `binder` in `/proc/filesystems`
  (built-in signature), (c) `binder_linux.ko*` under
  `/lib/modules/$(uname -r)`. All three miss → exit with actionable fix
  (`sudo apt install linux-image-amd64 && sudo reboot` boots Debian
  kernel alongside Liquorix). No override-and-continue by design.
- **Step 1 also fixes `vndbinder`/`hwbinder` device discovery.** Even
  with binder loaded, waydroid needs three IPC domains: `binder` (app/
  framework), `hwbinder` (HALs), `vndbinder` (vendor). Three security
  contexts, not aliases. Most desktop kernels build with
  `CONFIG_ANDROID_BINDER_DEVICES="binder"` (one device) and disable
  `CONFIG_ANDROID_BINDERFS` (no dynamic creation), so init fails with
  `Binder node "vndbinder" for waydroid not found`. Fix: `binder_linux`
  has module param `devices=` (charp) that overrides the kernel's
  static list. Step 1 checks `/dev/binder`/`/dev/hwbinder`/
  `/dev/vndbinder`; if any missing, writes
  `/etc/modprobe.d/waydroid-binder.conf` with
  `options binder_linux devices=binder,hwbinder,vndbinder`, `rmmod`s,
  `modprobe`s. Idempotent (the missing-device check skips on rerun).
  Built-in binder (`=y`) cannot be rebound this way — script tells the
  user to add `binder_linux.devices=binder,hwbinder,vndbinder` to GRUB
  kernel cmdline and reboot.

Roblox layout (`~/install_roblox/`, runtime-populated): `roblox.apk`
(uptodown), `waydroid_script/` (cloned casualsnek/waydroid_script, step
5), `venv/` (local Python venv). Waydroid container state under
`/var/lib/waydroid` — tied to kernel, no split-partition story (unlike
Steam/Minecraft on `/games/`).

### `check-roblox-prereqs.sh` — pre-flight gate for `install-roblox.sh`

Standalone preflight mirroring the installer's conditions so users can
run it before the 8-step script instead of bailing partway. Same
`[OK]/[FAIL]` style as `check-setup.sh`; exit 0 if every hard condition
met, 1 if any fails. Soft conditions print `[WARN]` without flipping
exit.

Hard: (1) kernel name does NOT contain `liquorix`/`zen` (those builds
disable `CONFIG_ANDROID_BINDER_IPC`; reboot into stock); (2)
`CONFIG_ANDROID_BINDER_IPC=m` in `/boot/config-$(uname -r)` — `=y`
downgrades to `[WARN]` (works but needs kernel cmdline arg); (3)
`waydroid` on PATH; (4) `getent hosts ota.waydro.id` resolves.

Soft: waydroid-container running (installer stops it), sudo cached,
stdin TTY, X11 vs Wayland session.

### `install-lineage.sh` — QEMU/KVM + Android-x86 ISO + qcow2 disk

Provisions host side of the Roblox VM that `rbxvm` boots. Three
idempotent actions:

1. `apt-get install qemu-system-x86 qemu-system-gui qemu-utils ovmf` —
   only the missing ones (`dpkg-query` short-circuits apt + sudo prompt
   when everything's there). `qemu-system-gui` is load-bearing — ships
   the GTK display + virgl renderer that `-display gtk,gl=on` needs.
2. `curl` Android-x86 9.0-r2 ISO (~700 MB, follows SourceForge mirror
   redirect) to `$LINEAGE_VM_DIR/android-x86.iso`. Skips if present and
   non-empty.
3. `qemu-img create -f qcow2 … 8G` at `$LINEAGE_VM_DIR/disk.qcow2`.
   Sparse — ~200 KB on disk until guest writes. Skips if disk exists.

Modes: bare, `--reinstall` (wipe + redo), `--uninstall` (wipe, keep
QEMU packages), `--dry-run`. Hard preflights: `/dev/kvm` exists;
`curl`/`sudo`/`apt-get`/`stat` on PATH.

See **LineageOS VM (Roblox-only)** above for the full first-boot dance,
Roblox sideload, ADB-over-network setup, and gotchas. Env overrides:
`LINEAGE_ISO_URL=<url>` (swap fork build — drop Bliss OS URL here when
their lockdown lifts), `LINEAGE_VM_DIR=<path>` (default
`$HOME/lineage_vm`; launcher honors same var).

Resource sizing split with launcher: `DISK_SIZE` here, `RAM_MB`/`VCPUS`
in `rbxvm`.

### `install-lxqt.sh` — alternative DE: LXQt + bilingual keyboard + Albert

Drops `lxqt + sddm` alongside XFCE (pick at SDDM login). Pre-seeds:
bilingual us/ru keyboard (Meta+Space toggle), F5/F6 brightness via
`brightnessctl`, bottom panel with FancyMenu in the left slot, Albert
as alt+space launcher, `xcape` autostart turning bare-Meta tap into
`XF86LaunchA` so the menu opens on Super alone. Modes: bare,
`--dry-run`. No `--uninstall` — purging LXQt while logged into LXQt is
a TTY-rescue recipe.

Albert from upstream OBS repo (signed key under
`/etc/apt/keyrings/albert.gpg`); skipped if `albert` is on PATH. Every
config file overwritten unconditionally — script treats
`~/.config/lxqt/*.conf`, `~/.config/albert/albert.conf`, and the two
`~/.config/autostart/*.desktop` entries as derived artifacts, not user
state. Hand-edits don't survive rerun.

### `debloat-xfce.sh` — strip XFCE after switching to another DE

Parallel to `debloat-mx.sh`/`debloat-kde.sh`. Idempotent, `--dry-run`-able.
Two hard-fail preflights: (1) active session must NOT be XFCE (refuses
if `$XDG_CURRENT_DESKTOP` is `*xfce*` — removing XFCE while it's live
kills the session); (2) XFCE must be installed somewhere (checks
`xfwm4` — refuses otherwise so a "0 packages" exit doesn't mask a bad
invocation).

Removal groups: metas (`xfce4`, `task-xfce-desktop`, `xfce4-goodies`);
core (xfwm4, xfdesktop4, xfconf, xfce4-session/settings/panel/notifyd/
appfinder/power-manager); wildcards (`'xfce4-*'`, `'libxfce4*'`,
`'thunar-*'` — catches the long tail of panel plugins, goodies, runtime
libs); apps (thunar, mousepad, ristretto, parole, orage); xubuntu
(`'xubuntu-*'` — no-op on Debian/MX). To bring XFCE back:
`sudo apt install xfce4`.
