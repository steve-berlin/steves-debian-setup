#!/usr/bin/env bash
set -e
sudo snap remove nordvpn 2>/dev/null || true
sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
sudo usermod -aG nordvpn "$USER"
echo "Log out/in, then: nordvpn login && nordvpn connect"
