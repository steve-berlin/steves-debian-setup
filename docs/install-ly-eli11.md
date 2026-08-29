# `install-ly.sh` explained (ELI11)

A plain-language guide to `installers/install-ly.sh` — it builds and installs
**Ly**, a login screen that is text instead of graphics.

## What a display manager is

The screen that asks for your username and password before the desktop appears
is a **display manager**, or DM. It runs before you log in, decides which
desktop to start, and hands over to it. SDDM (KDE's) and LightDM are the usual
graphical ones.

**Ly** does the same job in plain text, in the terminal. It starts in a
fraction of the time, uses almost no memory, and has famously little to go
wrong. You still choose your desktop from a list; it just looks like a terminal
rather than a wallpaper.

## Why this needs a build script

Ly is not in Debian's or MX's package lists. And it is written in **Zig**, a
fairly new language whose compiler changes quickly — so quickly that Ly 1.0.x
only builds with Zig 0.13, and today's Zig would refuse.

So the script pins both versions, exactly like `utils.sh` pins Go and neovim:

```
LY_VERSION=1.0.3      ZIG_VERSION=0.13.0
```

It downloads that Zig, downloads that Ly, builds, installs, and throws the
compiler away. You can override either with an environment variable, but the
defaults are the pair known to work — 1.0.3 is the last release on GitHub;
newer Ly moved to a different host and wants Zig 0.16.

## How to use it

```sh
bash installers/install-ly.sh                 # build + install, then ask about default
bash installers/install-ly.sh --dry-run       # print the plan, change nothing
bash installers/install-ly.sh --reinstall     # rebuild even if the same version is there
bash installers/install-ly.sh --uninstall     # remove it
bash installers/install-ly.sh --default       # switch to Ly without asking
bash installers/install-ly.sh --no-default    # install only, don't switch
```

It leaves a small file, `/usr/local/share/ly.version`, recording what it
installed. Running it again with that version already present does nothing —
which also protects `/etc/ly/config.ini` from being flattened by an accidental
re-run. `--reinstall` is the way to rebuild on purpose.

## What it does, in order

**1. Preflight.** Needs `git`, `curl`, `tar`, `sudo`, `systemctl`, and two
development packages — `libpam0g-dev` and `libxcb-xkb-dev` — because Ly is
compiled against the system's password-checking and keyboard libraries. It also
refuses architectures it has no Zig download name for (only x86_64 and aarch64
are mapped).

Under `--dry-run` all of those become warnings instead of stopping, since the
machine you would dry-run on is precisely the one without the build tools yet.

**2. Fetches the pinned Zig** into a temporary folder that is deleted when the
script exits, whatever happens.

**3. Clones Ly** at the pinned tag, with its two sub-projects (`zigini`,
`clap`).

**4. Builds twice, deliberately.** First as *you*, then again as *root*:

```sh
( cd ly && zig build )                      # as you
( cd ly && sudo zig build installsystemd )  # as root
```

The reason is ordering. Compile errors should appear before root touches
anything, and the installing step writes to absolute system paths, so it needs
root. A side effect: the root build leaves root-owned files in the temporary
folder, so the script hands ownership back afterwards or the cleanup at exit
could not delete them.

`installsystemd` does all the installing: `/usr/bin/ly`, the `/etc/ly/` config
folder, and the `ly.service` entry that lets systemd start it.

## The part that asks permission

After installing, it **offers** to make Ly your default login screen:

```
Make Ly the default display manager (disables sddm)? [y/N]
```

Only on "yes" does it turn off your current display manager, turn off the text
login on tty2 (Ly wants that console for itself), and enable Ly.

The default is **no**, and a non-interactive run (piped input, a script) also
gets "no" plus a warning. Silently swapping the thing that lets you log in is
not something to do by accident. `--default` and `--no-default` decide it up
front without a prompt.

Then reboot to use it.

## Uninstalling — read this before you do

```sh
bash installers/install-ly.sh --uninstall
```

removes Ly's files, disables its service, and puts the tty2 text login back.

**It does not re-enable your previous graphical login screen**, and it says so:

```
Ly removed. Enable a DM (e.g. 'sudo systemctl enable sddm') before reboot.
```

That is on purpose. Guessing which DM you had before and silently re-wiring it
is a great way to end up with a machine that boots to a black screen. Enable the
one you want yourself, *before* rebooting. If you forget, you can still log in
on a text console (Ctrl+Alt+F2) and fix it from there.

## A related bug that is not Ly's fault

If logins crash shortly after the laptop wakes from sleep, that is a systemd
issue, not Ly — see [`docs/fix-suspend-freeze-eli11.md`](fix-suspend-freeze-eli11.md).
An earlier attempt to fix it by rewriting Ly's PAM configuration was a
misdiagnosis and got reverted.

## Checking it afterwards

```sh
bash installers/check-ly.sh
```

That is a read-only health check covering every known Ly failure mode — see
[`docs/check-ly-eli11.md`](check-ly-eli11.md).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | installed, already installed, removed, or dry-run finished |
| 1 | preflight failure, or the download/build failed |
| 2 | unknown argument |
