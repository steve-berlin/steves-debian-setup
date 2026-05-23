#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh install-nic-tuning.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# install-nic-tuning.sh — NIC tuning for speed & stability.
# Target: ThinkPad T480 (Intel I219-LM eth + Intel 8265 wifi) on Debian/MX
# with NetworkManager. Idempotent; degrades to warn on other hardware.

set -euo pipefail

# ethtool/sysctl live in /usr/sbin; interactive bash on Debian doesn't put
# sbin dirs on a non-root user's PATH, so `command -v` misses them.
PATH=$PATH:/usr/sbin:/sbin

SYSCTL=/etc/sysctl.d/99-nic-tuning.conf
DISPATCHER=/etc/NetworkManager/dispatcher.d/99-nic-tuning
LAUNCHER_DST=$HOME/.local/bin/nic-boost
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LAUNCHER_SRC=$SCRIPT_DIR/../launchers/nic-boost

mode=install; dry=0
for a in "$@"; do
  case $a in
    --uninstall) mode=uninstall ;;
    --dry-run)   dry=1 ;;
    -h|--help)   sed -n '2,4p' "$0"; echo "Usage: $0 [--uninstall] [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
have(){ command -v "$1" >/dev/null; }

have ethtool && have sysctl || { echo "need ethtool + sysctl on PATH" >&2; exit 1; }

if [[ $mode == uninstall ]]; then
  run sudo rm -f "$SYSCTL" "$DISPATCHER"
  run rm -f "$LAUNCHER_DST"
  run sudo sysctl --system >/dev/null
  echo "removed."
  exit 0
fi

# Detect ifaces (skip lo, virtual bridges, docker).
eth=() wifi=()
for i in /sys/class/net/*; do
  n=${i##*/}
  [[ $n == lo || $n == vir* || $n == docker* || $n == br-* ]] && continue
  if [[ -d $i/wireless ]]; then wifi+=("$n")
  elif [[ -e $i/device/driver ]]; then eth+=("$n"); fi
done
echo "ethernet: ${eth[*]:-none}    wifi: ${wifi[*]:-none}"

write() { (( dry )) && printf 'DRY  write %s\n' "$1" || sudo tee "$1" >/dev/null; }

# 1. Kernel TCP tweaks — how Linux talks over the network. No power cost,
#    pure protocol logic. The values below do five things:
#    - BBR + fq: smarter congestion control. Default ("cubic") panics and
#      slows down on any packet loss; BBR estimates real bandwidth instead.
#      Big win over WiFi, where loss is normal.
#    - rmem_max / wmem_max + tcp_rmem / tcp_wmem: raise per-connection
#      buffer ceilings. Default ~200 KiB caps a single download on a fast
#      link; 16 MiB lets the kernel grow it as needed.
#    - tcp_fastopen=3: skip one round-trip when reconnecting to a server
#      you've spoken to before (saves ~50-100 ms per fresh connection).
#    - tcp_mtu_probing=1: rescue connections on hotel/airport/corporate
#      WiFi that block ICMP, which breaks normal MTU discovery.
#    - tcp_tw_reuse + no slow-start-after-idle: small wins for bursty
#      client workloads (browsing, gaming).
write "$SYSCTL" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536  16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF

# 2. NetworkManager dispatcher: per-ethernet-iface ethtool tweaks on every
#    link-up. Ring buffers maxed (more headroom for bursty traffic, no power
#    cost) and Wake-on-LAN disabled (we don't use it; trickle saving when
#    the machine is off). No WiFi tweaks here — those live in nic-boost.
if have nmcli && systemctl is-active --quiet NetworkManager; then
  write "$DISPATCHER" <<'EOF'
#!/bin/sh
iface="$1"; event="$2"
[ "$event" = "up" ] || exit 0
[ -e "/sys/class/net/$iface/device/driver" ] || exit 0
[ -d "/sys/class/net/$iface/wireless" ] && exit 0
ethtool -s "$iface" wol d 2>/dev/null || true
rx=$(ethtool -g "$iface" 2>/dev/null | awk '/^Pre-set maximums:/{p=1;next} p&&/^RX:/{print $2;exit}')
tx=$(ethtool -g "$iface" 2>/dev/null | awk '/^Pre-set maximums:/{p=1;next} p&&/^TX:/{print $2;exit}')
[ -n "$rx" ] && [ -n "$tx" ] && ethtool -G "$iface" rx "$rx" tx "$tx" 2>/dev/null || true
EOF
  (( dry )) || sudo chmod 755 "$DISPATCHER"
else
  echo "warn: NetworkManager not active — skipped $DISPATCHER"
fi

# Apply now so user doesn't need to reboot/reconnect.
run sudo sysctl --system >/dev/null
for n in "${eth[@]}"; do
  run sudo ethtool -s "$n" wol d || true
  rx=$(ethtool -g "$n" 2>/dev/null | awk '/^Pre-set maximums:/{p=1;next} p&&/^RX:/{print $2;exit}')
  tx=$(ethtool -g "$n" 2>/dev/null | awk '/^Pre-set maximums:/{p=1;next} p&&/^TX:/{print $2;exit}')
  [[ -n ${rx:-} && -n ${tx:-} ]] && run sudo ethtool -G "$n" rx "$rx" tx "$tx" || true
done

# Deploy the nic-boost launcher into ~/.local/bin so the user can call it.
if [[ -f $LAUNCHER_SRC ]]; then
  run mkdir -p "$(dirname "$LAUNCHER_DST")"
  run install -m 755 "$LAUNCHER_SRC" "$LAUNCHER_DST"
  echo "installed: $LAUNCHER_DST"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "warn: $HOME/.local/bin is not on PATH — add it to use 'nic-boost' directly." ;;
  esac
else
  echo "warn: $LAUNCHER_SRC not found; skipped nic-boost install."
fi

echo "done. Run 'nic-boost' before bandwidth-heavy work for the WiFi/EEE temporary boost."
