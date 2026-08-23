#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh fix-mount.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# fix-mount.sh — diagnose and repair a failing mount.
#
# The error this exists for:
#
#   mount: /dev/sdb: mount point not mounted or bad option.
#          dmesg(1) may have more information after failed mount system call.
#
# That message is util-linux's catch-all for "I could not turn what you typed
# into a (device, mountpoint, filesystem) triple". In practice it is one of:
#
#   1. One-argument `mount /dev/sdb` with no matching /etc/fstab entry — mount
#      has nowhere to put it and refuses to guess.
#   2. /dev/sdb is the whole disk. The filesystem lives on a partition
#      (/dev/sdb1); the disk itself holds only a partition table.
#   3. `mount -o remount …` aimed at something that is not currently mounted.
#   4. The mountpoint directory does not exist, or the fs driver (exfat, ntfs3,
#      f2fs…) is not loaded/installed, so no candidate mount can succeed.
#
# This script resolves what you typed, names the actual cause, and fixes the
# safe ones. It never formats, never repartitions, never edits /etc/fstab.
#
# Every mutating action prompts y/N unless --yes is given. --dry-run mutates
# nothing at all.
set -euo pipefail

# blkid, findfs, modprobe and fsck live in /usr/sbin (and /sbin). A plain user
# shell on Debian/MX does not have those on PATH, so every probe below would
# silently come back empty. Prepend them unconditionally — harmless duplicates.
PATH=/usr/sbin:/sbin:$PATH

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
if [[ -t 1 ]]; then
  c_r=$'\e[31m' c_g=$'\e[32m' c_y=$'\e[33m' c_b=$'\e[1m' c_0=$'\e[0m'
else
  c_r="" c_g="" c_y="" c_b="" c_0=""
