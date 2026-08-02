# TODO

- [x] Add `atmel-firmware` uninstall (with hardware detection to not delete necessary drivers by accident) to `utils.sh`
- [x] ~~Add `dash` uninstall to `utils.sh`~~ Reverted — step 1d removed. `dash` owns `/bin/sh` on trixie, so the purge deletes `/bin/sh` mid-run and then can't exec its own `#!/bin/sh` postrm; it wedged `dash` half-installed and took `/bin/sh` out on 2026-08-02. Not fixable by reordering. See `CLAUDE.md` steps 1c/1d/1e.
- [x] ~~Implement `https://github.com/gpakosz/.tmux` to current TMUX setup.~~ Reverted — omt installer + vendored `tmux-config/` cut entirely.
- [x] Organize scripts/tools from `unsorted/`, rewriting them if needed.
- [x] Add Zathura (use MuPDF if you know I won't have issues with it, install `zathura-djvu` alongside) and NCDU install to `utils.sh`. — MuPDF *backend* turned out not to exist: Debian trixie ships no `zathura-pdf-mupdf`/`zathura-mupdf`, only the `mupdf` engine. Settled on `zathura-pdf-poppler` + `zathura-djvu` + the standalone `mupdf` viewer for EPUB.
- [x] Add EarTag install and Foliate uninstall to `utils.sh`

## Open — deployed box still out of sync with the repo

The omt/expose removals landed in the repo only; this T480 still runs the old setup.

- [] Revert live tmux config off oh-my-tmux: `~/.tmux.conf` is still a symlink to `~/.tmux/.tmux.conf` (gpakosz engine). Replace with a real file matching `backup.tmux.conf`, then delete `~/.tmux/.tmux.conf` + `~/.tmux.conf.local`.
- [] `cargo uninstall tmux-expose` — the binary is still at `~/.cargo/bin/tmux-expose` after `install-tmux-expose.sh` was dropped.
- [] **Repair `/bin/sh` on this T480** — the 2026-08-02 `utils.sh` run left `/bin/sh` deleted, `dash` `iH` half-installed, and triggers pending on `debianutils`/`man-db`/`menu`. Every `#!/bin/sh` script (all dpkg maintainer scripts included) fails until fixed: `sudo ln -sf /usr/bin/bash /bin/sh`; `echo "dash dash/sh boolean true" | sudo debconf-set-selections`; `sudo apt-get install -y --reinstall dash`; `sudo dpkg --configure -a`. Verify `dpkg -l dash` reads `ii`.
- [] Boot-test `installers/install-mx-frugal.sh` against a real MX ISO. Only its dry-run, `bash -n`, and `rel_bdir` mountpoint-stripping were verified; the GRUB entry itself has never been booted, so `bdir=`/`buuid=`/`from=all` are correct-per-docs but unproven on this hardware.
