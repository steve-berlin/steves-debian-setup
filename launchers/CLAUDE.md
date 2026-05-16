# launchers/

Per-run wrappers that apply the same performance profile before launching
a game. Drop them in `~/.local/bin/` (already on PATH from `~/.zshrc`).

## Shared performance profile

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

## `stm` — Steam launcher

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

## `rbx` — Roblox-on-Waydroid launcher

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

## `lng` — LineageOS / Android-x86 VM launcher (Roblox)

Boots the Roblox-only Android-x86 VM provisioned by
`installers/install-lineage.sh`. Same perf profile as `stm`/`rbx`/`skl`,
then a single `exec qemu-system-x86_64` under KVM.

Order:

1. Preflight: `qemu-system-x86_64`/`qemu-img`/`sudo`/`systemctl`/`stat`
   on PATH; `/dev/kvm` present; `$LINEAGE_VM_DIR/disk.qcow2` exists.
   Hard-fails loud — no silent fallback to TCG (would be unplayable).
2. Apply the perf profile (TLP stop, swappiness, governor — same as
   `stm`/`rbx`/`skl`). Skipped under `LNG_DRY=1` so the dry-run is
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
- `LNG_DRY=1` — print the assembled qemu command and exit. Used by
  the install smoke test and when tuning `-cpu`/`-smp`/resource flags.
- `LINEAGE_VM_DIR=<path>` — point at a non-default VM directory
  (default: `$HOME/lineage_vm`). The installer honors the same var.
- `LNG_NO_AUTOSTART=1` — skip the ADB-driven Roblox autostart and just
  drop you at Android's home screen (useful for guest maintenance).
- `LNG_AUTOSTART_PKG=<pkg>` — override the package to launch (default
  `com.roblox.client`).

## `lng` ADB autostart

After QEMU launches, `lng` backgrounds a watcher that polls
`adb connect 127.0.0.1:5555` for ~180 s and, once the guest's package
manager answers, `monkey`-launches the Roblox `LAUNCHER` intent. The
QEMU netdev line forwards host loopback 5555 → guest 5555 explicitly
for this. Best-effort by design: if the guest hasn't been installed
yet (first boot), or ADB-over-network isn't enabled inside the guest,
or Roblox isn't sideloaded, the loop times out cleanly and emits a
single warning — the VM keeps running and you tap Roblox by hand.

Guest-side one-time setup (do this inside the VM after sideloading
Roblox — see `../lineage_vm/CLAUDE.md` for the full recipe):
Settings → System → About → tap Build number 7× → Developer options
→ enable USB debugging; then in any Android terminal app, run
`setprop service.adb.tcp.port 5555 && stop adbd && start adbd`
(persist across reboot by appending `persist.service.adb.tcp.port=5555`
to `/system/build.prop`; needs the writable /system you picked at
install time).

`adb` lives in the `adb` Debian package and is pulled in by
`install-lineage.sh`. If it's missing at launch time `lng` warns and
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
  needed, add an `LNG_FORCE_ISO=1` env var rather than tearing out
  the heuristic.
- **Graphics fallback is manual, not auto-detected.** If the guest
  hangs at the splash, swap `-device virtio-vga-gl -display gtk,gl=on`
  for `-device VGA -display gtk` (software rendering — Roblox tanks
  but it boots). Don't auto-detect: the failure mode is "hang", which
  isn't a clean signal.

## `nic-boost` — temporary WiFi/EEE perf boost

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

## `skl` — Minecraft (zsh alias, not a script)

Lives in `~/.zshrc` as a one-liner because there's nothing to wrap
beyond the perf tweaks and the SKlauncher jar:

```sh
alias skl='sudo systemctl stop tlp; sudo sysctl vm.swappiness=10; \
  sudo cpupower frequency-set -g performance; \
  gamemoderun java -jar ~/Desktop/SKlauncher-3.2.18.jar --workDir /games/minecraft'
```

Updated from earlier broken versions: `sudo tlp stop` (invalid tlp
subcommand) and `/mnt/minecraft` (stale mountpoint, now `/games/minecraft`).

## Gotchas common to all launchers

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
