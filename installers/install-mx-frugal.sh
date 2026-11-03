#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-mx-frugal.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-mx-frugal.sh — boot an MX/antiX ISO from an internal partition so you
# can install Linux with no USB stick, no DVD, no external media at all.
#
# THE PROBLEM
# Installing an OS normally means booting from something *other* than the
# disk you install onto: a USB stick or a DVD. You cannot reinstall a system
# while running it, because the installer would rewrite the disk underneath
# itself. With dead USB ports and no DVD drive, you look stuck.
#
# THE TRICK
# You need something to boot that is not the system being replaced. A folder
# on a partition you are *not* touching works fine. This is called a "frugal"
# boot, and here it is used purely as the install medium:
#   1. loop-mount the ISO (open the .iso file as if it were a disk) and copy
#      its /antiX folder onto an existing filesystem. That folder holds the
#      three files that boot a live session:
#        vmlinuz    the kernel
#        initrd.gz  the startup bundle
#        linuxfs    the compressed system
#      Nothing is formatted or repartitioned.
#   2. drop a /etc/grub.d/ snippet: a new boot-menu entry pointing at those
#      files;
#   3. run update-grub so the menu picks it up.
# Reboot, pick the entry, and you get a normal MX live session running off the
# disk, with the installer there just as if you had booted a USB stick.
#
# WORKFLOW
#   1. Run the script.
#   2. Reboot and pick "MX live (frugal, install medium) — <name>".
#   3. In the live session run MX's installer onto a DIFFERENT partition than
#      the one holding the payload. This is the step that can go wrong: if
#      you install onto the payload's partition, the installer wipes the files
#      it is running from, mid-install. The script names that partition when
#      it finishes.
#   4. Back on the fresh system, run `--uninstall` to drop the entry + files.
#
# No persistence is configured on purpose: this is a throwaway install medium,
# not a frugal *system* you live in. Live session changes live in the RAM
# overlay and are gone at reboot — exactly like booting the USB stick this
# replaces.
#
# HOW TO RUN IT
#   bash installers/install-mx-frugal.sh MX-25.iso --dry-run
#   bash installers/install-mx-frugal.sh MX-25.iso
#   bash installers/install-mx-frugal.sh MX-25.iso --sha256 checksums.txt
#   bash installers/install-mx-frugal.sh --uninstall --name MX-25
#
#   --target DIR       where to copy the payload (default /frugal)
#   --name NAME        name for the folder and menu entry (default: from the
#                      ISO filename)
#   --sha256 SUM|FILE  check the ISO is not corrupted before trusting it
#   --reinstall        wipe the copied payload and copy it again
#   --uninstall        remove the menu entry and the payload
#   --dry-run          print the plan, change nothing
#
# NEVER BOOT-TESTED. Verified: bash -n, --help, dry install/uninstall, and the
# bdir path calculation. The menu entry follows antiX's docs but has never
# been booted on real hardware. On first real use, keep a working boot entry
# in the menu: if the frugal one fails, pick your normal system and nothing
# is lost.
#
# EXIT CODES
#   0   installed, already installed, removed, nothing to remove, or dry-run
#       finished
#   1   missing tool, bad ISO, checksum mismatch, unusable target, no space
#       (under --dry-run, missing tools and target problems only warn)
#   2   bad arguments: no ISO, two ISOs, unknown flag, or --uninstall with
#       neither --name nor an ISO to take the name from
set -euo pipefail

# Default payload folder (--target overrides it).
TARGET_DEFAULT=/frugal
GRUB_PREFIX=42-mx-frugal      # /etc/grub.d/<GRUB_PREFIX>-<name>

# Settings filled in by the argument parser below.
#   dry       1 = --dry-run: print actions, change nothing
#   mode      install | reinstall | uninstall
#   iso       path to the ISO file (the one positional argument)
#   target    payload folder; the files go to <target>/<name>/antiX
#   name      folder + menu entry name; empty = taken from the ISO filename
#   want_sha  --sha256 value: a checksum, or a file holding one
dry=0; mode=install; iso=""; target=$TARGET_DEFAULT; name=""; want_sha=""
usage() {
  cat <<EOF
Usage:
  $0 <MX-or-antiX.iso> [--target DIR] [--name NAME] [--sha256 SUM|FILE] [--reinstall] [--dry-run]
  $0 --uninstall [--target DIR] [--name NAME] [--dry-run]

  --target DIR   where the ISO payload is copied (default: $TARGET_DEFAULT).
                 Must be on an existing, mounted, plain partition.
  --name NAME    entry/subdir name (default: derived from the ISO filename).
  --sha256       expected checksum, literal or a file holding one.
EOF
}

