# `fix-mount.sh` explained (ELI11)

A plain-language guide to `installers/fix-mount.sh` — what the mount error
means, what the script does about it, and what it refuses to do.

## The error

```
mount: /dev/sdb: mount point not mounted or bad option.
       dmesg(1) may have more information after failed mount system call.
```

That sentence is confusing because it is a *catch-all*. The `mount` command
needs three things to work:

1. **a device** — the actual hardware, like the USB stick you plugged in
2. **a filesystem** — the way files are organised on that device
3. **a mountpoint** — an empty folder to attach it to, like `/mnt/usb`

If it cannot line all three up, it gives you the message above no matter which
one was missing. The script's whole job is to figure out *which* one.

## Four words you need

**Disk** — the physical thing. Linux calls it `/dev/sdb`.

**Partition** — a disk is usually cut into slices, like a cake. The slices are
`/dev/sdb1`, `/dev/sdb2`, and so on. **Files live in the slices, not in the
whole cake.** The disk itself only holds a tiny map saying where the slices
start and end. This is the single most common cause of the error: you typed
`/dev/sdb` when the files are on `/dev/sdb1`.

**Filesystem** — the filing system inside a slice. Common ones: `ext4` (Linux),
`vfat` (old USB sticks and camera cards), `exfat` (big modern USB sticks),
`ntfs` (Windows drives).

**Mountpoint** — Linux has no drive letters. Instead you attach a filesystem to
an empty folder, and from then on that folder *is* the drive. `/mnt/usb` is a
normal choice. The folder has to exist first — mount will not create it.

**Driver** — the piece of Linux that knows how to read one particular
filesystem. If the driver is missing, the disk is fine and unreadable at the
same time.

## How to use it

```sh
installers/fix-mount.sh /dev/sdb /mnt/usb     # disk + where you want it
installers/fix-mount.sh /mnt/usb              # if /etc/fstab already knows it
installers/fix-mount.sh LABEL=backup /mnt/bkp # by the name written on the disk
```

Options:

| Flag | What it does |
|---|---|
| `--dry-run` | print the plan, change absolutely nothing |
| `-y`, `--yes` | do not ask before each fix (still asks before `ntfsfix`) |
| `-o OPTS` | your own mount options, passed straight to `mount` |
| `-h`, `--help` | usage |

Start with `--dry-run` if you are unsure. It is always safe.

## What it does, in order

**1. Works out what you meant.** You can hand it a device (`/dev/sdb`), a
folder (`/mnt/usb`), or a label or UUID — the disk's name or its long unique
serial number. It turns any of those into a real device.

**2. Checks whether it is already mounted.** If it is, it tells you where and
stops. Nothing to fix.

**3. Diagnoses.** This part only *reads*; it changes nothing. It checks:

- Did you point at the whole disk instead of a partition? If so, it finds the
  partition that actually has a filesystem. If there are several, it lists them
  and lets you choose.
- What filesystem is on there? If there is none, the disk is blank or damaged.
- Is the driver for that filesystem loaded, merely available, or missing
  entirely? It knows which Debian package supplies which driver.
- Does the mountpoint folder exist? Is it a folder at all? Is it empty?
- Is the device already being used somewhere else?
- Is `/etc/fstab` (the list of drives Linux mounts automatically) involved?

Then it prints a numbered list: each cause, and the exact command that fixes it.

**4. Fixes.** It asks before every single change:

```
  create mountpoint /mnt/usb? [y/N]
  run: sudo mount -o uid=1000,gid=1000 /dev/sdb1 /mnt/usb [y/N]
```

It can create the mountpoint folder, load a driver (`modprobe`), install a
driver package (`apt-get install`), and run the corrected mount command.

**5. If the mount still fails**, it reads the error and reacts: shows you the
matching lines from the kernel log, offers to retry read-only, or — for a
Windows disk that was hibernated instead of shut down — offers `ntfsfix`.

## Two details worth knowing

**Why `uid=` gets added by itself.** `vfat`, `exfat` and `ntfs` come from the
Windows world and store no idea of who owns a file. Mounted plainly, everything
belongs to root and you cannot write to your own USB stick. The script adds
`uid=` and `gid=` so the files belong to you. If you supply your own `-o`, it
assumes you know what you want and adds nothing.

**Why `ntfsfix` always asks.** Every other fix either creates a folder or
installs software — nothing on your data. `ntfsfix` *writes to the filesystem*
to clear the "dirty" flag Windows left behind. So it asks every time, even with
`--yes`, and refuses entirely if nothing can answer. The safer route is
mounting read-only, or booting Windows and shutting down properly (Windows
"fast startup" is hibernation wearing a hat, and it leaves the disk locked).

## What it will never do

- **format** anything, or create a filesystem
- **partition** or repartition a disk
- **edit `/etc/fstab`**
- run `fsck` on its own (it may suggest it — running it is your call)
- unlock an encrypted disk, activate LVM, or assemble a RAID array

For those last three it stops, says exactly what it found, prints the command
you would run, and exits with an error. It never guesses past something it
cannot safely handle.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | mounted, already mounted, or dry-run finished |
| 1 | could not fix it — the reason is printed above |
| 2 | you gave it bad arguments |

## When it cannot help

If the diagnosis says **"no filesystem signature found"**, the disk is either
brand new, wiped, or genuinely broken. No mount option rescues that. Check the
hardware first (`lsblk`, `sudo dmesg | tail`), and remember that formatting
destroys everything on the disk — if the data matters, stop and copy the raw
disk somewhere else before touching it.
