# TODO

- [x] Shorten all non-discontinued scripts (keep `installers/discontinued/`
      as-is). Tightened without dropping behavior; still follows repo
      conventions (verified with `bash -n` across all 13).
- [x] `utils.sh`: before anything else, offer (y/N) to delete the
      `installers/discontinued/` scripts. Non-interactive / `--dry-run` keeps
      them. → new **step 0** in `installers/utils.sh`.
