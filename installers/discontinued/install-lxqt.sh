#!/usr/bin/env bash
# install-lxqt.sh — LXQt desktop with bilingual us/ru keyboard, F5/F6
# brightness, Meta key opening Fancy Menu (bottom-left), and Albert
# alt+space launcher. Target: Debian 13 (trixie) / MX Linux.
#
# Idempotent. No --uninstall (purging LXQt rips out the DE you're using
# right now; recover via a TTY + apt purge if you need to roll back).

set -euo pipefail

dry=0
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,8p' "$0"; echo "Usage: $0 [--dry-run]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
write() { local f=$1; if (( dry )); then printf 'DRY  write %s\n' "$f"; cat >/dev/null
  else mkdir -p "$(dirname "$f")"; cat > "$f"; fi; }

# 1. Packages: LXQt + sddm + brightness control + xcape (for bare-Meta tap).
echo "── packages ──"
run sudo apt update
run sudo apt install -y lxqt sddm brightnessctl xcape

# 2. Albert from the official OBS repo (signed by upstream maintainer).
if ! command -v albert >/dev/null; then
  echo "── albert ──"
  key=/etc/apt/keyrings/albert.gpg
  src=/etc/apt/sources.list.d/albert.list
  url=https://download.opensuse.org/repositories/home:/manuelschneid3r/Debian_13
  run sudo install -d /etc/apt/keyrings
  run bash -c "curl -fsSL '$url/Release.key' | gpg --dearmor | sudo tee '$key' >/dev/null"
  run bash -c "echo 'deb [signed-by=$key] $url/ /' | sudo tee '$src' >/dev/null"
  run sudo apt update
  run sudo apt install -y albert
else
  echo "albert already installed; skipping repo + apt install"
fi

# 3. LXQt session.conf — bilingual keyboard (us + ru, default 'None' variant
#    on both). Meta+Space toggles. CapsLock stays as CapsLock.
echo "── keyboard layout ──"
write "$HOME/.config/lxqt/session.conf" <<'EOF'
[Keyboard]
layout=us,ru
variant=,
options=grp:win_space_toggle
EOF

# 4. Global key shortcuts via lxqt-globalkeysd.
#    F5 → brightness down, F6 → brightness up (raw, not Fn-modified).
#    Alt+Space → Albert. Menu opening is handled by the fancymenu plugin
#    itself (panel.conf below), bound to XF86LaunchA which xcape
#    synthesizes from a bare Meta tap.
echo "── global shortcuts ──"
write "$HOME/.config/lxqt/globalkeyshortcuts.conf" <<'EOF'
[General]
__userfile__=true

[brightness_down]
Comment=Lower brightness (F5)
Enabled=true
Exec=brightnessctl set 5%-
Shortcut=F5
path=/global_actions/brightness_down

[brightness_up]
Comment=Raise brightness (F6)
Enabled=true
Exec=brightnessctl set +5%
Shortcut=F6
path=/global_actions/brightness_up

[albert]
Comment=Albert launcher
Enabled=true
Exec=albert toggle
Shortcut=Alt+space
path=/global_actions/albert
EOF

# 5. xcape autostart: bare Meta tap → XF86LaunchA. Only fires when Super_L
#    is pressed AND released without combining with another key, so it
#    doesn't interfere with normal Super-modifier shortcuts.
echo "── xcape autostart ──"
write "$HOME/.config/autostart/xcape-meta.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=xcape (Meta tap → XF86LaunchA)
Exec=xcape -t 200 -e "Super_L=XF86LaunchA"
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

# 6. LXQt panel: bottom, fancymenu in leftmost slot. Pre-creating panel.conf
#    is honored — LXQt only generates a default if the file is absent.
echo "── panel ──"
write "$HOME/.config/lxqt/panel.conf" <<'EOF'
[General]
__userfile__=true
panels=panel1

[panel1]
alignment=-1
hidable=false
iconSize=22
lineCount=1
lockPanel=false
panelSize=32
plugins=fancymenu, desktopswitch, spacer, taskbar, tray, statusnotifier, volume, clock, showdesktop
position=Bottom
reserve-space=true
width-percent=true
length=100

[fancymenu]
type=fancymenu
shortcut=XF86LaunchA

[desktopswitch]
type=desktopswitch

[spacer]
type=spacer
size=4

[taskbar]
type=taskbar

[tray]
type=tray

[statusnotifier]
type=statusnotifier

[volume]
type=volume

[clock]
type=clock

[showdesktop]
type=showdesktop
EOF

# 7. Albert config: pre-seed Alt+Space hotkey so it's set on first run.
echo "── albert hotkey ──"
write "$HOME/.config/albert/albert.conf" <<'EOF'
[General]
hotkey=Alt+Space
showTray=true
telemetry=false
EOF

write "$HOME/.config/autostart/albert.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Albert launcher
Exec=albert
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

cat <<'EOF'

── done ──
Log out and pick "LXQt" at the SDDM session menu, then log back in.

Quick checks after first LXQt login:
  - Meta+Space toggles us ↔ ru keyboard
  - F5/F6 dim/brighten the screen (no Fn needed)
  - Tap Meta to open the bottom-left Fancy Menu
  - Alt+Space opens Albert
EOF
