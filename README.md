# steves_debian_setup

Personal Debian/MX Linux XFCE setup scripts: bulk bootstrap, post-install
verifier, and small installers for Steam, The Long Dark, Anki, Roblox
(via Waydroid), and NIC tuning. Plus launcher wrappers — `stm`, `rbx`
for the gaming perf profile, and `nic-boost` for opt-in WiFi/EEE
bandwidth boosts.

Targeted at a ThinkPad T480 (Intel UHD 620, x86_64, Liquorix kernel,
X11). Most scripts degrade to a warning rather than hard-failing on
other hardware/distros, so they remain usable elsewhere with light
edits.

## Quick start (fresh box)

```sh
git clone https://github.com/steve-berlin/steves-debian-setup ~/steves_debian_setup
cd ~/steves_debian_setup

# 1. bulk bootstrap (apt + toolchains + oh-my-zsh + debloat)
bash installers/utils.sh

# 2. verify
bash installers/check-setup.sh

# 3. game/app installers — pick what you want
bash installers/install-steam.sh
bash installers/install-tld.sh             # The Long Dark (needs stm + Steam)
bash installers/install-anki.sh
bash installers/check-roblox-prereqs.sh    # gate before the big install
bash installers/install-roblox.sh          # interactive, prompts per step

# 4. networking polish (permanent, zero power cost) — also deploys nic-boost
bash installers/install-nic-tuning.sh

# 5. optional: persist tmux sessions across reboots (tpm + resurrect + continuum)
bash installers/install-tmux-immortal.sh

# 6. drop launchers and autostarts in place
install -m 755 launchers/stm launchers/rbx ~/.local/bin/
cp autostarts/*.desktop ~/.config/autostart/
```

Every installer supports `--dry-run` (prints actions, mutates nothing)
and is idempotent. See `CLAUDE.md` for layout, conventions, and the
per-script details.

## Repo layout

```
installers/    install-*.sh, utils.sh, check-setup.sh, check-roblox-prereqs.sh
launchers/     stm (Steam), rbx (Roblox/Waydroid), nic-boost (NIC perf)
autostarts/    *.desktop for ~/.config/autostart
backup.zshrc   reference copy of ~/.zshrc (do not source as-is)
CLAUDE.md      orientation map for Claude Code
```

`installers/`, `launchers/`, and `autostarts/` each have their own
`CLAUDE.md` with per-file detail.

## Conventions

- `set -euo pipefail` everywhere.
- `--dry-run` is universal and combinable with mode flags.
- Idempotent: re-running on an already-installed box is a no-op.
- No credentials, no scraping behind logins.
- Sudo is called inline; nothing re-execs itself as root.

## License

[GNU AGPLv3](LICENSE). Forks and modifications must remain under AGPLv3
with source available. No warranty.