# Flags can come in any order. Flags with a value take the next word, and
# ${2:?…} stops the script if that word is missing. Anything not starting
# with "-" is the ISO; a second one is an error (exit 2).
while [[ $# -gt 0 ]]; do
  case $1 in
    --uninstall) mode=uninstall ;;
    --reinstall) mode=reinstall ;;
    --dry-run)   dry=1 ;;
    --target)    target=${2:?--target needs a path}; shift ;;
    --name)      name=${2:?--name needs a value}; shift ;;
    --sha256)    want_sha=${2:?--sha256 needs a value}; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "error: unknown arg: $1" >&2; exit 2 ;;
    *)           [[ -z $iso ]] || { echo "error: multiple ISOs given" >&2; exit 2; }; iso=$1 ;;
  esac
  shift
done

# run <command…>: run it, or under --dry-run only print "DRY  <command>".
run() { if (( dry )); then printf 'DRY  %s\n' "$*"; else "$@"; fi; }

# run-parts (update-grub) skips filenames with dots or odd characters.
# So every character outside A-Z a-z 0-9 _ - becomes "_".
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

# miss "<message>": report a problem. Normally prints "error:" and exits 1.
# Under --dry-run it only prints "warning:" (see install-ly.sh): you may well
# be planning this on a box that isn't the one being reworked. Note this
# covers every miss() call, including the target checks in probe_target.
miss() { (( dry )) && echo "warning: $1" >&2 || { echo "error: $1" >&2; exit 1; }; }

# Check the tools this script needs. The box must boot via GRUB: either
# update-grub (Debian's wrapper) or grub-mkconfig must exist, plus the
# /etc/grub.d folder the new entry goes into.
preflight() {
  for c in findmnt lsblk cp du df sudo; do
    command -v "$c" >/dev/null || miss "missing: $c"
  done
  command -v update-grub >/dev/null || command -v grub-mkconfig >/dev/null \
    || miss "missing: update-grub / grub-mkconfig — this box does not boot via GRUB"
  [[ -d /etc/grub.d ]] || miss "missing: /etc/grub.d"
}

# Rebuild /boot/grub/grub.cfg from /etc/grub.d. Prefer update-grub; fall back
# to calling grub-mkconfig directly.
grub_update() {
  if command -v update-grub >/dev/null; then run sudo update-grub
  else run sudo grub-mkconfig -o /boot/grub/grub.cfg; fi
}

# Resolve <dir> to (mountpoint, fs UUID, fstype, source device), and hard-fail on
# anything GRUB + the live-init can't reach by plain UUID.
# Sets the globals mp, uuid, fstype (used later by do_install).
# The checks, and why: both the boot menu and the live startup must read the
# files very early in boot, before anything clever is available. So:
#   - the partition must have a filesystem UUID (GRUB finds it by that);
#   - the filesystem must be ext2/3/4, xfs or vfat (FAT);
#   - it must not be encrypted (crypt) or on LVM: nothing can open those
#     at that point in boot.
probe_target() {
  # Separate statements: bash expands every word of a `local a=… b=$a` line
  # before assigning, so `probe=$dir` on the same line reads an unset $dir.
  local dir=$1
  local probe=$dir
  # --target may not exist yet (it is created at copy time). Walk up to the
  # nearest existing parent folder and ask about that one instead.
  while [[ ! -e $probe && $probe != / ]]; do probe=$(dirname "$probe"); done
  mp=$(findmnt -no TARGET --target "$probe" || true)
  uuid=$(findmnt -no UUID --target "$probe" || true)
  fstype=$(findmnt -no FSTYPE --target "$probe" || true)
  local dev; dev=$(findmnt -no SOURCE --target "$probe" || true)
  [[ -n ${mp:-} ]] || miss "cannot resolve a mountpoint for $dir"
  [[ -n ${uuid:-} ]] || miss "no filesystem UUID for $dir (device: ${dev:-?}) — GRUB needs one"
  case $fstype in
    ext2|ext3|ext4|xfs|vfat) ;;
    *) miss "filesystem $fstype on $mp is not a plain partition layout the live-init handles — use ext4" ;;
  esac
  local devtype; devtype=$(lsblk -no TYPE "$dev" 2>/dev/null | head -n1 || true)
  case $devtype in
    crypt|lvm) miss "$dev is $devtype — the live-init can't open it at boot; pick a plain partition" ;;
  esac
}

