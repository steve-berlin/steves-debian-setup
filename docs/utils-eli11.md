# `utils.sh` explained (ELI11)

A plain-language guide to `installers/utils.sh` — the script that turns a
freshly installed MX/Debian box into *this* box.

## The problem it solves

`~/.zshrc` — the settings file your shell reads every time you open a terminal
— mentions a lot of programs by name. It sets up `fzf`, `starship`, `atuin`,
`nvm`, `pyenv` and a dozen others. If those programs are not installed, the
shell either complains on every launch or silently skips half of your setup.

`utils.sh` installs every one of them, plus the desktop apps and keyboard
shortcuts that make the machine feel like yours. It is **step 1** of the whole
repo: everything else assumes it already ran.

## Five words you need

**Package** — a program bundled up so the system can install and remove it
cleanly. **apt** is Debian's package installer; `apt-get install zsh` fetches
zsh from Debian's servers.

**Repository (repo)** — the server apt downloads from. Debian's default repos
don't carry everything (Steam needs an extra one), so some steps add repos.

**Tarball** — a `.tar.gz` file: a folder squashed into one file. Some projects
(Go, neovim) ship these instead of packages, so the script downloads and
unpacks them by hand into your home folder.

**Flatpak** — a second, newer way to install desktop apps. Each app carries its
own libraries, so it can be much newer than the Debian version. The script uses
`--user`, meaning the apps install into your account, not system-wide.

**Toolchain / version manager** — `nvm`, `pyenv`, `rbenv` don't *do* anything by
themselves. They let you install and switch between versions of Node, Python
and Ruby per project.

## How to use it

```sh
bash installers/utils.sh              # do it
bash installers/utils.sh --dry-run    # print the plan, change nothing
bash installers/utils.sh --help
```

| Flag | What it does |
|---|---|
| `--dry-run` | prints a `DRY` line for every action; touches nothing |
| `--uninstall-caveman` | removes the caveman Claude Code plugin, then exits immediately — nothing else runs |
| `-h`, `--help` | usage |

Any other argument is an error and exits with code 2. Note there is **no plain
`--uninstall`**: undoing a bulk bootstrap means guessing which of two hundred
packages you wanted before, and the script refuses to guess.

**It is safe to run twice.** Every step checks first — "is oh-my-zsh already
there? then skip". Running it on an already-set-up box does nothing. That is
the point: it is how you top up a machine after adding a new tool to the list.

## What it does, in order

The steps are numbered in the script itself, and `check-setup.sh` verifies them
in the same order, so the numbers are worth knowing.

**0. Offers to delete `installers/discontinued/`.** Only asks if you are sitting
at a real terminal. That folder no longer exists, so this never actually fires —
it is harmless leftover.

**1. The big apt install.** One long list: `zsh git curl tmux fzf`, compilers
(`build-essential`) and the libraries Ruby needs to build, media tools (`mpv`,
`playerctl`, `easyeffects`), desktop bits (`alacritty`, `copyq`, `flameshot`),
and the document readers (`zathura` for PDF and DjVu, `mupdf` for EPUB).

**1b. Steam.** Steam is 32-bit, so the script first tells apt that 32-bit
packages are allowed at all (`dpkg --add-architecture i386`), then installs it.
If Debian's non-free repo isn't enabled, it prints a warning instead of dying.

**1c. Removes `atmel-firmware` — carefully.** That package is firmware for USB
WiFi dongles from around 2004. On a modern Intel-WiFi laptop it is dead weight,
but deleting firmware a real device needs would kill your WiFi. So it checks
three ways whether such a device exists (is one plugged in? is the driver
loaded? does `lsusb` see one?) and **keeps the package if any check says yes.**

**1e. Removes `foliate`** (an ebook reader) because `mupdf` from step 1 already
covers EPUB, then cleans up the libraries foliate dragged in with it.

**2. oh-my-zsh** plus the two plugins that make zsh pleasant: syntax
highlighting and autosuggestions.