fi
ok()   { printf '%s[ OK ]%s %s\n'   "$c_g" "$c_0" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n'   "$c_r" "$c_0" "$*"; }
warn() { printf '%s[WARN]%s %s\n'   "$c_y" "$c_0" "$*" >&2; }
info() { printf '[--]   %s\n' "$*"; }
head_() { printf '\n%s== %s ==%s\n' "$c_b" "$*" "$c_0"; }
die()  { bad "$*"; exit 1; }

# --- argument parsing -------------------------------------------------------
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
[[ $target ]] || { usage >&2; exit 2; }

# --- preflight --------------------------------------------------------------
# Under --dry-run a missing dep is a warning, not a hard fail (see install-ly.sh):
# you may well be dry-running on a box that has not installed the tool yet.
preflight() {
  local miss; miss() { (( dry )) && warn "$1" || die "$1"; }
  local t
  for t in lsblk findmnt mount blkid; do
    command -v "$t" >/dev/null || miss "missing: $t (install util-linux)"
  done
  command -v sudo >/dev/null || miss "missing: sudo"
}

# --- target resolution ------------------------------------------------------
# Fills DEV (canonical block device, or empty) and MP (mountpoint path, which
# may not exist yet, or empty). Neither being set is a hard failure.
DEV="" MP=""

resolve() {
  local t=$1

  case $t in
    UUID=*|PARTUUID=*|LABEL=*|PARTLABEL=*)
      # findfs is the canonical resolver and understands every tag form.
      DEV=$(findfs "$t" 2>/dev/null || true)
      [[ $DEV ]] || die "no block device matches $t  (lsblk -o NAME,LABEL,UUID to list)"
      ;;
    /dev/*)
      [[ -e $t ]] || die "no such device: $t  (lsblk to list what is attached)"
      [[ -b $t ]] || die "not a block device: $t"
      # /dev/disk/by-*/… are symlinks; carry the real node so later lsblk and
      # findmnt lookups match what the kernel reports.
      DEV=$(readlink -f "$t")
      ;;
    /*)
      # An absolute path that is not under /dev is a mountpoint — existing or
      # intended. A missing directory is itself one of the causes we fix.
      MP=$t
      ;;
    *)
      # Bare word: try device node, then filesystem label, then uuid.
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
# Cheapest possible exit: if the thing is already mounted there is nothing to
# repair, and `mount` would have said "already mounted" rather than the error
# this script is named for.
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
# Findings accumulate as parallel arrays: CAUSES[i] is what is wrong, FIXES[i]
# is the command (or human action) that clears it. Step 3 acts on the flags
# TRY_DEV / TRY_FS / NEED_MKDIR / NEED_MODULE / NEED_PKG rather than re-parsing
# these strings.
CAUSES=() FIXES=()
TRY_DEV="" TRY_FS="" NEED_MKDIR=0 NEED_MODULE="" NEED_PKG="" BLOCKED=0
add() { CAUSES+=("$1"); FIXES+=("$2"); }
# BLOCKED marks a cause this script must not fix on its own (encrypted volume,
# LVM member, no filesystem at all). Step 3 refuses to guess past one.
block() { CAUSES+=("$1"); FIXES+=("$2"); BLOCKED=1; }

# lsblk reads the udev database, so it answers as an unprivileged user; blkid
# would need root to re-read the superblock. Prefer lsblk everywhere.
lsb() { lsblk -dnro "$1" "$2" 2>/dev/null || true; }

# Filesystem driver state: 0 = loaded, 1 = module present but not loaded,
# 2 = no driver on this system. Callers must use it in an `if`/`case` —
# a bare call would trip `set -e`.
fs_driver() {
  local fs=$1
  if grep -qw "$fs" /proc/filesystems; then return 0; fi
  if modinfo -n "$fs" >/dev/null 2>&1; then return 1; fi
  return 2
}

# Userspace tools / FUSE drivers Debian ships separately from the kernel module.
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
# an entry, mount already knows the pair and the failure is elsewhere.
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
expand_disk() {
  local type; type=$(lsb TYPE "$DEV")
  [[ $type == disk || $type == loop ]] || return 1
  local self_fs; self_fs=$(lsb FSTYPE "$DEV")
  # A disk can legitimately carry a filesystem directly (superfloppy layout).
  if [[ $self_fs ]]; then return 1; fi

  local -a cand=() name fstype size
  while read -r name fstype size; do
    if [[ $name == "$DEV" ]]; then continue; fi
    [[ $fstype ]] || continue
    cand+=("$name|$fstype|$size")
  done < <(lsblk -nrpo NAME,FSTYPE,SIZE "$DEV" 2>/dev/null || true)

  if (( ${#cand[@]} == 0 )); then
    block "$DEV is a whole disk with no mountable partition on it" \
          "inspect it: lsblk -f $DEV   (an empty or unpartitioned disk needs partitioning/formatting — this script will not do that)"
    return 0
  fi

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

# Container formats are not filesystems. Mounting them directly always fails,
# and the unlock step is stateful enough that guessing is wrong.
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

check_fs() {
  TRY_FS=$(lsb FSTYPE "$TRY_DEV")
  if [[ -z $TRY_FS ]]; then
    block "no filesystem signature found on $TRY_DEV" \
          "confirm with: sudo blkid $TRY_DEV   (blank means unformatted — formatting is destructive and out of scope here)"
    return
  fi
  info "filesystem $TRY_FS on $TRY_DEV"
  check_container
  if (( BLOCKED )); then return 0; fi

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
  case $TRY_FS in
    vfat|exfat|ntfs|ntfs3)
      [[ $opts == *uid=* ]] || info "hint: $TRY_FS has no Unix permissions — add -o uid=$(id -u),gid=$(id -g) to own the files" ;;
  esac
}

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

check_busy() {
  [[ $TRY_DEV ]] || return 0
  local where; where=$(findmnt -n -o TARGET --source "$TRY_DEV" 2>/dev/null | head -1 || true)
  [[ $where ]] || return 0
  block "$TRY_DEV is already mounted at $where" \
        "use it there, or: sudo umount $where"
}

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
# Everything below can change the system. Each action is gated by confirm():
# --dry-run prints and returns, --yes answers yes, a non-interactive stdin
# refuses rather than blocking on a read that will never be answered.
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

# Run a privileged command after confirmation. Returns non-zero if declined.
act() {
  local desc=$1; shift
  if (( dry )); then printf 'DRY  %s\n' "$*"; return 0; fi
  if ! confirm "$desc"; then return 1; fi
  "$@"
}

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

# vfat/exfat/ntfs store no Unix ownership, so a default mount is root-owned and
# unwritable for you. Supply uid/gid unless the caller passed their own -o.
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

# NTFS left dirty by a Windows fast-shutdown or hibernation cannot be mounted
# read-write. ntfsfix WRITES to the filesystem, so it always asks, even under
# --yes — that flag means "skip the routine prompts", not "repair my disk".
offer_ntfsfix() {
  command -v ntfsfix >/dev/null || { warn "ntfsfix not installed (apt-get install ntfs-3g)"; return 1; }
  printf '%s\n' "  ntfsfix clears the NTFS dirty flag and journal. It writes to the filesystem."
  printf '%s\n' "  Safer alternative: mount read-only, or boot Windows and shut down fully (not hibernate)."
  if [[ ! -t 0 ]]; then warn "non-interactive — not running ntfsfix"; return 1; fi
  local a; read -r -p "  run: sudo ntfsfix $TRY_DEV [y/N] " a
  [[ $a == [yY]* ]] || return 1
  sudo ntfsfix "$TRY_DEV"
}

mounted_ok() {
  ok "mounted"
  findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS --mountpoint "$MP"
}

# Try the mount, and translate whatever mount says back into a next action.
try_mount() {
  local extra=${1:-} mopts
  mopts=$(mount_opts)
  if [[ $extra ]]; then mopts=${mopts:+$mopts,}$extra; fi

  local -a cmd=(sudo mount)
  if [[ $mopts ]]; then cmd+=(-o "$mopts"); fi
  cmd+=("$TRY_DEV" "$MP")

  if (( dry )); then printf 'DRY  %s\n' "${cmd[*]}"; return 0; fi
  if ! confirm "run: ${cmd[*]}"; then info "not mounted (declined)"; return 1; fi

  local err rc=0
  err=$("${cmd[@]}" 2>&1) || rc=$?
  if (( rc == 0 )); then mounted_ok; return 0; fi

  bad "mount failed: ${err:-exit $rc}"
  case $err in
    *"unknown filesystem type"*)
      info "the kernel has no driver for this filesystem — see the diagnosis above" ;;
    *"wrong fs type"*|*"bad superblock"*)
      info "the superblock is unreadable: wrong partition, or a damaged/unsupported filesystem"
      show_dmesg ;;
    *[Hh]ibernat*|*hiberfil*|*"unsafe state"*|*"Falling back to read-only"*)
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
  # it never writes, so it cannot make the damage worse.
  if [[ -z $extra ]] && confirm "retry read-only (-o ro)?"; then try_mount ro; return $?; fi
  return 1
}

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
  if (( BLOCKED )); then exit 1; fi

  if (( NEED_MKDIR )) || [[ $NEED_MODULE || $NEED_PKG ]]; then apply_fixes; fi

  head_ "mount"
  try_mount
}

main "$@"
