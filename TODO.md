# TODO

## Next up (ordered)

1. **Backfill the missing `docs/<script>-eli11.md` walkthroughs.** Repo convention says
   every script gets one; 15 of 17 were missing when this list was written.
   ✔ = written. One doc per commit, in install order:
   `utils.sh` ✔ → `check-setup.sh` (157) → `setup_nordvpn.sh` (53) →
   `install-anki.sh` (73) → `install-music-dl.sh` ✔ → `install-mx-frugal.sh` (240) →
   `install-ly.sh` (162) → `check-ly.sh` (242) → `fix-suspend-freeze.sh` (101) →
   `fix-mount.sh` ✔ → `tmux_setup/install-tmux-immortal.sh` (87) →
   `tmux_setup/install-tmux-dim.sh` (97) → `debloat-mx.sh` (85) →
   `debloat-kde.sh` (227) → `debloat-nvidia.sh` (87) → `launchers/nic-boost` (60) →
   `nord-job/nord-rand` (82).

2. **Write a tmux startup speedup script.** `tmux` currently takes ~30 s to reach a
   usable prompt on the T480 — cause not yet profiled. Note the live config is
   `~/.tmux.conf` → `~/steves-cli-setup/tmux/tmux.conf` (sister repo, vendored
   resurrect/continuum, no TPM), so the fix may land in *that* repo while the
   measure/apply script lands here under `installers/tmux_setup/`. First step is
   profiling, not patching: time `tmux -f /dev/null new -d` against the real config
   to separate tmux itself from the config, then bisect the config, then check
   whether `tmux-resurrect`'s restore hook or a shell rc (`~/.zshrc`, oh-my-zsh
   plugin load) owns the wait.

## Done

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
- [] Test streamrip's actual download path. `install-music-dl.sh` is verified as far as it can be without a subscription: config materializes with empty credential fields, `rip url` prompts then aborts cleanly on closed stdin. The fetch/decrypt/tag path has never run — needs a Qobuz, Tidal or Deezer HiFi account.
- [] Decide the `yt-dlp` PATH-shadow fix. Three copies live on the box (apt `/usr/bin/yt-dlp`, an orphaned pip package in `~/.local/lib` with no script, pipx's shim). `~/.local/bin` sorts *after* `/usr/bin`, so apt's wins and `pipx upgrade yt-dlp` changes nothing you run. `install-music-dl.sh` warns but deliberately doesn't fix it — the two options are reordering `PATH` in `~/.zshrc` (not in this repo) or `sudo apt purge yt-dlp`. Pick one; also `pip3 uninstall yt-dlp` to clear the orphan.
- [] Wire YouTube cookies into the music stack. Verified 2026-08-24 that `--impersonate chrome` clears Cloudflare but NOT YouTube's bot gate behind the VPN, which blocks spotdl's audio leg entirely. Options: a cookie export from Firefox for `--cookie-file`/`--cookies-from-browser`, or `nordvpn` off for the duration. Neither is scripted yet.
- [] Boot-test `installers/install-mx-frugal.sh` against a real MX ISO. Only its dry-run, `bash -n`, and `rel_bdir` mountpoint-stripping were verified; the GRUB entry itself has never been booted, so `bdir=`/`buuid=`/`from=all` are correct-per-docs but unproven on this hardware.
