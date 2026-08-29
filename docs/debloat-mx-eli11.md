# `debloat-mx.sh` explained (ELI11)

A plain-language guide to `debloat_scripts/debloat-mx.sh` — it removes the
software MX Linux ships that you probably don't want.

## What "debloat" means here

MX Linux comes with a lot pre-installed: its own settings tools, a welcome
tour, an office suite, a photo editor, CD burning software. All fine, all
optional, and all taking disk space and menu entries.

This script removes a specific, hand-picked list. It is not a "remove everything
that looks unused" heuristic — every entry was chosen, and grouped with a
comment saying why.

## How to use it

```sh
bash debloat_scripts/debloat-mx.sh --dry-run   # see the list first — do this
bash debloat_scripts/debloat-mx.sh             # actually remove
```

> Read the dry run before the real run. This uninstalls software. Everything is
> recoverable with `sudo apt install <name>`, but it is faster to notice
> beforehand that you did want GIMP after all.

There is **no `--uninstall`** — the reverse of removing a package is installing
it, and apt already does that.

## Why it refuses to run on plain Debian

```
error: not MX Linux (no /etc/mx-version)
```

The list is full of `mx-*` package names that only exist on MX. Running it
elsewhere would do nothing useful, and the check is a cheap way to catch "wrong
machine". `/etc/mx-version` is the marker MX itself uses, and it survives
switching desktop environments.

## What gets removed

Nine groups, in the script's own order:

1. **Welcome and tour** — the one-time introduction screens.
2. **MX miscellany** — its updater, its graphical package installer, `mx-viewer`
   (a minimal browser), a Flash installer for a plugin that no longer exists,
   and a one-shot codec installer.
3. **Settings tools that duplicate the desktop's own** — MX's keyboard, locale,
   date/time, user and menu editors. Your desktop's Settings app already covers
   all of them.
4. **Niche network helpers** — rsync frontend, Samba config, share finder,
   network assistant, service manager.
5. **Theme and sound packs** — artwork, the Faenza icon set, sound selectors.
6. **`mx-comp-mgr`** — MX's compositing manager, which does nothing once you're
   on KDE, since KWin handles that itself.
7. **Bundled heavyweights** — GIMP, Strawberry, gmtp, deb-installer, qpdfview,
   Catfish, LibreOffice helper.
8. **CD/DVD burning and ripping** — xfburn, asunder, brasero, k3b, xcdroast and
   friends. Dead technology on a laptop with no optical drive.
9. **Wildcards** — all of LibreOffice, all of VLC, all of GIMP.

### What it deliberately keeps

MX's genuinely good tools stay: `mx-tools`, `mx-snapshot`, `mx-cleanup`,
`mx-tweak`, `mx-repo-manager`, `mx-iso-dump`, `mx-software-defaults`,
`mx-default-settings`, `mx-keyring`.

### Four you can opt into

Commented out at the bottom of the list, because they're a matter of taste:
`mx-conky` (system monitor overlay), `mxlive-usb-maker`, `mx-remastercc` (only
useful when building your own ISO), `mx-installer` (only useful for reinstalling
the OS). Uncomment any you want gone.

## How it avoids errors on a second run

The list contains patterns like `libreoffice-*`, not just names. Handing those
straight to apt on a machine where they aren't installed produces errors.

So the script first *expands* every name and pattern into "packages that are
actually installed right now", then removes that list in one go. On an
already-debloated machine the list comes out empty and it prints:

```
── nothing to remove (already debloated) ──
```

That is why re-running is safe and quick.

## Afterwards

It finishes with `apt autoremove --purge`, which clears out libraries that
nothing needs any more — often a bigger space saving than the packages
themselves.

To bring something back:

```sh
sudo apt install gimp
```

For the graphics-driver cleanup, that's a separate script:
[`docs/debloat-nvidia-eli11.md`](debloat-nvidia-eli11.md).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | removed, nothing to remove, or dry-run finished |
| 1 | not MX Linux, or a required tool is missing |
| 2 | unknown argument |
