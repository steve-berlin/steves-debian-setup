# LineageOS VM (Roblox-only)

A QEMU/KVM-backed Android-x86 VM dedicated to running Roblox. Same
"stop TLP / drop swappiness / pin governor" perf profile as `stm`,
`rbx`, `skl` — see `~/CLAUDE.md`.

This directory holds the VM's data files. The installer and launcher
live elsewhere:

| File                | Path                                                              |
|---------------------|-------------------------------------------------------------------|
| Installer           | `~/steves_debian_setup/installers/install-lineage.sh`             |
| Launcher            | `~/.local/bin/rbxvm`                                                |
| Disk image          | `/home/fred/lineage_vm/disk.qcow2`  (8 GB ceiling, qcow2 sparse)  |
| Install ISO         | `/home/fred/lineage_vm/android-x86.iso`  (~700 MB)                |

## Why Android-x86 and not literal LineageOS

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

## Resource sizing — 4 vCPU / 4 GiB RAM / 8 GiB qcow2

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

## First-boot install dance

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

## Roblox install — Play Store is not bundled

Android-x86 ships without Google Play Services. To install Roblox:

- Sideload the **APKMirror** Roblox APK over a browser inside the
  guest, OR
- Install **Aurora Store** (anonymous Play Store proxy) and pull
  Roblox from there.

The Roblox Android app's HW requirements are easy to meet — the actual
runtime ceiling is the GL passthrough perf, not CPU/RAM.

## Boot-straight-into-Roblox via ADB autostart

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

## Non-obvious gotchas — do not reintroduce

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

## Operations cheatsheet

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
