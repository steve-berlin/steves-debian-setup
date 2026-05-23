# installers/discontinued/

Scripts kept on disk for the institutional knowledge they encode (kernel
binder probing, Bliss OS history, X11/Wayland nesting tricks) but no
longer recommended for fresh setups. Reasons vary per script — see each
section. They still pass `bash -n` and may still work on the right box;
they're just not on the default install path.

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
  either shell. (This pattern is now repo convention — every active
  installer adopts it; see root `CLAUDE.md`.)
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
in `../../lineage_vm/CLAUDE.md` (the deployed-state doc — covers
first-boot install, Roblox sideload, ADB-over-network setup for
autostart, gotchas, and an operations cheatsheet). Play Store is not
bundled — sideload Roblox via APKMirror or pull it through Aurora
Store inside the guest.

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

## `debloat-xfce.sh` — strip XFCE after you've switched to another DE

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
