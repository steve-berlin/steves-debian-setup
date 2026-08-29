# `debloat-nvidia.sh` explained (ELI11)

A plain-language guide to `debloat_scripts/debloat-nvidia.sh` — it removes
NVIDIA graphics drivers from a computer that has no NVIDIA graphics card.

## Why a computer would have drivers it can't use

Most Linux installers play it safe and install drivers for hardware you *might*
have. A laptop with only Intel graphics built into its processor still ends up
with the NVIDIA driver stack, and with **nouveau** — the open-source driver for
NVIDIA cards — sitting there.

That costs two things:

- About 500 MB of disk.
- A little time and contention at every boot, because nouveau loads and probes
  for a card that isn't there before giving up.

Neither is dramatic. Both are free to reclaim if the card genuinely isn't there.

## The safety check that comes first

```
error: NVIDIA GPU detected by lspci — refusing to purge drivers.
       This script is for Intel-iGPU-only boxes.
```

Before touching anything, it asks the hardware itself what graphics devices
exist — all three relevant kinds: the main display adapter, secondary 3D
controllers, and display controllers. If any of them is NVIDIA, it stops.

This is not politeness. Removing the driver on a machine that has the card
leaves you with software rendering — everything drawn slowly by the processor —
or a machine that doesn't finish booting. **There is deliberately no flag to
override this.** If you truly want that, use apt directly and know what you're
doing.

## How to use it

```sh
bash debloat_scripts/debloat-nvidia.sh --dry-run
bash debloat_scripts/debloat-nvidia.sh
bash debloat_scripts/debloat-nvidia.sh --uninstall
```

Reboot afterwards.

## What it does

**1. Purges the packages** — everything named `nvidia-*` or `libnvidia-*`, plus
`xserver-xorg-video-nouveau`. Same trick as the other debloat scripts: it first
turns those patterns into the list of packages actually installed, so a second
run finds nothing and says so instead of erroring.

**2. Blacklists nouveau.** Removing the package isn't quite enough — nouveau is
also built into the kernel's own driver collection. So it writes:

```
/etc/modprobe.d/blacklist-nouveau.conf
    blacklist nouveau
    options nouveau modeset=0
```

which tells Linux never to load it. Two lines because they block two different
routes: one stops the driver loading by name, the other stops it being pulled in
to set up the screen early in boot.

**3. Rebuilds the initramfs.** The initramfs is a miniature system the kernel
unpacks first, before your real disk is available — and it carries its *own*
copy of the driver rules. Skip this and nouveau still loads during early boot
from the stale copy. That is `update-initramfs -u`.

**Then reboot.** Nothing here unloads a driver from the running kernel; it takes
effect on the next boot.

## Undoing it

```sh
bash debloat_scripts/debloat-nvidia.sh --uninstall
```

removes the blacklist file and rebuilds the initramfs, so nouveau is allowed to
load again. It does **not** reinstall the driver packages — apt does that:

```sh
sudo apt install xserver-xorg-video-nouveau
```

Splitting it that way is intentional: undoing a configuration change is safe and
predictable, while reinstalling a driver stack is a decision you should make
explicitly.

## Checking it afterwards

`check-setup.sh` verifies exactly this: no `nvidia-*` packages, the blacklist
file present, no nvidia or nouveau module loaded, and — if `glxinfo` is
installed — that your graphics really are being drawn by the Intel chip.

If it reports a module still loaded right after you ran this, that is the
pending reboot, not a failure.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | purged, nothing to purge, reverted, or dry-run finished |
| 1 | an NVIDIA GPU is present, or a required tool is missing |
| 2 | unknown argument |
