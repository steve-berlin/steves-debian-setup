# `install-mx-frugal.sh` explained (ELI11)

A plain-language guide to `installers/install-mx-frugal.sh` — it lets you
install Linux on a machine with **no USB stick and no DVD drive**.

## The problem

Installing an operating system normally means booting from something *other*
than the disk you're installing onto: a USB stick, a DVD. If your USB ports are
dead and there's no optical drive, you appear to be stuck — you can't reinstall
the system while running it, because the installer would be rewriting the disk
underneath itself.

## The trick

You don't actually need removable media. You need something to boot that isn't
the system being replaced. A folder on a partition you're *not* touching works
fine.

This script sets that up:

1. It opens the MX/antiX installation ISO file and copies the three files that
   boot a live session — `vmlinuz` (the kernel), `initrd.gz` (the startup
   bundle) and `linuxfs` (the compressed system) — onto an existing partition.
2. It adds an entry to the **boot menu** pointing at those files.
3. Reboot, pick that entry, and you're in a normal MX live session running from
   the internal disk, with the installer available exactly as if you'd booted a
   USB stick.

This arrangement is called a **frugal install**.

**Nothing is formatted and nothing is repartitioned.** It copies files onto a
filesystem that already exists.

## How to use it

```sh
bash installers/install-mx-frugal.sh MX-25.iso --dry-run
bash installers/install-mx-frugal.sh MX-25.iso
bash installers/install-mx-frugal.sh MX-25.iso --sha256 checksums.txt
bash installers/install-mx-frugal.sh --uninstall --name MX-25
```

| Flag | Meaning |
|---|---|
| `--target DIR` | where to copy the payload (default `/frugal`) |
| `--name NAME` | name for the folder and menu entry (default: from the ISO filename) |
| `--sha256 SUM\|FILE` | check the ISO isn't corrupted before trusting it |
| `--reinstall` | wipe the copied payload and copy it again |
| `--uninstall` | remove the menu entry and the payload |
| `--dry-run` | print the plan, change nothing |

The whole workflow:

1. Run the script.
2. Reboot and pick **"MX live (frugal, install medium) — <name>"**.
3. In the live session, run MX's installer, targeting **a different partition
   than the one holding the payload**.
4. Back on the fresh system, `--uninstall` to clean up.

> **Step 3 is the one that can go wrong.** If you install onto the same
> partition the payload lives on, the installer wipes the files it is currently
> running from, mid-install. The script prints which partition to avoid, by
> name, when it finishes.

## Nothing you do in the live session is saved

That is deliberate. This is a *throwaway install medium*, not a permanent second
system. Changes live in memory and vanish at reboot — exactly like the USB stick
it replaces. If you want a frugal install you can actually live in, that's a
different setup (persistence), and this script doesn't do it.

## The boot settings, and why they are those

The generated menu entry looks like this:

```
menuentry "MX live (frugal, install medium) — MX-25" {
  search --no-floppy --set=root --fs-uuid <UUID>
  linux /frugal/MX-25/antiX/vmlinuz bdir=/frugal/MX-25/antiX buuid=<UUID> from=all quiet
  initrd /frugal/MX-25/antiX/initrd.gz
}
```

Three details matter:

**`bdir=`** — where the system files are, written **relative to the top of that
partition**, not to `/`. If the payload is at `/frugal/MX` and `/frugal` is its
own separate partition, then as far as that partition is concerned the files are
just at `/MX`. Getting this wrong is the classic way to end up at a rescue
prompt. The script works it out for you.

**`buuid=`** — the unique ID of the partition holding the payload. Partition
names like `/dev/sda3` can change between boots; the UUID doesn't.

**`from=all`** — the live startup normally only looks for its files on USB
sticks and CDs. Without this it would ignore the internal disk entirely and the
boot would fail. This is the single most important parameter in the entry.

There is another approach — `fromiso=`, booting the `.iso` file whole — which
this script deliberately doesn't use: upstream marks it deprecated and it
disables live features.

## What it refuses to do

The target partition is checked before anything is copied, and the script stops
rather than proceeding if:

- **The filesystem is unusual.** Only ext2/3/4, XFS and FAT are accepted. Both
  the boot menu and the live startup have to read those files very early, before
  anything clever is available.
- **The partition is encrypted or on LVM.** Same reason — at that point in boot,
  nothing can open them.
- **There isn't enough room** — it needs the payload plus 256 MiB of headroom.
- **The ISO isn't what you think it is.** It looks inside for the three expected
  files before copying, so a wrong or corrupt download fails immediately instead
  of producing a boot entry that dies at a rescue prompt.

It also warns — but does not stop — if **Secure Boot** is on:

```
warning: Secure Boot is enabled — this entry boots an unsigned kernel and will
be refused. Disable Secure Boot in firmware first.
```

That is not cosmetic. With Secure Boot on, the firmware will simply refuse the
entry.

## About `--dry-run`

`--dry-run` never mounts the ISO, so it **cannot** check the ISO's contents or
the free space — those need the file actually open. It is a plan, not a full
rehearsal. It also downgrades missing tools to warnings rather than errors,
since you might well be planning this from a different machine.

## The one thing that has never been tested

Everything in this script has been verified except the part that matters most:
**the boot entry has never actually been booted.** Its syntax check, its help,
its dry runs and its path calculation are all verified; the entry itself is
correct according to antiX's documentation and unproven on real hardware.

So on your first real use: **keep a working boot entry available.** If the
frugal entry fails, pick your normal system from the same menu and nothing is
lost.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | installed, already installed, removed, or dry-run finished |
| 1 | missing tool, bad ISO, checksum mismatch, unusable target, no space |
| 2 | bad arguments (no ISO, two ISOs, `--uninstall` without `--name`) |
