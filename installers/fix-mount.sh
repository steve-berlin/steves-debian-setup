#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh fix-mount.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# fix-mount.sh — diagnose and repair a failing mount.
#
# THE ERROR THIS EXISTS FOR
#
#   mount: /dev/sdb: mount point not mounted or bad option.
#          dmesg(1) may have more information after failed mount system call.
#
# That message is a catch-all from util-linux (the package that ships mount).
# mount needs three things to line up:
#   1. a device      — the real hardware, like the USB stick you plugged in
#   2. a filesystem  — the way files are organised on that device
#   3. a mountpoint  — an empty folder to attach it to, like /mnt/usb
# If any one is missing, you get the same message. This script finds out which.
# In practice the cause is one of:
#
#   1. One-argument `mount /dev/sdb` with no matching /etc/fstab entry. mount
#      has nowhere to put it and refuses to guess.
#   2. /dev/sdb is the whole disk. The filesystem lives on a partition
#      (/dev/sdb1); the disk itself holds only a partition table.
#   3. `mount -o remount …` aimed at something that is not currently mounted.
#   4. The mountpoint folder does not exist, or the filesystem driver (exfat,
#      ntfs3, f2fs…) is not loaded or not installed, so no mount can succeed.
#
# WORDS YOU NEED FIRST
#   Disk        the physical thing. Linux calls it /dev/sdb.
#   Partition   a slice of the disk: /dev/sdb1, /dev/sdb2, … Files live in the
#               slices, not in the whole disk. The disk itself only holds a
#               tiny map of where the slices start and end. Typing /dev/sdb
#               when the files are on /dev/sdb1 is the most common cause.
#   Filesystem  the filing system inside a slice. Common ones: ext4 (Linux),
#               vfat (old USB sticks, camera cards), exfat (big modern USB
#               sticks), ntfs (Windows drives).
#   Mountpoint  Linux has no drive letters. You attach a filesystem to an
#               empty folder, and from then on that folder *is* the drive.
#               The folder must exist first — mount will not create it.
#   Driver      the part of Linux that reads one kind of filesystem. With no
#               driver, the disk is fine and unreadable at the same time.
#
# HOW TO RUN IT
#   fix-mount.sh /dev/sdb /mnt/usb       disk + where you want it
#   fix-mount.sh /mnt/usb                if /etc/fstab already knows it
#   fix-mount.sh LABEL=backup /mnt/bkp   by the name written on the disk
#
#   --dry-run       print the plan, change absolutely nothing. Always safe.
#   -y, --yes       do not ask before each fix (still asks before ntfsfix)
#   -o OPTS         your own mount options, passed straight to mount -o
#   -h, --help      usage
#
# WHAT IT WILL NEVER DO
#   format anything or create a filesystem; partition or repartition a disk;
#   edit /etc/fstab; run fsck; unlock an encrypted disk, activate LVM, or
#   assemble a RAID array. For those it stops, says what it found, prints the
#   command you would run, and exits 1. It never guesses past them.
#
# EXIT CODES
#   0   mounted, already mounted, or dry-run finished with nothing blocking
#   1   could not fix it — the reason is printed above. Also: an unknown
#       option, too many arguments, or -o with no value.
#   2   no <target> given (usage is printed)
set -euo pipefail

# blkid, findfs, modprobe and fsck live in /usr/sbin (and /sbin). A plain user
# shell on Debian/MX does not have those on PATH. Without them every probe
# below would silently come back empty, and the diagnosis would be wrong, not
# missing. So put them first on PATH every time. Duplicates are harmless.
PATH=/usr/sbin:/sbin:$PATH

# Settings filled in by the argument parser below.
#   dry         1 = --dry-run: print actions, change nothing.
#   assume_yes  1 = --yes: answer "yes" to every routine prompt.
#   opts        the -o value, passed through to mount -o. Empty = none given.
#   target      first positional argument: what you want mounted.
#   want_mp     second positional argument: where to mount it.
dry=0 assume_yes=0 opts=""
target="" want_mp=""

