# TODO

## Next up (ordered)

1. ~~**Backfill the missing `docs/<script>-eli11.md` walkthroughs.**~~ Done
   2026-08-29. All 17 scripts now have one: `utils`, `check-setup`,
   `setup_nordvpn`, `install-anki`, `install-music-dl`, `install-mx-frugal`,
   `install-ly`, `check-ly`, `fix-suspend-freeze`, `fix-mount`,
   `install-tmux-immortal`, `install-tmux-dim`, `debloat-mx`, `debloat-kde`,
   `debloat-nvidia`, `nic-boost`, `nord-rand`. Keep them in sync when a script
   changes — that is the repo convention, not a one-off.

2. ~~**Write a tmux startup speedup script.**~~ Done 2026-09-05, scoped to
   measure-only: `installers/tmux_setup/profile-tmux-startup.sh` +
   `docs/profile-tmux-startup-eli11.md`. It reports and advises; it changes
   nothing. Profiled result on the T480 — tmux itself is not the problem:

   | stage | cost |
   |---|---|
   | bare `tmux -f /dev/null` | 96 ms |
   | + config parsed, `run-shell` stripped | 134 ms |
   | + plugins loaded | 1137 ms |
   | `zsh -f -i` (no rc, the floor) | 16 ms |
   | `zsh -i` (real rc) | 1836 ms |
   | restore sleeps (computed) | 4300 ms |

   **Eager `nvm.sh` in `~/.zshrc.local` is ~1530 ms of that shell time, paid
   once per pane** — 5 panes ≈ 9 s, roughly two thirds of the wait. Remaining
   work is the fix itself, below.

3. ~~**Lazy-load nvm in `~/.zshrc.local`.**~~ Done 2026-09-05. Newest installed
   version's bin goes straight on `PATH` (so `node`/`npm`/`npx`/`corepack` are
   plain binaries), and `nvm.sh` is deferred behind an `nvm()` stub that
   `unfunction`s itself on first call. **Shell start 1836 ms -> 296 ms**, paid
   per pane. nvm no longer appears in the profiler's top offenders; `rbenv init`
   (73 ms) is now the largest, not worth chasing yet. Trade-off accepted: no
   `.nvmrc` auto-switch on `cd`, and "newest installed" wins over the `default`
   alias — both moot with one version installed.

   Still unresolved from this item: **`~/.zshrc.local` lives in no repo.** It is
   155 lines of real config (`PATH`, completions, all five toolchains, atuin,
   aliases) and one disk failure from gone. `backup.zshrc` here is a stripped
   copy of the *pre-symlink* `~/.zshrc` — a different file, and stale. Options:
   leave untracked; track it in `steves-cli-setup` as `zsh/local/t480.zshrc`
   with `~/.zshrc.local` symlinking to it (preferred); or refresh the stripped
   copy here. No longer blocked — the `GH_TOKEN` that made it uncommittable was
   removed and revoked on 2026-09-05.

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