# bdir is relative to the *partition root*, not to /.
# rel_bdir <absolute path> <its mountpoint>: cut the mountpoint off the front.
# Example: payload /frugal/MX/antiX, and /frugal is its own partition. As far
# as that partition knows, the files sit at /MX/antiX. Getting this wrong is
# the classic way to land at a rescue prompt. If the mountpoint is / there is
# nothing to cut. The result always starts with "/".
rel_bdir() {
  local abs=$1 mount=$2 rel=${1#"$2"}
  [[ $mount == / ]] && rel=$abs
  [[ $rel == /* ]] || rel="/$rel"
  printf '%s' "$rel"
}

# Check the ISO against --sha256, so a corrupt download is caught before it is
# trusted. No --sha256 = skip. If the value is a file, the checksum is the
# first word of its FIRST line only — a multi-line checksums file works only
# when this ISO's line comes first. Mismatch = exit 1.
verify_sha() {
  [[ -n $want_sha ]] || return 0
  command -v sha256sum >/dev/null || { miss "missing: sha256sum"; return 0; }
  local want=$want_sha
  if [[ -f $want_sha ]]; then want=$(awk 'NR==1{print $1}' "$want_sha"); fi
  echo "verifying sha256 of $(basename "$iso") …"
  local got; got=$(sha256sum "$iso" | awk '{print $1}')
  [[ $got == "$want" ]] || { echo "error: checksum mismatch: got $got, expected $want" >&2; exit 1; }
  echo "checksum OK"
}

# tmp = the temp folder the ISO is mounted on. cleanup() unmounts and removes
# it. It runs on every exit (the EXIT trap), so a failure mid-copy does not
# leave the ISO mounted.
tmp=""   # script scope, not local: the EXIT trap fires after the function returns
cleanup() {
  [[ -n ${tmp:-} ]] || return 0
  mountpoint -q "$tmp" 2>/dev/null && sudo umount "$tmp" || true
  rmdir "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

do_install() {
  preflight
  [[ -n $iso ]] || { usage >&2; exit 2; }
  [[ -f $iso ]] || { echo "error: no such ISO: $iso" >&2; exit 1; }
  iso=$(readlink -f "$iso")
  [[ -n $name ]] || name=$(basename "$iso" .iso)
  name=$(sanitize "$name")
  verify_sha

  # dest = where the payload goes; grub_file = the new menu snippet.
  # Both already there and no --reinstall: nothing to do, exit 0.
  local dest="$target/$name/antiX" grub_file="/etc/grub.d/$GRUB_PREFIX-$name"
  if [[ -d $dest && -f $grub_file && $mode != reinstall ]]; then
    echo "already installed: $dest + $grub_file (use --reinstall to refresh)"
    return 0
  fi

  probe_target "$target"
  local bdir; bdir=$(rel_bdir "$dest" "$mp")

  # Read the payload straight out of the ISO so a layout change fails loud here
  # rather than producing a GRUB entry that drops to a rescue prompt at boot.
  # It looks for the three expected files; a wrong or corrupt download stops
  # here. Then free space: payload size + 262144 KiB (256 MiB) of headroom.
  # --dry-run never mounts the ISO (no temp folder either), so it CANNOT do
  # these two checks. A dry run is a plan, not a full rehearsal.
  if (( dry )); then
    echo "DRY  sudo mount -o loop,ro $iso <tmpdir>   (skipping content + free-space checks)"
  else
    tmp=$(mktemp -d)
    sudo mount -o loop,ro "$iso" "$tmp"
    for f in antiX/vmlinuz antiX/initrd.gz antiX/linuxfs; do
      [[ -e $tmp/$f ]] || { echo "error: $iso has no /$f — not an MX/antiX live ISO" >&2; exit 1; }
    done
    local need avail
    need=$(du -sk "$tmp/antiX" | awk '{print $1}')
    avail=$(df -Pk "$mp" | awk 'NR==2{print $4}')
    (( avail > need + 262144 )) || {
      echo "error: need $((need/1024)) MiB + headroom on $mp, only $((avail/1024)) MiB free" >&2; exit 1; }
  fi

  # Copy. --reinstall first wipes <target>/<name> so the copy starts clean.
  # After the copy: sync (flush to disk), then unmount the ISO right away.
  echo "copying ISO payload to $dest (UUID $uuid, bdir $bdir) …"
  if [[ $mode == reinstall ]]; then run sudo rm -rf "$target/$name"; fi
  if (( dry )); then
    echo "DRY  sudo mkdir -p $dest"
    echo "DRY  sudo cp -a <iso>/antiX/. $dest/"
  else
    sudo mkdir -p "$dest"
    sudo cp -a "$tmp/antiX/." "$dest/"
    sudo sync
    cleanup; tmp=""
  fi

  # `exec tail -n +3 $0` is the stock /etc/grub.d/40_custom idiom: everything
  # below line 3 is emitted verbatim into grub.cfg.
  # The menu entry, line by line:
  #   search …        find the partition by its UUID and use it as GRUB's root
  #   linux …         load the kernel, with the live-init boot params:
  #     bdir=$bdir    the folder holding linuxfs/vmlinuz/initrd.gz, relative to
  #                   the partition root (see rel_bdir). Default is /antiX.
  #     buuid=$uuid   filesystem UUID of that partition. Names like /dev/sda3
  #                   can change between boots; the UUID does not.
  #     from=all      device types to search. The default is usb,cd, so
  #                   without this the live startup never looks at an internal
  #                   disk and the boot fails. The most important param here.
  #   initrd …        load the startup bundle
  # bdir= + buuid= is the same pair antiX's own frugal grub.entry generates
  # (antiX-FAQ "Live Boot Parameters"). `fromiso=` (boot the .iso file whole
  # via loopback) is deliberately NOT used: upstream marks it deprecated and
  # it disables live features.
  local snippet
  snippet=$(cat <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry "MX live (frugal, install medium) — $name" {
  search --no-floppy --set=root --fs-uuid $uuid
  linux $bdir/vmlinuz bdir=$bdir buuid=$uuid from=all quiet
  initrd $bdir/initrd.gz
}
EOF
)
  # Write the snippet as root and make it executable: update-grub only runs
  # executable files in /etc/grub.d.
  if (( dry )); then
    printf 'DRY  write %s:\n%s\n' "$grub_file" "$snippet"
  else
    printf '%s\n' "$snippet" | sudo tee "$grub_file" >/dev/null
    sudo chmod 0755 "$grub_file"
  fi
  grub_update

  # Secure Boot warning (only checked when mokutil is installed). It warns but
  # does not stop. It is not cosmetic: the entry boots an unsigned kernel, and
  # firmware with Secure Boot on simply refuses it.
  if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    echo "warning: Secure Boot is enabled — this entry boots an unsigned kernel and will be refused. Disable Secure Boot in firmware first." >&2
  fi

  cat <<EOF

Done. Next:
  1. reboot, pick "MX live (frugal, install medium) — $name" in GRUB
  2. in the live session run the MX installer, targeting a partition that is
     NOT $mp — installing over $mp wipes $target/$name mid-install
  3. back on a working system: $0 --uninstall --name $name --target $target
EOF
}

# --uninstall: remove the menu snippet and <target>/<name>, remove <target>
# itself if it is now empty, then rebuild the GRUB menu. The name comes from
# --name, or else from the ISO filename if one was given. Pass the same
# --target used at install time if it was not the default.
do_uninstall() {
  preflight
  if [[ -z $name && -n $iso ]]; then name=$(basename "$iso" .iso); fi
  [[ -n $name ]] || { echo "error: --uninstall needs --name (see /etc/grub.d/$GRUB_PREFIX-*)" >&2; exit 2; }
  name=$(sanitize "$name")
  local dest="$target/$name" grub_file="/etc/grub.d/$GRUB_PREFIX-$name"
  [[ -e $dest || -e $grub_file ]] || { echo "nothing to remove for '$name'"; return 0; }
  run sudo rm -f "$grub_file"
  run sudo rm -rf "$dest"
  run sudo rmdir "$target" 2>/dev/null || true   # only if now empty
  grub_update
  echo "Removed frugal boot entry + payload for '$name'."
}

case $mode in
  uninstall)         do_uninstall ;;
  install|reinstall) do_install ;;
esac
