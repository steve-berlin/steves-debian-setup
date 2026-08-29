# `setup_nordvpn.sh` explained (ELI11)

A plain-language guide to `installers/setup_nordvpn.sh` — the script that puts
the *right* copy of NordVPN on the machine.

## Why a script for this at all

There are two ways to get NordVPN on Linux and they are not equal.

**Snap** is a self-contained app format. It works, but the snap build of
NordVPN is sandboxed in ways that get in its own way — it can be slow to start,
and it has had long-running trouble reaching the system's network settings.

**The official `.deb`** comes from NordVPN's own apt repository. It is the build
their support actually tests. This script's whole job is: if the snap is here,
take it off; put the deb on; then make sure *you* are allowed to talk to it.

That last part is the bit people miss. The NordVPN background service runs as
root and only accepts commands from members of a group called `nordvpn`. If you
aren't in that group, every command answers with a permission error even though
the install worked perfectly.

## How to use it

```sh
bash installers/setup_nordvpn.sh              # install
bash installers/setup_nordvpn.sh --dry-run    # print the plan, change nothing
bash installers/setup_nordvpn.sh --uninstall  # remove it again
```

Anything else is an error and exits with code 2.

It is safe to run twice. If the deb is already installed it says so and skips
the installer; if you are already in the group it says so and skips `usermod`.

## What it does, in order

**1. Checks it has `curl` and `sudo`.** Missing either one, it stops
immediately rather than half-working.

**2. Removes the snap, if there is one.** Only if `snap` exists *and* actually
lists nordvpn. On most boxes this does nothing.

**3. Runs NordVPN's official installer** — but only if the deb isn't already
there. That guard is the interesting line. NordVPN's installer is *not*
idempotent: run it twice and it adds its apt source entry a second time, which
leaves apt complaining about a duplicate repository on every future update. So
the script checks `dpkg -s nordvpn` first and skips the whole thing.

**4. Adds you to the `nordvpn` group** — and checks three things in order: does
the group exist at all (if not, the installer failed and it warns you), are you
already in it (then nothing to do), otherwise `usermod -aG`.

## The one thing that trips everyone up

**Group membership does not apply to a shell that is already open.** Linux
attaches your groups when you log in, and never revisits it. So after this
script finishes:

```
Log out/in (for group change), then: nordvpn login && nordvpn connect
```

Log out and back in — not just close the terminal. Until you do, `nordvpn
status` will keep refusing you, and it looks exactly like a broken install.

## What it does not do

- **It does not log you in.** `nordvpn login` opens a browser and needs your
  account. No credentials are stored by this repo, ever.
- **It does not connect you, or configure anything.** Kill switch, protocol,
  autoconnect — all of that lives in `nord-rand setup` (see
  [`docs/nord-rand-eli11.md`](nord-rand-eli11.md)).
- **`--uninstall` purges the package and autoremoves its leftovers**, but does
  not remove you from the group or delete NordVPN's config folder.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | installed, already installed, uninstalled, or dry-run finished |
| 1 | a required tool (`curl`, `sudo`) is missing |
| 2 | unknown argument |
