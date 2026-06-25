# TODO

- [x] Write an installer for the **Ly** display manager. Install Ly and offer to
      make it the default DM via a y/n prompt (only switch on confirmation).
      → `installers/install-ly.sh` (builds from source via pinned Zig + Ly tag;
      y/N default-DM prompt with `--default`/`--no-default` overrides;
      pinned Ly 1.0.3 + Zig 0.13.0).
- [x] Shorten all non-discontinued scripts (keep `installers/discontinued/`
      as-is). Tightened without dropping behavior; still follows repo
      conventions (verified with `bash -n` across all 13).
- [x] `utils.sh`: before anything else, offer (y/N) to delete the
      `installers/discontinued/` scripts. Non-interactive / `--dry-run` keeps
      them. → new **step 0** in `installers/utils.sh`.
