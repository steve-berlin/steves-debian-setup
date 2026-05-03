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

Same perf tweaks as `stm`, then:

1. Starts `waydroid-container.service` if not already running (sudo
   once per reboot).
2. Backgrounds `waydroid session start` and polls `waydroid session
   status` for up to 10 s. Waydroid has two runtimes: the system-wide
   container (owns the Android processes) and a per-user session
   daemon (clipboard, input, surface creation, `app launch` IPC).
   `waydroid app launch` silently no-ops if the session is not
   `RUNNING`, hence the poll.
3. On X11, spawns nested `weston` at 1600x900 and exports
   `WAYLAND_DISPLAY=wayland-1`. On Wayland, no-op.
4. `exec waydroid app launch com.roblox.client`. Override the package
   via `$RBX_PKG`.

Add the alias to `~/.zshrc`:

```sh
alias rbx='~/install_roblox/rbx'
```

(Or symlink `rbx` into `~/.local/bin/`; pick one.)

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
