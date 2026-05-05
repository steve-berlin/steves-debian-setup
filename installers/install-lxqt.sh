sudo apt update && sudo apt full-upgrade -y
sudo apt install lxqt sddm -y
sudo apt update
x= sudo apt list --upgradable
if [[ "$x" -n  ]]; then
  sudo apt full-upgrade -y
fi
