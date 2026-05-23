# installers/

Idempotent, dry-runnable setup scripts. Each is independent — pick the
ones you need on a given box. All follow the conventions in the root
`CLAUDE.md`: bash re-exec guard, `set -euo pipefail`, `--dry-run`, no
creds, no scraping behind logins, hard-fail preflight.

The `discontinued/` subfolder holds scripts no longer on the default
install path (Roblox, Lineage VM, LXQt, XFCE-purge) — see that folder's
own `CLAUDE.md` for the technical notes.

## `utils.sh` — bulk bootstrap

The one big script. Resolves every dependency referenced by `~/.zshrc`
on a Debian/Ubuntu box: apt packages, oh-my-zsh + plugins, fzf shell
integration, user toolchains (rustup, rbenv, atuin, starship, nvm, deno,
bun, pyenv), Go and neovim from upstream tarballs, third-party installers
(brave, waydroid), pip tools, flatpak + Organic Maps, Claude Code,
NordVPN, tmux config, helper scripts, XFCE + KDE keybindings, and
EasyEffects presets. Numbered sections (1–15) match `check-setup.sh`'s
verification order; step 14 is intentionally a no-op stub — debloat
moved out to `debloat-mx.sh` (run it separately with `--intel-only` for
the old nvidia-purge behaviour). `--dry-run` prints every action without
mutating; for the curl-piped third-party installers and the `cat >
heredoc` helper-script writes it prints a short summary instead of
trying to render the whole pipe.

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
  spawns on every folder browse)

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
