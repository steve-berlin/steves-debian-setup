#!/usr/bin/env bash
# Re-exec under bash if invoked as `sh setup_nordvpn.sh` — uses bashisms.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# setup_nordvpn.sh — put the *right* copy of NordVPN on the machine, and let
# you talk to it.
#
# There are two ways to get NordVPN on Linux, and they are not equal.
#   - Snap is a self-contained app format. The snap build of NordVPN is
#     sandboxed in ways that get in its own way: it can be slow to start, and
#     it has had long-running trouble reaching the system's network settings.
#   - The official .deb comes from NordVPN's own apt repository. It is the
#     build their support actually tests.
# So the job is: if the snap is here, take it off. Put the deb on. Then add
# you to the `nordvpn` group.
#
# That last part is the bit people miss. The NordVPN background service runs
# as root. It only takes commands from members of a group called `nordvpn`.
# If you are not in that group, every command answers with a permission error,
# even though the install worked perfectly.
#
# Usage:
#   bash installers/setup_nordvpn.sh              # install
#   bash installers/setup_nordvpn.sh --dry-run    # print the plan, change nothing
#   bash installers/setup_nordvpn.sh --uninstall  # remove it again
#
# Safe to run twice. If the deb is already installed, it says so and skips the
# installer. If you are already in the group, it says so and skips `usermod`.
#
# What it does NOT do:
#   - Log you in. `nordvpn login` opens a browser and needs your account. This
#     repo never stores credentials.
#   - Connect you, or configure anything. Kill switch, protocol, autoconnect:
#     all of that lives in `nord-rand setup` (see nord-job/nord-rand).
#
# Exit codes:
#   0  installed, already installed, uninstalled, or dry-run finished
#   1  a required tool is missing (sudo; curl too when installing)
#   2  unknown argument
set -euo pipefail

# dry=1 means "print each command instead of running it".
# mode is what to do: install (the default) or uninstall.
# Any argument not listed here is an error and exits with code 2.
dry=0; mode=install
for a in "$@"; do
  case $a in
    --dry-run)   dry=1 ;;
    --uninstall) mode=uninstall ;;
    -h|--help)   echo "Usage: $0 [--dry-run] [--uninstall]"; exit 0 ;;
    *) echo "error: unknown arg: $a" >&2; exit 2 ;;
  esac
done

# run: in dry-run, print "DRY  <command>"; otherwise run the command.
# have: true if the named program is on PATH.
run() { (( dry )) && printf 'DRY  %s\n' "$*" || "$@"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# Step 1: check the tools this mode needs, and stop now rather than
# half-working. sudo is always needed. curl only fetches the installer, so
# --uninstall doesn't ask for it.
need=(sudo)
if [[ $mode == install ]]; then need+=(curl); fi
for c in "${need[@]}"; do
  have "$c" || { echo "missing: $c" >&2; exit 1; }
done

# --uninstall: purge the package, then autoremove its leftover dependencies.
# It does NOT take you out of the nordvpn group, and it does NOT delete
# NordVPN's config folder.
if [[ $mode == uninstall ]]; then
  have nordvpn && { run sudo apt-get purge -y nordvpn; run sudo apt-get autoremove -y; } \
                || echo "nordvpn not installed."
  exit 0
fi

# Step 2: remove the snap version, if there is one. Only happens when `snap`
# exists AND it actually lists nordvpn. On most boxes this does nothing (rare).
have snap && snap list nordvpn >/dev/null 2>&1 && run sudo snap remove nordvpn

# Step 3: run NordVPN's official installer, but only if the deb is not already
# here. This guard matters. The upstream installer is NOT idempotent (running
# it twice does not leave things the same as running it once). Run it twice
# and it adds its apt source entry a second time. Then apt complains about a
# duplicate repository on every future update. So check `dpkg -s nordvpn`
# first and skip the whole thing if the deb is installed.
if have nordvpn && dpkg -s nordvpn >/dev/null 2>&1; then
  echo "nordvpn (deb) already installed — skipping installer."
elif (( dry )); then
  echo "DRY  sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)"
else
  sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
fi

# Step 4: add you to the nordvpn group. Three checks, in order:
#   1. Does the group exist at all? If not, the installer failed: warn.
#   2. Are you already in it? Then there is nothing to do.
#   3. Otherwise, `usermod -aG` adds you (-a = append, keep your other groups).
if ! getent group nordvpn >/dev/null 2>&1; then
  echo "warn: nordvpn group missing — installer may have failed."
elif id -nG "$USER" | tr ' ' '\n' | grep -qx nordvpn; then
  echo "$USER already in nordvpn group."
else
  run sudo usermod -aG nordvpn "$USER"
fi

# The one thing that trips everyone up: a new group does NOT apply to a shell
# that is already open. Linux attaches your groups when you log in, and never
# looks again. So log out and back in, not just close the terminal. Until you
# do, `nordvpn status` keeps refusing you, and it looks exactly like a broken
# install.
echo "Log out/in (for group change), then: nordvpn login && nordvpn connect"
