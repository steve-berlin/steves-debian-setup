# nord-job — random NordVPN country rotation

## Files

- `~/.local/bin/nord-rand` — the script (chmod +x, NordLynx, kill switch, threat protection, autoconnect baked into `setup` mode)
- `nord-rand.cron` (this dir) — crontab snippet, installed via `crontab nord-rand.cron`
- `~/Desktop/nord-rand.log` — every action timestamped (ISO-8601), append-only, no rotation
- `/media/fred/8B35-3F46/nord-rand` and `nord-rand.cron` — backup copies on SD card (FAT/exFAT drops the +x bit; `chmod +x` after copy back)

## Modes

- `nord-rand` — pick a random country from whatever `nordvpn countries` returns; **skip if already connected**
- `nord-rand force` — same, but disconnect-and-reconnect even when connected. **This is what cron runs.**
- `nord-rand setup` — one-time NordVPN config. Requires prior `nordvpn login`. Disconnects, sets technology + protections, enables autoconnect, tries `post-quantum` (ignored on older clients).
- `nord-rand kill on|off` — toggle kill switch. `off` is the escape hatch when you need plain internet.

## Cron

`0 */6 * * * /home/fred/.local/bin/nord-rand force >/dev/null 2>&1` — every 6 hours (00, 06, 12, 18). Output silenced because the script logs internally.

## The autoconnect ↔ option-B conflict

User picked "skip if already connected" (option B) but also enabled NordVPN's autoconnect. Autoconnect keeps the VPN up 24/7, so plain `nord-rand` would never rotate. Resolution: cron uses `force`; manual invocations still default to soft skip. To revert to literal option B, drop the word `force` from the cron line — `crontab -e`.

## Country list

Pulled live from `nordvpn countries` at every invocation — no hardcoded array. `list_countries()` strips ANSI colour codes, normalises whitespace/commas to one country per line, and drops separator dashes; the CLI's own naming (underscores for spaces, e.g. `United_Kingdom`) is preserved. Retry loop tolerates up to `MAX_TRIES` (5) unavailable picks. To restrict the pool (e.g. EU-only), pipe through an `awk`/`grep` filter inside `list_countries`.

## Prereqs not handled by the script

- `nordvpn` daemon installed and user in the `nordvpn` group
- `nordvpn login` run interactively at least once (browser flow)
- `nord-rand setup` run once after login

## Failure modes worth knowing

- Kill switch ON + VPN daemon dead/crashed → no internet at all. Recover with `nord-rand kill off` or `sudo systemctl restart nordvpnd`.
- 5 connect attempts all hit unavailable countries → script exits 1, log shows `fail: MAX_TRIES attempts exhausted`. Re-run, or narrow the pool by filtering inside `list_countries`.
- Cron silently dropping mail because no MTA: expected. All visibility is in `~/Desktop/nord-rand.log`.
