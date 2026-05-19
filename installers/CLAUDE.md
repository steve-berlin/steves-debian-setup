# installers/

Idempotent, dry-runnable setup scripts. Each is independent — pick the
ones you need on a given box. All follow the conventions in the root
`CLAUDE.md`: `set -euo pipefail`, `--dry-run`, no creds, no scraping
behind logins, hard-fail preflight.

## `utils.sh` — bulk bootstrap

The one big script. Resolves every dependency referenced by `~/.zshrc`
on a Debian/Ubuntu box: apt packages, oh-my-zsh + plugins, fzf shell
integration, user toolchains (rustup, rbenv, atuin, starship, nvm, deno,
bun, pyenv), Go and neovim from upstream tarballs, third-party installers
(brave, waydroid), pip tools, flatpak + Organic Maps, Claude Code,
NordVPN, tmux config, helper scripts, XFCE keybindings, and EasyEffects
presets. Numbered sections (1–15) match `check-setup.sh`'s verification
order; step 14 is intentionally a no-op stub — debloat moved out to
`debloat-mx.sh` (run it separately with `--intel-only` for the old
nvidia-purge behaviour). `kate` is in the apt install list because it's
the user's go-to GUI editor (pulls Qt6 + KF6 deps; ~150 MB).

Two known issues to fix in a future pass:
- Line 2 hard-codes `/home/alex/.zsh/completions` in FPATH (left over
  from the source machine).
- Line 151 warns about rotating `GH_TOKEN` / `ANTHROPIC_API_TOKEN` in
  `~/.zshrc` — those should never live in shell config.

## `check-setup.sh` — post-bootstrap verifier

Mirrors `utils.sh` step-for-step and prints `[OK]` / `[FAIL]` per check.
Exit 0 if all pass. Use it as the smoke test after `utils.sh` and after
any system upgrade that touches the GPU stack (the iGPU/nouveau check
will catch a regression).

## `install-steam.sh` — Steam from apt + non-free

Adds the i386 architecture and (on Debian) ensures the
`contrib non-free non-free-firmware` components are enabled, then
installs `steam-installer` (Debian) or `steam` (Ubuntu). Modes mirror
`install-tld.sh` / `install-anki.sh`: bare install, `--reinstall`,
`--uninstall`, `--dry-run`. Does NOT touch `libraryfolders.vdf` —
the `stm` launcher registers `/games/steam` on first run.

## `install-tld.sh` — The Long Dark (re)installer

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

## `install-anki.sh` — official upstream tarball

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

## `install-roblox.sh` — interactive Waydroid + APK setup

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
  either shell.
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

## `check-roblox-prereqs.sh` — pre-flight gate for `install-roblox.sh`

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

## `install-lineage.sh` — QEMU/KVM + Android-x86 ISO + qcow2 disk

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
in `../lineage_vm/CLAUDE.md` (the deployed-state doc — covers
first-boot install, Roblox sideload, ADB-over-network setup for
autostart, gotchas, and an operations cheatsheet). Play Store is not
bundled — sideload Roblox via APKMirror or pull it through Aurora
Store inside the guest.

## `install-nic-tuning.sh` — permanent NIC tuning (zero power cost)

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
session and revert on reboot. See `launchers/CLAUDE.md` for nic-boost.

The dispatcher script bails early on wifi (`exit 0` if
`/sys/class/net/$iface/wireless` exists) so it never touches WiFi
power state — kept ethernet-only on purpose.

## `install-tmux-immortal.sh` — persist tmux sessions across reboots

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

## `install-lxqt.sh` — alternative DE: LXQt + bilingual keyboard + Albert

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

## `debloat-mx.sh` — strip MX Linux bundled apps

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

Modes: bare, `--dry-run`, `--intel-only` (also purges
`nvidia-*`/`libnvidia-*`/`xserver-xorg-video-nouveau` and writes
`/etc/modprobe.d/blacklist-nouveau.conf` + reruns `update-initramfs`
— matches the old `utils.sh` step 14 behaviour for Intel-iGPU
laptops).

Implementation note: a single `expand_installed` helper accepts both
literal package names and shell globs (e.g. `'libreoffice-*'`,
`'mx-packageinstaller*'`), enumerates them via `dpkg-query` selectors,
and filters down to installed-only — so re-runs on a debloated box
are no-ops and one apt invocation handles everything.

## `debloat-kde.sh` — strip a Debian/MX KDE Plasma install

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
- **bluetooth (opt-in via `--no-bluetooth`)**: bluedevil, bluez,
  bluez-obexd, blueman, `'libbluetooth*'`

Holds `kdeaccessibility` before any removes — otherwise the chained
`apt autoremove --purge` at the end strips it as a transitive dep.
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

## `setup_nordvpn.sh` — replace snap with official deb

Removes any snap-installed nordvpn, runs the official install.sh,
adds the user to the `nordvpn` group. Log out/in afterward for the
group change to take effect.
