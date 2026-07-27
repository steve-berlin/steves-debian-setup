#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-mx-frugal.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-mx-frugal.sh — boot an MX/antiX ISO from an internal partition so you
# can install Linux with no USB stick, no DVD, no external media at all.
#
# What it does (frugal boot, used purely as the install medium):
#   1. loop-mounts the ISO, copies its /antiX dir (vmlinuz, initrd.gz, linuxfs)
#      onto an existing filesystem — nothing is formatted or repartitioned;
#   2. drops a /etc/grub.d/ snippet that boots that kernel with the live-init
#      params `bdir=` (where linuxfs lives) + `buuid=` (UUID of the partition
#      holding it) — the same pair antiX's own frugal grub.entry generates;
#   3. runs update-grub.
# Reboot, pick the entry, get a normal MX live session running off the disk, and
# run MX's installer from it onto a real partition. Then `--uninstall` to drop
# the entry + the copied files.
#
# No persistence is configured on purpose: this is a throwaway install medium,
# not a frugal *system*. Live session changes live in the RAM overlay and are
# gone at reboot — exactly like booting the USB stick this replaces.
#
# Boot params (antiX-FAQ "Live Boot Parameters"):
#   bdir=  boot dir holding linuxfs/vmlinuz/initrd.gz, relative to the partition
#          root (NOT to /). Default would be /antiX.
#   buuid= filesystem UUID of that partition.
#   from=  device types to probe. Default is usb,cd — must be widened or the
#          live-init never looks at an internal disk.
# `fromiso=` (boot the .iso file whole via loopback) is deliberately NOT used:
# upstream marks it deprecated and it disables live features.
set -euo pipefail

TARGET_DEFAULT=/frugal
GRUB_PREFIX=42-mx-frugal      # /etc/grub.d/<GRUB_PREFIX>-<name>

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

run() { if (( dry )); then printf 'DRY  %s\n' "$*"; else "$@"; fi; }

# run-parts (update-grub) skips filenames with dots or odd characters.
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

# Under --dry-run a missing dep warns instead of hard-failing (see install-ly.sh):
# you may well be planning this on a box that isn't the one being reworked.
miss() { (( dry )) && echo "warning: $1" >&2 || { echo "error: $1" >&2; exit 1; }; }

preflight() {
  for c in findmnt lsblk cp du df sudo; do
    command -v "$c" >/dev/null || miss "missing: $c"
  done
  command -v update-grub >/dev/null || command -v grub-mkconfig >/dev/null \
    || miss "missing: update-grub / grub-mkconfig — this box does not boot via GRUB"
  [[ -d /etc/grub.d ]] || miss "missing: /etc/grub.d"
}

grub_update() {
  if command -v update-grub >/dev/null; then run sudo update-grub
  else run sudo grub-mkconfig -o /boot/grub/grub.cfg; fi
}

# Resolve <dir> to (mountpoint, fs UUID, fstype, source device), and hard-fail on
# anything GRUB + the live-init can't reach by plain UUID.
probe_target() {
  # Separate statements: bash expands every word of a `local a=… b=$a` line
  # before assigning, so `probe=$dir` on the same line reads an unset $dir.
  local dir=$1
  local probe=$dir
  # --target wants a path that exists; walk up to the nearest existing ancestor.
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
rel_bdir() {
  local abs=$1 mount=$2 rel=${1#"$2"}
  [[ $mount == / ]] && rel=$abs
  [[ $rel == /* ]] || rel="/$rel"
  printf '%s' "$rel"
}

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

  local dest="$target/$name/antiX" grub_file="/etc/grub.d/$GRUB_PREFIX-$name"
  if [[ -d $dest && -f $grub_file && $mode != reinstall ]]; then
    echo "already installed: $dest + $grub_file (use --reinstall to refresh)"
    return 0
  fi

  probe_target "$target"
  local bdir; bdir=$(rel_bdir "$dest" "$mp")

  # Read the payload straight out of the ISO so a layout change fails loud here
  # rather than producing a GRUB entry that drops to a rescue prompt at boot.
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
  if (( dry )); then
    printf 'DRY  write %s:\n%s\n' "$grub_file" "$snippet"
  else
    printf '%s\n' "$snippet" | sudo tee "$grub_file" >/dev/null
    sudo chmod 0755 "$grub_file"
  fi
  grub_update

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
