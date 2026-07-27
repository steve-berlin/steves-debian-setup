# TODO

- [x] Add `atmel-firmware` uninstall (with hardware detection to not delete necessary drivers by accident) to `utils.sh`
- [x] Add `dash` uninstall to `utils.sh`
- [x] ~~Implement `https://github.com/gpakosz/.tmux` to current TMUX setup.~~ Reverted — omt installer + vendored `tmux-config/` cut entirely.
- [x] Organize scripts/tools from `unsorted/`, rewriting them if needed.
- [x] Add Zathura (use MuPDF if you know I won't have issues with it, install `zathura-djvu` alongside) and NCDU install to `utils.sh`.
- [x] Add EarTag install and Foliate uninstall to `utils.sh`

## Open — deployed box still out of sync with the repo

The omt/expose removals landed in the repo only; this T480 still runs the old setup.

- [] Revert live tmux config off oh-my-tmux: `~/.tmux.conf` is still a symlink to `~/.tmux/.tmux.conf` (gpakosz engine). Replace with a real file matching `backup.tmux.conf`, then delete `~/.tmux/.tmux.conf` + `~/.tmux.conf.local`.
- [] `cargo uninstall tmux-expose` — the binary is still at `~/.cargo/bin/tmux-expose` after `install-tmux-expose.sh` was dropped.
- [] Boot-test `installers/install-mx-frugal.sh` against a real MX ISO. Only its dry-run, `bash -n`, and `rel_bdir` mountpoint-stripping were verified; the GRUB entry itself has never been booted, so `bdir=`/`buuid=`/`from=all` are correct-per-docs but unproven on this hardware.
