#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-tld.sh` — uses `[[` and `(( ))`.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
set -euo pipefail

APPID=305620
LIBRARY=/games/steam
NEED_GB=12
VDF=$HOME/.steam/steam/steamapps/libraryfolders.vdf

mode=install
dry=0
for a in "$@"; do
  case $a in
    --reinstall) mode=reinstall ;;
    --verify)    mode=verify ;;
    --dry-run)   dry=1 ;;
    -h|--help)   echo "Usage: $0 [--reinstall|--verify] [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run(){ (( dry )) && { echo "DRY: stm $*"; return; }; stm "$@"; }

command -v stm >/dev/null || { echo "error: stm not on PATH" >&2; exit 1; }
command -v steam >/dev/null || { echo "error: steam not installed" >&2; exit 1; }
[[ -f $VDF ]] || { echo "error: $VDF missing — launch Steam once" >&2; exit 1; }
grep -qF "\"$LIBRARY\"" "$VDF" || { echo "error: $LIBRARY not a Steam library — run stm first" >&2; exit 1; }
mountpoint -q "$LIBRARY" || { echo "error: $LIBRARY not mounted" >&2; exit 1; }
[[ -w $LIBRARY ]] || { echo "error: $LIBRARY not writable" >&2; exit 1; }

[[ $mode == verify ]] && { run "steam://validate/$APPID"; exit 0; }

avail=$(df -BG --output=avail "$LIBRARY" | awk 'NR==2{gsub(/[^0-9]/,""); print}')
(( avail >= NEED_GB )) || { echo "error: need ${NEED_GB}G free in $LIBRARY (have ${avail}G)" >&2; exit 1; }

[[ $mode == reinstall ]] && run "steam://uninstall/$APPID"
run "steam://install/$APPID"
