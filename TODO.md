# TODO

- [x] Add `atmel-firmware` uninstall (with hardware detection to not delete necessary drivers by accident) to `utils.sh`
- [x] ~~Add `dash` uninstall to `utils.sh`~~ Reverted — step 1d removed. `dash` owns `/bin/sh` on trixie, so the purge deletes `/bin/sh` mid-run and then can't exec its own `#!/bin/sh` postrm; it wedged `dash` half-installed and took `/bin/sh` out on 2026-08-02. Not fixable by reordering. See `CLAUDE.md` steps 1c/1d/1e.
- [x] ~~Implement `https://github.com/gpakosz/.tmux` to current TMUX setup.~~ Reverted — omt installer + vendored `tmux-config/` cut entirely.
- [x] Organize scripts/tools from `unsorted/`, rewriting them if needed.
- [x] Add Zathura (use MuPDF if you know I won't have issues with it, install `zathura-djvu` alongside) and NCDU install to `utils.sh`. — MuPDF *backend* turned out not to exist: Debian trixie ships no `zathura-pdf-mupdf`/`zathura-mupdf`, only the `mupdf` engine. Settled on `zathura-pdf-poppler` + `zathura-djvu` + the standalone `mupdf` viewer for EPUB.
- [x] Add EarTag install and Foliate uninstall to `utils.sh`

## Open

Verified on 2026-08-23: the tmux and `/bin/sh` items below all landed on the deployed T480.

- [x] ~~Revert live tmux config off oh-my-tmux~~ — done, though not as planned: `~/.tmux.conf` now symlinks to `~/steves-cli-setup/tmux/tmux.conf` (its own repo, vendored resurrect/continuum, no TPM) rather than a real file matching `backup.tmux.conf`. `~/.tmux/` is gone. `backup.tmux.conf` is therefore stale — see `CLAUDE.md` → `installers/tmux_setup/`.
- [x] ~~`cargo uninstall tmux-expose`~~ — binary no longer in `~/.cargo/bin/`.
- [x] ~~Repair `/bin/sh` on this T480~~ — `/bin/sh -> dash`, `dpkg -l dash` reads `ii`, no packages left half-configured.
- [] Boot-test `installers/install-mx-frugal.sh` against a real MX ISO. Only its dry-run, `bash -n`, and `rel_bdir` mountpoint-stripping were verified; the GRUB entry itself has never been booted, so `bdir=`/`buuid=`/`from=all` are correct-per-docs but unproven on this hardware.