usage() {
  cat <<'EOF'
Usage: fix-mount.sh [options] <target> [mountpoint]

  <target>      /dev/sdb, /dev/sdb1, /dev/disk/by-uuid/…, UUID=…, LABEL=…,
                a bare label or uuid, or an existing/intended mountpoint.
  [mountpoint]  where to mount it. Optional when <target> is a mountpoint or
                already has an /etc/fstab entry.

Options:
  -o, --options OPTS   mount options to use (passed through to mount -o)
  -y, --yes            do not prompt; apply every safe fix
      --dry-run        print what would happen, change nothing
  -h, --help           this text

Examples:
  fix-mount.sh /dev/sdb /mnt/data      # whole disk -> finds the partition
  fix-mount.sh /mnt/data               # mountpoint -> resolves via fstab
  fix-mount.sh LABEL=backup /mnt/bkp
EOF
}

# --- output helpers ---------------------------------------------------------
# Colours only when stdout is a terminal. Piped into a file or less, the
# escape codes would show up as junk, so they are set to empty strings.
if [[ -t 1 ]]; then
  c_r=$'\e[31m' c_g=$'\e[32m' c_y=$'\e[33m' c_b=$'\e[1m' c_0=$'\e[0m'
else
  c_r="" c_g="" c_y="" c_b="" c_0=""
fi
# ok/bad/info print a tagged line. warn goes to stderr. head_ prints a bold
# section title. die prints a [FAIL] line and exits 1.
ok()   { printf '%s[ OK ]%s %s\n'   "$c_g" "$c_0" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n'   "$c_r" "$c_0" "$*"; }
warn() { printf '%s[WARN]%s %s\n'   "$c_y" "$c_0" "$*" >&2; }
info() { printf '[--]   %s\n' "$*"; }
head_() { printf '\n%s== %s ==%s\n' "$c_b" "$*" "$c_0"; }
die()  { bad "$*"; exit 1; }

# --- argument parsing -------------------------------------------------------
# Flags can come in any order. Anything not starting with "-" is a positional:
# the first one is <target>, the second is [mountpoint], a third is an error.
# "--" ends the flags. Note: die exits 1, so a bad flag exits 1, not 2.
while (( $# )); do
  case $1 in
    -o|--options) [[ ${2:-} ]] || die "--options needs a value"; opts=$2; shift 2 ;;
    -y|--yes)     assume_yes=1; shift ;;
    --dry-run)    dry=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; break ;;
    -*)           die "unknown arg: $1  (try --help)" ;;
    *)
      if   [[ -z $target  ]]; then target=$1
      elif [[ -z $want_mp ]]; then want_mp=$1
      else die "too many arguments: $1  (try --help)"
      fi
      shift ;;
  esac
done
# No target at all: print usage and exit 2 (the only exit-2 path).
[[ $target ]] || { usage >&2; exit 2; }

# --- preflight --------------------------------------------------------------
# Check the tools the script cannot work without. lsblk, findmnt, mount and
# blkid all come from util-linux; sudo runs every change.
# Under --dry-run a missing tool is a warning, not a hard fail (see
# install-ly.sh): you may well be dry-running on a box that has not installed
# the tool yet.
preflight() {
  local miss; miss() { (( dry )) && warn "$1" || die "$1"; }
  local t
  for t in lsblk findmnt mount blkid; do
    command -v "$t" >/dev/null || miss "missing: $t (install util-linux)"
  done
  command -v sudo >/dev/null || miss "missing: sudo"
}

# --- target resolution ------------------------------------------------------
# Step 1: work out what you meant. You can hand in a device (/dev/sdb), a
# folder (/mnt/usb), or a label or UUID (the disk's name, or its long unique
# serial number). resolve() turns any of those into a real device.
#
# DEV  the real block device node, like /dev/sdb1. Empty if not known yet.
# MP   the mountpoint path. It may not exist yet. Empty if not known yet.
# Neither being set later is a hard failure.
DEV="" MP=""

