# `check-setup.sh` explained (ELI11)

A plain-language guide to `installers/check-setup.sh` — the script that grades
your machine after `utils.sh` has run.

## What it is for

`utils.sh` installs about a hundred things. Some of those installs are allowed
to fail quietly — a flatpak that Flathub is having a bad day about, a vendor
script that changed its URL. So "the script finished" and "the box is actually
set up" are two different questions.

`check-setup.sh` answers the second one. It walks the same numbered steps in the
same order and prints one line per thing it looked for:

```
[OK]   pkg  zsh
[OK]   dir  /home/fred/.oh-my-zsh
[FAIL] bin  yt not in PATH
```

At the end it totals them up:

```
Passed: 78  Failed: 2
```

Exit code 0 means everything passed. Exit code 1 means at least one thing did
not. That makes it usable in a script or a CI job, not just by eye.

## How to use it

```sh
bash installers/check-setup.sh
```

That's the whole interface. **No flags, no arguments, no `--dry-run`** — and it
doesn't need one, because it never changes anything. Every single check is a
question: does this package exist, does this folder exist, is this command on
`PATH`, is this setting set to this value. Nothing is installed, removed or
written. You can run it as often as you like, on any box, safely.

## Six kinds of check

The script is built out of six tiny helpers, and every line of output comes
from one of them. Knowing which is which makes the output easy to read:

| Helper | Question it asks | Output looks like |
|---|---|---|
| `cp_` | is this apt package installed? | `pkg zsh` |
| `np` | is this package *gone*? | `pkg foliate removed` |
| `cbin` | is this command on `PATH`? | `bin yt-dlp` |
| `cf` | does this file exist? | `file ~/.fzf.zsh` |
| `cd_` | does this folder exist? | `dir ~/.pyenv` |
| `xk` / `kk` | is this keyboard shortcut set to this exact value? | `xfce /commands/custom/<Super>k` |

`np` is the odd one out and worth a second look: it **passes when the package is
absent**. It is used for things `utils.sh` deliberately removes (`foliate`,
`atmel-firmware`) and for everything the debloat scripts strip. A `[FAIL]` from
`np` means "this is still here and shouldn't be".

## What it checks, step by step

The numbers match `utils.sh`, so a failure tells you which step to re-run.

**1.** All the apt packages from the big install line — zsh, git, curl, fzf,
tmux, mpv, alacritty, the zathura/mupdf reader stack, and the rest.

**1c.** `atmel-firmware`, with the same safety logic `utils.sh` uses: if an
at76c50x WiFi dongle is actually plugged in, the package is supposed to *stay*,
so the check inverts — present is `[OK]`, missing is `[FAIL]`. On any normal
laptop no such device exists, so it just checks the package is gone.

**1e.** `foliate` is gone.

**2–3.** oh-my-zsh, its two plugins, and fzf's shell integration file.

**4.** Each toolchain, checked by whatever file proves it landed: `~/.cargo/env`
for Rust, the `~/.rbenv` folder, `nvm.sh`, the `deno` and `bun` binaries,
`~/.pyenv`. `atuin` and `starship` are checked on `PATH` *or* at their known
install path, because a fresh install isn't on `PATH` until you reopen the shell.

**5.** The Go and neovim tarballs unpacked into `~/.local/go` and `~/.nvim`.

**6.** Brave and Waydroid.

**8.** The pip tools: `yt-dlp`, `tldr`, `platformio`, and `yt` — which is
yewtube's command name. Looking for a command called `yewtube` would fail
forever; there isn't one.

**9.** Each flatpak, asked for by its full app ID (`app.drey.EarTag` and so on)
with `flatpak info --user`. The `--user` matters: `utils.sh` installs them into
your account, and a system-wide query wouldn't see them.

**10.** Claude Code, NordVPN, and — separately — whether **you** are in the
`nordvpn` group. That last one is the check people trip over: the group is added
during install but does not apply until you log out and back in.

**11.** That `~/.tmux.conf` really says `set -g prefix C-a`.

**12.** Both helper scripts exist *and* are executable.

**13 / 13b.** The keyboard shortcuts — but only on the desktop they belong to.
It reads `XDG_CURRENT_DESKTOP` and checks the XFCE shortcuts only in an XFCE
session, the KDE ones only in a KDE session. On the wrong desktop it skips them
entirely rather than reporting a wall of false failures.

The KDE check compares by **prefix**, not exact match, on purpose: Plasma
rewrites a shortcut's stored value into three tab-separated fields (the active
key, the default key, the display name), so the script asserts only that the
first field starts with `Meta+K` and ignores whatever Plasma appended.

**14–15.** The debloat results: GIMP, VLC, the MX-bundled tools and every
`nvidia-*` package should be **gone**; the nouveau blacklist file should exist;
no nvidia or nouveau kernel module should be loaded; and if `glxinfo` is
available, the graphics renderer should be the Intel chip rather than an NVIDIA
one.

## The one confusing result

**On a box where you ran only `utils.sh`, steps 14 and 15 will fail — and that
is correct.** `utils.sh` does not debloat anything. Those checks belong to
`debloat_scripts/debloat-mx.sh` and `debloat-nvidia.sh`, which are opt-in. If
you never wanted them, treat those specific failures as "not applicable"; the
exit code will still be 1.

Two smaller ones:

- A **reboot pending** after removing the nvidia driver shows up as
  `nvidia/nouveau kernel module loaded`. The removal worked; the running kernel
  just hasn't caught up.
- `glxinfo` missing prints `[--]` and skips the renderer check instead of
  failing. Install `mesa-utils` if you want that check to run.

## Why it doesn't stop at the first failure

Most scripts in this repo start with `set -euo pipefail`, which makes them
abort the moment anything returns an error. This one uses only `set -u`.

That is deliberate. A failed *check* is not a failed *script* — it is the
result. If `set -e` were on, the first missing package would end the run and you
would never see the other seventy answers. Instead every check records its
verdict and the script keeps going, so one run gives you the complete picture.

The exit code comes from the very last line, `[ "$F" -eq 0 ]`: zero failures,
exit 0; otherwise exit 1.

## Two gaps worth knowing about

The script does not currently verify:

- **Step 8**, the neovim config seeded from `nvim-config/`. A stale comment in
  the file says step 8 is "commented out" in `utils.sh` — it isn't any more, so
  this is an untested step rather than a deliberate skip.
- **The caveman plugin** (`utils.sh` step 10b′) and the **EasyEffects presets**
  (step 15).

Nothing breaks because of this; the checks simply aren't there yet. If a run
comes back all-green, those three items are the ones it did not actually look at.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every check passed |
| 1 | at least one check failed — the count is on the last line |
