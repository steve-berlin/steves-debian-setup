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
NordVPN, tmux config, helper scripts, XFCE keybindings, debloat, and
EasyEffects presets. Numbered sections (1–15) match `check-setup.sh`'s
verification order.

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
  toggle: Debian stock (`linux-image-amd64`) builds it `=y`, Liquorix
  6.19 builds it off. The previous check looked at `/sys/module/binder_linux`
  and `lsmod`, but a not-compiled-in kernel exposes neither, and the
  fallback `modinfo` branch silently warned-and-continued — burning a
  500 MB image download before failing at `waydroid init`. The new
  three-way probe checks (a) `/sys/module/binder_linux`, (b)
  `binder` in `/proc/filesystems` (built-in signature), (c)
  `binder_linux.ko*` under `/lib/modules/$(uname -r)` (loadable
  module on disk). All three miss → exit with the actionable fix
  (`sudo apt install linux-image-amd64 && sudo reboot` is the easy
  path; DKMS or a kernel rebuild are the harder ones). No "override
  and continue" escape hatch — if you genuinely know better than
  the probe, edit the script.

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

## `setup_nordvpn.sh` — replace snap with official deb

Removes any snap-installed nordvpn, runs the official install.sh,
adds the user to the `nordvpn` group. Log out/in afterward for the
group change to take effect.