resolve() {
  local t=$1

  case $t in
    UUID=*|PARTUUID=*|LABEL=*|PARTLABEL=*)
      # A tag like LABEL=backup. findfs is the standard tool that turns a tag
      # into a device, and it understands every tag form.
      DEV=$(findfs "$t" 2>/dev/null || true)
      [[ $DEV ]] || die "no block device matches $t  (lsblk -o NAME,LABEL,UUID to list)"
      ;;
    /dev/*)
      # A device path. It must exist and be a block device (a disk-like node).
      [[ -e $t ]] || die "no such device: $t  (lsblk to list what is attached)"
      [[ -b $t ]] || die "not a block device: $t"
      # /dev/disk/by-*/… are symlinks. Follow them to the real node, so later
      # lsblk and findmnt lookups match the name the kernel reports.
      DEV=$(readlink -f "$t")
      ;;
    /*)
      # An absolute path that is not under /dev is a mountpoint, existing or
      # intended. A missing folder is itself one of the causes we fix.
      MP=$t
      ;;
    *)
      # A bare word, like "sdb1" or "backup". Try, in order: a device node
      # /dev/<word>, then a filesystem label, then a UUID.
      if   [[ -b /dev/$t ]];            then DEV=$(readlink -f "/dev/$t")
      elif DEV=$(findfs "LABEL=$t" 2>/dev/null); then :
      elif DEV=$(findfs "UUID=$t"  2>/dev/null); then :
      else die "cannot resolve '$t' as a device, label or uuid  (absolute paths only for mountpoints)"
      fi
      ;;
  esac

  # A second positional always wins as the mountpoint.
  [[ $want_mp ]] && MP=$want_mp
  return 0
}

# --- already mounted? -------------------------------------------------------
# Step 2: is it already mounted? If yes, say where and stop: nothing to fix.
# This is the cheapest exit. (If it were mounted, mount would have said
# "already mounted", not the error this script is named for.)
# Checks the device first, then whether anything at all sits on the
# mountpoint. Returns 0 = already mounted, 1 = not mounted.
check_mounted() {
  local where=""
  if [[ $DEV ]]; then
    where=$(findmnt -n -o TARGET --source "$DEV" | head -1 || true)
    if [[ $where ]]; then
      ok "$DEV is already mounted at $where"
      findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS --source "$DEV"
      return 0
    fi
  fi
  if [[ $MP && -d $MP ]] && findmnt -n --mountpoint "$MP" >/dev/null 2>&1; then
    ok "$MP already has a filesystem mounted on it"
    findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS --mountpoint "$MP"
    return 0
  fi
  return 1
}

# --- diagnosis --------------------------------------------------------------
# Step 3: diagnose. This part only *reads*; it changes nothing. It checks:
#   - did you point at the whole disk instead of a partition?
#   - what filesystem is on there, if any?
#   - is its driver loaded, merely available, or missing?
#   - does the mountpoint exist, is it a folder, is it empty?
#   - is the device already in use somewhere else?
#   - is /etc/fstab (the list of drives Linux mounts by itself) involved?
# Then it prints a numbered list: each cause and the command that fixes it.
#
# Findings pile up in two matching lists. CAUSES[i] says what is wrong.
# FIXES[i] is the command (or human action) that clears it. The fix step acts
# on the flags below, not on these strings:
#   TRY_DEV      the device we will actually try to mount (may differ from DEV)
#   TRY_FS       the filesystem type found on TRY_DEV
#   NEED_MKDIR   1 = the mountpoint folder must be created
#   NEED_MODULE  name of a kernel module to load with modprobe
#   NEED_PKG     name of a Debian package to install for the driver
#   BLOCKED      1 = found something this script must not fix (see block())
CAUSES=() FIXES=()
TRY_DEV="" TRY_FS="" NEED_MKDIR=0 NEED_MODULE="" NEED_PKG="" BLOCKED=0
# add: record a cause the script can fix.
add() { CAUSES+=("$1"); FIXES+=("$2"); }
# block: record a cause this script must not fix on its own (encrypted volume,
# LVM member, no filesystem at all…) and set BLOCKED. The script then prints
# the command you would run and exits 1. It refuses to guess past one.
block() { CAUSES+=("$1"); FIXES+=("$2"); BLOCKED=1; }

# lsb <column> <device>: ask lsblk for one column of one device, like FSTYPE.
# lsblk reads the udev database (the list the system keeps of every device),
# so it answers for a normal user. blkid would need root to re-read the disk
# itself. So lsblk is used everywhere.
lsb() { lsblk -dnro "$1" "$2" 2>/dev/null || true; }

# Is there a driver for filesystem <fs>? The answer is the return code:
#   0 = loaded (listed in /proc/filesystems)
#   1 = module is on disk but not loaded (modinfo finds it)
#   2 = no driver on this system at all
# Callers must use it in an `if`/`case` — a bare call would trip `set -e`.
fs_driver() {
  local fs=$1
  if grep -qw "$fs" /proc/filesystems; then return 0; fi
  if modinfo -n "$fs" >/dev/null 2>&1; then return 1; fi
  return 2
}

# Which Debian package supplies the tools / FUSE driver for a filesystem type.
# Debian ships these apart from the kernel module. Empty = no known package.
fs_pkg() {
  case $1 in
    ntfs|ntfs3) echo ntfs-3g ;;
    exfat)      echo exfatprogs ;;
    f2fs)       echo f2fs-tools ;;
    btrfs)      echo btrfs-progs ;;
    xfs)        echo xfsprogs ;;
    hfs|hfsplus) echo hfsprogs ;;
    jfs)        echo jfsutils ;;
    udf)        echo udftools ;;
    *)          echo "" ;;
  esac
}

# /etc/fstab is the reason a one-argument `mount` ever works. If the target has
# an entry, mount already knows the (device, mountpoint) pair and the failure
# is elsewhere. Looks both ways: mountpoint -> device, then device ->
# mountpoint, and fills in whichever of DEV / MP is still empty.
fstab_lookup() {
  local src="" mp=""
  if [[ $MP ]]; then
    src=$(findmnt --fstab -n -o SOURCE --mountpoint "$MP" 2>/dev/null | head -1 || true)
    if [[ $src ]]; then
      info "fstab: $MP <- $src"
      if [[ -z $DEV ]]; then DEV=$(findfs "$src" 2>/dev/null || readlink -f "$src" 2>/dev/null || true); fi
      return 0
    fi
  fi
  if [[ $DEV ]]; then
    mp=$(findmnt --fstab -n -o TARGET --source "$DEV" 2>/dev/null | head -1 || true)
    if [[ $mp ]]; then
      info "fstab: $DEV -> $mp"
      if [[ -z $MP ]]; then MP=$mp; fi
      return 0
    fi
  fi
  return 1
}

# Cause 2: the argument is the whole disk. A disk holds a partition table, not
# a filesystem, so mount has nothing to work with. Pick the partition instead.
# Returns 1 (do nothing) when DEV is not a whole disk or loop device.
expand_disk() {
  local type; type=$(lsb TYPE "$DEV")
  [[ $type == disk || $type == loop ]] || return 1
  local self_fs; self_fs=$(lsb FSTYPE "$DEV")
  # A disk can legitimately carry a filesystem directly (superfloppy layout).
  if [[ $self_fs ]]; then return 1; fi

  # List every partition under the disk that has a filesystem, as
  # "name|fstype|size" strings.
  local -a cand=() name fstype size
  while read -r name fstype size; do
    if [[ $name == "$DEV" ]]; then continue; fi
    [[ $fstype ]] || continue
    cand+=("$name|$fstype|$size")
  done < <(lsblk -nrpo NAME,FSTYPE,SIZE "$DEV" 2>/dev/null || true)

  # None at all: blank, wiped or unpartitioned. Stop here.
  if (( ${#cand[@]} == 0 )); then
    block "$DEV is a whole disk with no mountable partition on it" \
          "inspect it: lsblk -f $DEV   (an empty or unpartitioned disk needs partitioning/formatting — this script will not do that)"
    return 0
  fi

  # One partition: use it. Several: list them all and tell you to pick one,
  # but still go on with the first one (the mount step asks before running).
  local first=${cand[0]} rest
  rest=${first#*|}                       # "<fstype>|<size>"
  if (( ${#cand[@]} == 1 )); then
    TRY_DEV=${first%%|*}
    add "$DEV is the whole disk; its filesystem lives on $TRY_DEV (${rest%%|*}, ${rest#*|})" \
        "mount $TRY_DEV instead of $DEV"
  else
    local c list=""
    for c in "${cand[@]}"; do list+="    ${c//|/  }"$'\n'; done
    TRY_DEV=${first%%|*}
    add "$DEV is the whole disk and has ${#cand[@]} partitions with filesystems:"$'\n'"${list%$'\n'}" \
        "pick one explicitly, e.g. mount ${first%%|*}"
  fi
}

# Container formats are not filesystems: an encrypted LUKS volume, an LVM
# physical volume, an md RAID member. Mounting them directly always fails, and
# opening them changes system state, so guessing is wrong. Each one blocks and
# prints the command you would run. Swap is listed too: it is switched on with
# swapon, never mounted.
check_container() {
  case $TRY_FS in
    crypto_LUKS)
      block "$TRY_DEV is an encrypted LUKS volume, not a filesystem" \
            "sudo cryptsetup open $TRY_DEV unlocked && $0 /dev/mapper/unlocked ${MP:-<mountpoint>}" ;;
    LVM2_member)
      block "$TRY_DEV is an LVM physical volume; the filesystem is on a logical volume inside it" \
            "sudo vgchange -ay && lsblk -f   # then run this script against the /dev/<vg>/<lv> node" ;;
    linux_raid_member)
      block "$TRY_DEV is a member of an md RAID array, not a filesystem" \
            "sudo mdadm --assemble --scan && lsblk -f" ;;
    swap)
      block "$TRY_DEV is a swap partition — swap is enabled, never mounted" \
            "sudo swapon $TRY_DEV" ;;
  esac
}

# What filesystem is on TRY_DEV, and can this system read it?
check_fs() {
  TRY_FS=$(lsb FSTYPE "$TRY_DEV")
  # No filesystem signature: the disk is brand new, wiped, or truly broken.
  # No mount option rescues that. Check the hardware first (lsblk,
  # sudo dmesg | tail). Formatting destroys everything on the disk: if the
  # data matters, stop and copy the raw disk somewhere else first.
  if [[ -z $TRY_FS ]]; then
    block "no filesystem signature found on $TRY_DEV" \
          "confirm with: sudo blkid $TRY_DEV   (blank means unformatted — formatting is destructive and out of scope here)"
    return
  fi
  info "filesystem $TRY_FS on $TRY_DEV"
  check_container
  if (( BLOCKED )); then return 0; fi

  # Driver state (see fs_driver): loaded = fine; on disk = modprobe it;
  # absent = install the package from fs_pkg, or block if none is known.
  local pkg; pkg=$(fs_pkg "$TRY_FS")
  local rc=0; fs_driver "$TRY_FS" || rc=$?
  case $rc in
    0) : ;;
    1) NEED_MODULE=$TRY_FS
       add "the $TRY_FS driver is available but not loaded into the kernel" \
           "sudo modprobe $TRY_FS" ;;
    2) if [[ $pkg ]]; then
         NEED_PKG=$pkg
         add "no $TRY_FS driver on this system (kernel module absent)" \
             "sudo apt-get install -y $pkg"
       else
         block "no $TRY_FS driver on this system and no known Debian package provides one" \
               "check: modinfo $TRY_FS ; apt-cache search $TRY_FS"
       fi ;;
  esac

  # vfat/exfat/ntfs carry no Unix ownership. Without uid=/gid= the mount lands
  # root-owned and read-only for you, which reads as a second, later failure.
  # This is only a hint; mount_opts() below adds uid=/gid= by itself.
  case $TRY_FS in
    vfat|exfat|ntfs|ntfs3)
      [[ $opts == *uid=* ]] || info "hint: $TRY_FS has no Unix permissions — add -o uid=$(id -u),gid=$(id -g) to own the files" ;;
  esac
}

# Is the mountpoint usable? No mountpoint known: block (we will not guess one).
# Missing: create it (fixable). Exists but is a file: block. Not empty: only a
# warning.
check_mountpoint() {
  if [[ -z $MP ]]; then
    block "no mountpoint given and no /etc/fstab entry for ${TRY_DEV:-$DEV}" \
          "say where it should go: $0 ${TRY_DEV:-$DEV} /mnt/data"
    return
  fi
  if [[ ! -e $MP ]]; then
    NEED_MKDIR=1
    add "mountpoint $MP does not exist" "sudo mkdir -p $MP"
  elif [[ ! -d $MP ]]; then
    block "$MP exists but is not a directory" "pick a different mountpoint"
  elif [[ -n $(ls -A "$MP" 2>/dev/null || true) ]]; then
    # Not fatal: mount succeeds and hides the contents until unmount.
    warn "$MP is not empty — mounting hides its current contents until unmounted"
  fi
}

# Is TRY_DEV already mounted somewhere else? That blocks: unmount it first.
# (This matters when TRY_DEV is a partition found by expand_disk, which
# check_mounted did not look at.)
check_busy() {
  [[ $TRY_DEV ]] || return 0
  local where; where=$(findmnt -n -o TARGET --source "$TRY_DEV" 2>/dev/null | head -1 || true)
  [[ $where ]] || return 0
  block "$TRY_DEV is already mounted at $where" \
        "use it there, or: sudo umount $where"
}

# Run the checks in order. fstab first, since it may fill in DEV or MP. Each
# later check is skipped once something has blocked.
diagnose() {
  head_ "diagnosis"
  fstab_lookup || true
  if [[ $DEV ]]; then TRY_DEV=$DEV; expand_disk || true; fi
  if [[ $TRY_DEV ]]; then
    check_busy
    (( BLOCKED )) || check_fs
  else
    block "could not determine which device to mount" \
          "list what is attached: lsblk -f"
  fi
  (( BLOCKED )) || check_mountpoint
}

# Print the numbered list: each cause, then "fix:" and its command.
report() {
  if (( ${#CAUSES[@]} == 0 )); then
    ok "no fault found — the mount should succeed as-is"
    return
  fi
  head_ "causes"
  local i
  for i in "${!CAUSES[@]}"; do
    printf '%s%d.%s %s\n     fix: %s\n' "$c_b" "$((i+1))" "$c_0" "${CAUSES[$i]}" "${FIXES[$i]}"
  done
}

# --- fixes ------------------------------------------------------------------
# Step 4: fix. Everything below can change the system, so it asks before
# every single change, like:
#     create mountpoint /mnt/usb? [y/N]
#     run: sudo mount -o uid=1000,gid=1000 /dev/sdb1 /mnt/usb [y/N]
# It can: create the mountpoint folder, load a driver (modprobe), install a
# driver package (apt-get install), and run the corrected mount command.
#
# confirm "<question>": ask y/N. Returns 0 only on an answer starting y/Y.
#   --yes          answers yes without asking.
#   no terminal    on stdin (piped, cron): refuses, rather than waiting
#                  forever on a question nobody can answer.
# --dry-run never reaches here: act() and try_mount() print and return first.
confirm() {
  if (( assume_yes )); then return 0; fi
  if [[ ! -t 0 ]]; then
    warn "non-interactive stdin — skipping: $1  (pass --yes to allow)"
    return 1
  fi
  local a
  read -r -p "  $1 [y/N] " a
  [[ $a == [yY]* ]]
}

# act "<question>" <command…>: run a privileged command after confirmation.
# Under --dry-run it only prints "DRY  <command>". Returns non-zero if
# declined.
act() {
  local desc=$1; shift
  if (( dry )); then printf 'DRY  %s\n' "$*"; return 0; fi
  if ! confirm "$desc"; then return 1; fi
  "$@"
}

# Apply the fixable causes, in this order: create the mountpoint, install the
# driver package, load the kernel module. A declined or failed fix only warns;
# the mount is still tried after.
apply_fixes() {
  head_ "applying"
  if (( NEED_MKDIR )); then
    act "create mountpoint $MP?" sudo mkdir -p "$MP" && ok "mountpoint $MP ready" || warn "mountpoint not created"
  fi
  if [[ $NEED_PKG ]]; then
    if act "install $NEED_PKG (provides the $TRY_FS driver)?" sudo apt-get install -y "$NEED_PKG"; then
      ok "$NEED_PKG installed"
      # The package may ship a kernel module that still needs loading.
      if ! grep -qw "$TRY_FS" /proc/filesystems; then NEED_MODULE=$TRY_FS; fi
    else
      warn "$NEED_PKG not installed — the mount will likely still fail"
    fi
  fi
  if [[ $NEED_MODULE ]]; then
    act "load the $NEED_MODULE kernel module?" sudo modprobe "$NEED_MODULE" && ok "$NEED_MODULE loaded" || warn "$NEED_MODULE not loaded"
  fi
}

# Why uid=/gid= get added by themselves: vfat, exfat and ntfs come from the
# Windows world and store no idea of who owns a file. Mounted plainly,
# everything belongs to root and you cannot write to your own USB stick.
# So this adds uid=<your id>,gid=<your group> and the files belong to you.
# If you passed your own -o, it assumes you know what you want and adds
# nothing.
mount_opts() {
  if [[ $opts ]]; then printf '%s' "$opts"; return; fi
  case $TRY_FS in
    vfat|exfat|ntfs|ntfs3) printf 'uid=%s,gid=%s' "$(id -u)" "$(id -g)" ;;
    *) printf '' ;;
  esac
}

# Last 12 kernel lines mentioning this device — the "dmesg(1) may have more
# information" half of the original error message, fetched so you do not have to.
show_dmesg() {
  local base=${TRY_DEV##*/} out
  out=$(sudo dmesg 2>/dev/null | grep -F "$base" | tail -n 12 || true)
  if [[ $out ]]; then
    head_ "kernel log ($base)"
    printf '%s\n' "$out"
  fi
}

