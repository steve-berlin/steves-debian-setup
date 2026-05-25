# steves_debian_setup

Personal Debian/MX Linux XFCE setup scripts: bulk bootstrap, post-install
verifier, and small installers for Steam, The Long Dark, Anki, scrcpy,
NIC tuning, plus tmux power-ups and DE debloaters. Launcher wrappers
apply a gaming perf profile (`stm`, `rbx`, `rbxvm`, `redmi-gaming`) or
opt-in WiFi/EEE bandwidth boost (`nic-boost`).

Targeted at a ThinkPad T480 (Intel UHD 620, x86_64, Liquorix kernel,
X11). Most scripts degrade to a warning rather than hard-failing on
other hardware/distros, so they remain usable elsewhere with light
edits.

## Quick start (fresh box)

```sh
git clone https://github.com/steve-berlin/steves-debian-setup ~/steves_debian_setup
cd ~/steves_debian_setup

# 1. bulk bootstrap (apt + toolchains + oh-my-zsh + nvim-config seed)
bash installers/utils.sh

# 2. verify
bash installers/check-setup.sh

# 3. game/app installers — pick what you want
bash installers/gaming/install-steam.sh
bash installers/gaming/install-tld.sh             # The Long Dark (needs stm + Steam)
bash installers/gaming/install-scrcpy.sh          # upstream scrcpy under /usr/local
bash installers/install-anki.sh
bash installers/gaming/install-nic-tuning.sh      # permanent NIC tuning + deploys nic-boost

# 4. debloaters (each opt-in)
bash debloat_scripts/debloat-mx.sh                # strip MX-bundled apps
bash debloat_scripts/debloat-nvidia.sh            # purge nvidia/nouveau (Intel-iGPU boxes only)
bash debloat_scripts/debloat-kde.sh               # post-install KDE Plasma debloat
bash debloat_scripts/debloat-redmi.sh             # disable LineageOS bloat on a Redmi 4A (ADB)

# 5. tmux stack (each independent)
bash installers/tmux_setup/install-tmux-immortal.sh   # tpm + resurrect + continuum
bash installers/tmux_setup/install-tmux-expose.sh     # Mission-Control-style session switcher
bash installers/tmux_setup/install-tmux-dim.sh        # patched tmux 3.5a w/ inactive-pane dim

# 6. optional: random NordVPN country rotation every 6h
bash installers/setup_nordvpn.sh                  # replace snap with official deb
install -m 755 nord-job/nord-rand ~/.local/bin/
crontab nord-job/nord-rand.cron                   # see CLAUDE.md "nord-job/" section

# 7. drop launchers and autostarts in place
install -m 755 launchers/stm launchers/rbx launchers/rbxvm launchers/redmi-gaming launchers/nic-boost ~/.local/bin/
cp autostarts/*.desktop ~/.config/autostart/

# Discontinued (kept for institutional knowledge — see CLAUDE.md):
#   installers/discontinued/install-roblox.sh, check-roblox-prereqs.sh,
#   install-lineage.sh, install-lxqt.sh, debloat-xfce.sh
```

Every installer supports `--dry-run` (prints actions, mutates nothing)
and is idempotent. See `CLAUDE.md` for layout, conventions, and the
per-script details.

## Repo layout

```
installers/                 utils.sh, check-setup.sh, install-anki.sh, setup_nordvpn.sh
  gaming/                   install-steam.sh, install-tld.sh, install-scrcpy.sh, install-nic-tuning.sh
  tmux_setup/               install-tmux-immortal.sh / -expose.sh / -dim.sh
  patches/                  vendored upstream patches (tmux dim)
  discontinued/             scripts no longer on the default install path
debloat_scripts/            debloat-mx.sh / -kde.sh / -nvidia.sh / -redmi.sh
launchers/                  stm, rbx, rbxvm, redmi-gaming, nic-boost
lineage_vm/                 deployed-state docs for the Roblox-on-Android-x86 VM
nord-job/                   nord-rand script + 6-hourly crontab snippet
autostarts/                 *.desktop for ~/.config/autostart
nvim-config/                vendored LazyVim starter (utils.sh seeds ~/.config/nvim from this)
backup.zshrc                reference copy of ~/.zshrc (do not source as-is)
CLAUDE.md                   single consolidated orientation doc for Claude Code
```

## Conventions

- `set -euo pipefail` everywhere, with a `[ -z "${BASH_VERSION:-}" ]`
  re-exec guard so `sh installers/foo.sh` doesn't trip dash on bashisms.
- `--dry-run` is universal and combinable with mode flags.
- Idempotent: re-running on an already-installed box is a no-op.
- No credentials, no scraping behind logins.
- Sudo is called inline; nothing re-execs itself as root.
- Track multi-step work in real time via the Claude Code task tools
  (TaskCreate / TaskUpdate) — see `CLAUDE.md` Conventions for detail.

## License

[GNU AGPLv3](LICENSE). Forks and modifications must remain under AGPLv3
with source available. No warranty.
