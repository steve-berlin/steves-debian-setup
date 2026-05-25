#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh debloat-redmi.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# debloat-redmi.sh — disable LineageOS preinstalled apps on a Redmi 4A (rolex)
# via ADB. Uses `pm disable-user --user 0` so no root or bootloader unlock is
# needed; every action is reversible with --restore.
# See CLAUDE.md "installers/" → "debloat-redmi.sh" for the curated-list rationale.
set -euo pipefail

DEVICE_CODENAME=rolex   # Redmi 4A; matches `getprop ro.product.device`

# Safe-to-disable: FOSS/replacement-available, disabling does not break the
# phone (no dialer/contacts/launcher/settings dependencies). Inline-commented.
SAFE=(
  org.lineageos.jelly        # built-in browser (use Brave/Bromite)
  com.android.email          # email (use FairEmail/K-9)
  com.android.gallery3d      # gallery (use Simple Gallery/Aves)
  org.lineageos.eleven       # music (use VLC/Vinyl)
  com.android.messaging      # SMS (use Signal/QKSMS)
  org.lineageos.audiofx      # audio EQ that hijacks every media stream
  org.lineageos.setupwizard  # first-boot welcome — only ever runs once anyway
  com.android.fmradio        # FM radio (needs wired headphones as antenna)
  com.android.soundrecorder  # legacy; LOS replaced this with org.lineageos.recorder
)
# Opt-in via --include-optional: useful only if you've already lined up
# replacements for each one. trebuchet is intentionally commented — disabling
# the default launcher with no replacement set locks you out of the home screen.
OPTIONAL=(
  com.android.calculator2
  com.android.deskclock
  org.lineageos.recorder
  # org.lineageos.trebuchet  # default launcher — set a replacement default FIRST
)

dry=0; mode=disable; optional=0
for a in "$@"; do
  case $a in
    --restore)          mode=restore ;;
    --list-only)        mode=list ;;
    --include-optional) optional=1 ;;
    --dry-run)          dry=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--restore|--list-only] [--include-optional] [--dry-run]
  bare               disable SAFE list on the connected Redmi 4A (idempotent)
  --include-optional also disable the OPTIONAL list
  --restore          re-enable every package this script touches
  --list-only        show pkg + status (enabled/disabled/missing), no changes
EOF
      exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  adb shell %s\n' "$*" || adb shell "$@"; }

# Preflight.
command -v adb >/dev/null || { echo "missing: adb (apt install adb)" >&2; exit 1; }
mapfile -t devs < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
case ${#devs[@]} in
  0) echo "error: no authorized device. Plug in Redmi 4A + accept USB-debugging." >&2; exit 1 ;;
  1) ;;
  *) echo "error: ${#devs[@]} devices visible — set ANDROID_SERIAL to pick one:" >&2
     printf '  %s\n' "${devs[@]}" >&2; exit 1 ;;
esac
actual=$(adb shell getprop ro.product.device 2>/dev/null | tr -d '\r')
[[ $actual == "$DEVICE_CODENAME" ]] \
  || { echo "error: device codename '$actual' != '$DEVICE_CODENAME' — wrong phone, refusing." >&2; exit 1; }

# Pull installed + disabled package lists once for fast per-pkg lookups.
# `tr -d '\r'` first — adb shell stdout uses CRLF, and a stray \r at the end
# of every package name makes `grep -Fxq` silently miss every match.
mapfile -t inst < <(adb shell pm list packages -a 2>/dev/null | tr -d '\r' | sed 's/^package://')
mapfile -t dis  < <(adb shell pm list packages -d 2>/dev/null | tr -d '\r' | sed 's/^package://')
has() { local needle=$1; shift; printf '%s\n' "$@" | grep -Fxq "$needle"; }

TARGETS=("${SAFE[@]}")
(( optional )) && TARGETS+=("${OPTIONAL[@]}")

case $mode in
  list)
    printf '%-40s %s\n' PACKAGE STATUS
    for p in "${SAFE[@]}" "${OPTIONAL[@]}"; do
      if   has "$p" "${dis[@]}";  then s='disabled'
      elif has "$p" "${inst[@]}"; then s='enabled'
      else                              s='not installed'
      fi
      printf '%-40s %s\n' "$p" "$s"
    done ;;
  disable)
    for p in "${TARGETS[@]}"; do
      has "$p" "${inst[@]}" || { echo "skip $p (not installed)"; continue; }
      has "$p" "${dis[@]}"  && { echo "skip $p (already disabled)"; continue; }
      run pm disable-user --user 0 "$p"
    done
    echo "── done ── reverse with: $0 --restore" ;;
  restore)
    for p in "${SAFE[@]}" "${OPTIONAL[@]}"; do
      has "$p" "${dis[@]}" || continue
      run pm enable --user 0 "$p"
    done ;;
esac