# NTFS left "dirty" by Windows cannot be mounted read-write. Windows leaves it
# dirty after hibernation, and after "fast startup" shutdown (which is really
# hibernation in disguise, and leaves the disk locked).
# Why ntfsfix always asks: every other fix creates a folder or installs
# software — nothing touches your data. ntfsfix WRITES to the filesystem to
# clear the dirty flag. So it asks every time, even under --yes (that flag
# means "skip the routine prompts", not "repair my disk"), and refuses
# entirely when no one is at a terminal to answer. The safer routes: mount
# read-only, or boot Windows and shut it down fully.
offer_ntfsfix() {
  command -v ntfsfix >/dev/null || { warn "ntfsfix not installed (apt-get install ntfs-3g)"; return 1; }
  printf '%s\n' "  ntfsfix clears the NTFS dirty flag and journal. It writes to the filesystem."
  printf '%s\n' "  Safer alternative: mount read-only, or boot Windows and shut down fully (not hibernate)."
  if [[ ! -t 0 ]]; then warn "non-interactive — not running ntfsfix"; return 1; fi
  local a; read -r -p "  run: sudo ntfsfix $TRY_DEV [y/N] " a
  [[ $a == [yY]* ]] || return 1
  sudo ntfsfix "$TRY_DEV"
}

