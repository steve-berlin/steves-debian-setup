# Gaming utilities (archived)

The scripts described below **no longer live in this repo.** As of commit
`592ca4c` (2026-06-07) they were split out:

- Steam / The Long Dark / scrcpy / NIC tuning installers + `stm` / `rbx` /
  `rbxvm` launchers + `skl` Minecraft alias + Waydroid/Android-x86 VM
  setup → **[steves-gaming-utils](https://github.com/steve-berlin/steves-gaming-utils)**
- Redmi 4A debloater + `redmi-gaming` launcher → **[steves-redmi-setup](https://github.com/steve-berlin/steves-redmi-setup)**

These notes are kept here as institutional knowledge — gotchas, ordering
constraints, and "why" decisions that don't survive in commit messages.
For deploy detail consult the moved repos' own `CLAUDE.md`/`README.md`.

## Gaming partitions

`/games/steam` (sda3) + `/games/minecraft` (sda4) mounted via `/etc/fstab`. Launchers + `gaming/install-tld.sh` hard-code those paths; edit constants at script top on a different box. See `~/CLAUDE.md` for disk layout and why Steam itself stays in `~/.steam` while only game *content* lives on `/games/steam`.

## VM / container runtime data (not committed)

- Roblox APK, Waydroid image, Steam game data, Minecraft worlds — fetched on demand
- `~/install_roblox/{waydroid_script,venv}/` — runtime-created
- VM disk + ISO under `~/android-vm/` — created by `install-android-vm.sh`

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

## debloat_scripts/debloat-redmi.sh — disable LineageOS preinstalled apps on a Redmi 4A

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

## installers/discontinued/ — Roblox / Android-x86 VM setup

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
