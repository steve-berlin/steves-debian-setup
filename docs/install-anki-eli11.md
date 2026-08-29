# `install-anki.sh` explained (ELI11)

A plain-language guide to `installers/install-anki.sh` — the script that
installs Anki, the flashcard program, from the version its own authors ship.

## Why not just `apt install anki`

Debian has an `anki` package, and it is *years* behind. Anki's scheduler,
sync protocol and add-on system all move; running an ancient build means broken
add-ons and, eventually, a sync server that refuses to talk to you.

So this script goes to Anki's own releases instead.

## What an "anki-launcher" is

Since version 25.07, Anki's official Linux download is not the program. It is a
**launcher**: a small file that, the first time you run it, downloads the real
application and keeps it up to date afterwards.

This is why the download is tiny and why the *first* launch takes a while and
needs internet. Nothing is broken; that is the design.

## How to use it

```sh
bash installers/install-anki.sh              # install
bash installers/install-anki.sh --reinstall  # remove, then install fresh
bash installers/install-anki.sh --uninstall  # remove
bash installers/install-anki.sh --dry-run    # print the plan, change nothing
```

Then start it with `anki`.

## What it does, in order

**1. Checks its tools.** It needs `curl`, `tar`, `sudo` and `awk`. It also
checks that your `tar` understands **zstd**, because Anki's file is compressed
with it. Old `tar` versions can't read that — the fix it prints is
`sudo apt install zstd`.

**2. Asks GitHub what the latest release is.** It downloads the release list and
picks the first file whose name matches `anki-launcher-…-linux.tar.zst`. Walking
the list rather than only looking at "latest" matters: some releases don't carry
a Linux launcher, and the newest one that does is the one you want.

**3. Downloads and unpacks it** into a temporary folder that is deleted when the
script exits, however it exits.

**4. Runs Anki's own installer** from inside that folder, with `sudo`. That
installer writes to `/usr/local` — a system location, hence the password prompt.

## Where things end up

| Path | What's there | Safe to delete? |
|---|---|---|
| `/usr/local/bin/anki` | the command you type | no — that's the app |
| `/usr/local/share/anki/` | launcher files, plus `uninstall.sh` | no |
| `~/.local/share/Anki2/` | **your decks, cards and media** | **never** |
| `~/.cache/Anki2/` | the real app the launcher downloaded | yes — it re-downloads |

**Your collection is never touched.** Installing, reinstalling and uninstalling
all leave `~/.local/share/Anki2/` exactly where it is. `--uninstall` just runs
the `uninstall.sh` that Anki's own installer left behind.

## Two failures worth recognising

**"No matching launcher asset in recent releases."** Usually not a bug in the
script. GitHub allows about 60 anonymous requests per hour per IP address; over
that, it returns an error page instead of the release list and the search comes
up empty. Wait an hour and try again. (A shared VPN exit IP makes this more
likely, since you share the quota with everyone else on that IP.)

**"tar lacks zstd".** Your `tar` is too old to read the compression Anki uses.
`sudo apt install zstd`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | installed, uninstalled, or dry-run finished |
| 1 | a missing tool, no matching release, or a broken download |
| 2 | unknown argument |