# Success: say so and show what is now mounted on MP.
mounted_ok() {
  ok "mounted"
  findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS --mountpoint "$MP"
}

# Step 5: try the mount. If it still fails, read mount's error and react:
# show the matching kernel log lines, offer a read-only retry, or — for a
# Windows disk that was hibernated instead of shut down — offer ntfsfix.
# try_mount [extra]: "extra" is one more mount option, like "ro", tacked onto
# the options from mount_opts. Returns 0 = mounted (or dry-run), 1 = not.
try_mount() {
  local extra=${1:-} mopts
  mopts=$(mount_opts)
  if [[ $extra ]]; then mopts=${mopts:+$mopts,}$extra; fi

  # Build the command as a list, so options and paths with spaces stay whole.
  local -a cmd=(sudo mount)
  if [[ $mopts ]]; then cmd+=(-o "$mopts"); fi
  cmd+=("$TRY_DEV" "$MP")

  if (( dry )); then printf 'DRY  %s\n' "${cmd[*]}"; return 0; fi
  if ! confirm "run: ${cmd[*]}"; then info "not mounted (declined)"; return 1; fi

  # Capture mount's error text (stderr) and its exit code without letting
  # set -e kill the script on failure.
  local err rc=0
  err=$("${cmd[@]}" 2>&1) || rc=$?
  if (( rc == 0 )); then mounted_ok; return 0; fi

  # Match the error text to a likely cause and the next thing to try.
  bad "mount failed: ${err:-exit $rc}"
  case $err in
    *"unknown filesystem type"*)
      info "the kernel has no driver for this filesystem — see the diagnosis above" ;;
    *"wrong fs type"*|*"bad superblock"*)
      info "the superblock is unreadable: wrong partition, or a damaged/unsupported filesystem"
      show_dmesg ;;
    *[Hh]ibernat*|*hiberfil*|*"unsafe state"*|*"Falling back to read-only"*)
      # Dirty NTFS: try ntfsfix and then the same mount again; if that is
      # declined, offer a read-only mount instead.
      warn "the NTFS volume was not shut down cleanly"
      if offer_ntfsfix; then try_mount "$extra"; return $?; fi
      if confirm "mount read-only instead?"; then try_mount ro; return $?; fi ;;
    *"already mounted"*|*busy*)
      info "device or mountpoint is in use: findmnt $TRY_DEV ; sudo fuser -vm $MP" ;;
    *"Permission denied"*|*"only root"*)
      info "needs privileges — check your sudo rights" ;;
    *)
      show_dmesg ;;
  esac

  # Read-only is the standard escape hatch for a damaged or foreign filesystem:
  # it never writes, so it cannot make the damage worse. Offered once only:
  # a retry that already has an extra option does not offer it again.
  if [[ -z $extra ]] && confirm "retry read-only (-o ro)?"; then try_mount ro; return $?; fi
  return 1
}