**3. fzf** — the fuzzy finder — gets its keyboard shortcuts wired into zsh.

**4. Toolchains**: rustup (Rust), atuin (searchable shell history), starship
(the prompt), nvm (Node), deno, bun and pyenv (Python) each come from their
project's own installer; rbenv (Ruby) is cloned straight from git instead,
because that is how rbenv ships.

**5–6. Go and neovim** as tarballs, unpacked to `~/.local/go` and `~/.nvim`.
It asks go.dev what the current version is rather than hard-coding a number.

**7. Brave browser and Waydroid** (which runs Android apps on Linux).

**8. Neovim config.** Copies the `nvim-config/` folder from this repo over
`~/.config/nvim/`. See the warning below — this one overwrites.

**9. Python tools** via pip: `yt-dlp`, `tldr`, `platformio`, and separately
`yewtube` (a terminal YouTube client). Its command is **`yt`**, not `yewtube`.

**10. Flatpak apps**: Organic Maps, Session, SimpleX Chat, EarTag, Telegram.

**10b. Claude Code**, then the **caveman** plugin for it, then **NordVPN**
(which also adds you to the `nordvpn` group — that only takes effect after you
log out and back in).

**11. tmux prefix.** Changes the tmux "attention key" from `Ctrl-b` to `Ctrl-a`,
backing up the old config first.

**12. Two small helper scripts** written into `~/.local/bin/`:
`clear-clipboard` (wipes the clipboard and CopyQ's history) and `focus-nth`
(jump to the Nth window on screen).

**13. Keyboard shortcuts**, for XFCE and KDE both, only if that desktop is
present: Super+K powers off, Super+L logs out, Super+C clears the clipboard,
Print takes a screenshot, Super+1…9 jump between windows.

**14.** Nothing — the debloat scripts moved to `debloat_scripts/`.

**15. EasyEffects presets** — ready-made equalizer profiles.

## Three things to know before you run it

**Step 8 overwrites your neovim config.** It deletes `~/.config/nvim/` and
copies the repo's version in. If you have hand-edited anything in there, commit
or copy it somewhere else first. Everything else in the script skips work that
is already done; this one step does not.

**It downloads and runs installer scripts from the internet.** That is how
rustup, starship, Brave, NordVPN and the rest are officially distributed, so
there is no way around it — but it means you are trusting those vendors. All of
them run as *you*, except Waydroid's repo setup, which needs root to add an apt
repository.

**Nothing here logs you in.** When it finishes it reminds you to run
`claude login` and `nordvpn login` yourself, and to log out and back in so the
`nordvpn` group membership applies.

## What it deliberately does *not* do

- **Does not remove `dash` or repoint `/bin/sh`.** An earlier version did, and
  it bricked the machine: `dash` owns `/bin/sh`, so removing it deletes
  `/bin/sh` halfway through — and then the removal script's own first line,
  `#!/bin/sh`, has nothing to run it. Everything on the system that starts with
  `#!/bin/sh` stops working at once. Do not put this back.
- **Does not install a default Node version.** `nvm` is installed; picking a
  version is yours. (The one exception: if caveman needs Node and finds none,
  it quietly installs the LTS release.)
- **Does not change your login shell.** Installing zsh and running `chsh` are
  separate decisions.
- **Does not debloat anything** beyond the two targeted removals in 1c and 1e.
- **Does not touch your tokens.** It warns that `~/.zshrc` has API tokens in it
  that should be rotated, and leaves them alone.

## When it finishes

Run the checker:

```sh
bash installers/check-setup.sh
```

It walks the same steps and prints `[OK]` or `[FAIL]` for each. Exit code 0
means the bootstrap is clean.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | finished (or `--dry-run`, or `--uninstall-caveman`, completed) |
| 2 | you passed an argument it doesn't know |
| other | a step failed hard — the script stops at the first real error rather than limping on |

Steps that are allowed to fail — a flatpak that isn't on Flathub today, an
optional kernel-tools package — end in `|| true` and only print a warning. A
failure that stops the script is one that would leave the box half-built.
