# steves_debian_setup

Personal setup repo for a fresh MX Linux XFCE install on a ThinkPad T480
(Intel UHD 620, x86_64, Liquorix kernel, X11). The scripts here turn a
clean MX install into the working environment, plus install/launch a
handful of games and apps that don't have first-class Linux delivery.

## Layout

```
installers/    install-*.sh, utils.sh, check-setup.sh   (one-shot setup)
launchers/     stm, rbx, rbxvm, nic-boost               (per-run wrappers)
lineage_vm/    CLAUDE.md                                 (Roblox-VM deployed-state docs)
nord-job/      nord-rand + nord-rand.cron               (6-hourly NordVPN rotation)
autostarts/    *.desktop                                 (XFCE autostart)
backup.zshrc   reference copy of ~/.zshrc               (do not source)
```

Each subfolder has its own `CLAUDE.md` with the per-script details.
Read those when working inside that subfolder; this file is just the map.

## Install order on a fresh box

1. `installers/utils.sh` — bulk apt + toolchains + oh-my-zsh + debloat.
   This is the one big bootstrap; everything else assumes it ran.
2. `installers/check-setup.sh` — verifies step 1. Exit 0 means clean.
3. `installers/setup_nordvpn.sh` — only if you want NordVPN; replaces
   the snap version with the official deb repo.
4. Game/app installers as needed:
   `install-steam.sh`, `install-tld.sh`, `install-anki.sh`,
   `install-roblox.sh` (run `check-roblox-prereqs.sh` first),
   `install-lineage.sh` (Roblox-on-Android-x86 VM alternative),
   `install-lxqt.sh` (alternative DE: LXQt + bilingual keyboard +
   Albert), `debloat-mx.sh` (strip MX-bundled apps + optional
   `--intel-only` for nvidia/nouveau purge), `debloat-kde.sh`
   (post-install KDE Plasma debloat — only runs if `plasma-desktop`
   is installed). Each is independent.
5. Networking polish: `install-nic-tuning.sh` drops sysctl + NM
   dispatcher tweaks (zero power cost) and deploys `nic-boost`
   to `~/.local/bin/` for opt-in WiFi/EEE temporary boosts.
6. Optional tmux persistence: `install-tmux-immortal.sh` adds tpm
   + tmux-resurrect + tmux-continuum so sessions survive reboots.
7. Optional NordVPN country rotation: `install -m 755 nord-job/nord-rand
   ~/.local/bin/` then `crontab nord-job/nord-rand.cron`. See
   `nord-job/CLAUDE.md` for modes and the autoconnect/skip interaction.
8. `launchers/stm`, `launchers/rbx`, and `launchers/rbxvm` go to
   `~/.local/bin/`. The `skl` Minecraft launcher lives as a zsh alias,
   not a script — see `backup.zshrc` for the exact line.
9. `autostarts/*.desktop` go to `~/.config/autostart/`.

## Conventions every installer follows

- `set -euo pipefail` at the top, no exceptions.
- `--dry-run` prints actions, mutates nothing. Combinable with other modes.
- Idempotent: re-running on an already-installed box is a no-op, not an error.
- No credentials, no scraping behind logins, no `curl | sudo bash` of
  unaudited third parties (waydroid_script is the one exception, vendored
  under `~/install_roblox/waydroid_script/`).
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
  cloned/created by `install-roblox.sh` at runtime.