# The whole run, top to bottom: check tools, resolve the target, show what
# was resolved, stop if already mounted, diagnose, stop (exit 1) if blocked,
# apply fixes if any, then mount. try_mount's result is main's last command,
# so a failed mount makes the script exit 1 (via set -e).
main() {
  preflight
  resolve "$target"

  head_ "resolved"
  # Note the `|| true` / `if` forms below: under `set -e` a bare
  # `[[ cond ]] && cmd` is a failing AND-list when cond is false, which kills
  # the script. Never shorten these back to the one-liner form.
  if [[ $DEV ]]; then info "device     $DEV"; else info "device     (unknown — will resolve from fstab/mountpoint)"; fi
  if [[ $MP  ]]; then info "mountpoint $MP";  else info "mountpoint (none given)"; fi
  [[ $opts ]] && info "options    $opts" || true
  (( dry )) && info "mode       dry-run (nothing will be changed)" || true

  head_ "state"
  if check_mounted; then
    info "nothing to fix"
    exit 0
  fi
  info "not currently mounted"

  diagnose
  report
  # A blocked cause exits 1 even under --dry-run.
  if (( BLOCKED )); then exit 1; fi

  if (( NEED_MKDIR )) || [[ $NEED_MODULE || $NEED_PKG ]]; then apply_fixes; fi

  head_ "mount"
  try_mount
}

main "$@"
