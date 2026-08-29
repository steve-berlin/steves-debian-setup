# `nord-rand` explained (ELI11)

A plain-language guide to `nord-job/nord-rand` — the script that moves your VPN
to a different random country every six hours.

## The idea

A VPN sends your traffic through someone else's computer first, so websites see
that computer's location instead of yours. If you always exit in the same
country, that is one steady, recognisable trail.

`nord-rand` picks a country at random from whatever NordVPN currently offers,
connects to it, and writes a line in a log. A cron job runs it four times a day.

## How to use it

```sh
nord-rand              # connect to a random country — but skip if already connected
nord-rand force        # disconnect and reconnect somewhere else, always
nord-rand setup        # one-time configuration; run once after `nordvpn login`
nord-rand kill on      # kill switch on
nord-rand kill off     # kill switch off  ← the escape hatch, see below
```

Everything it does is appended to `~/Desktop/nord-rand.log` with a timestamp.
That file is the only place its output survives, which matters for the cron job.

## Install it

```sh
install -m 755 nord-job/nord-rand ~/.local/bin/
crontab nord-job/nord-rand.cron
```

The cron line is:

```
0 */6 * * * $HOME/.local/bin/nord-rand force >/dev/null 2>&1
```

Read the five stars as *minute, hour, day-of-month, month, day-of-week*. So:
minute 0, every 6th hour, every day — midnight, 06:00, noon, 18:00.

> **`crontab nord-job/nord-rand.cron` replaces your entire crontab**, it does
> not add to it. If you already have cron jobs, run `crontab -l` first and keep
> a copy. And `crontab -r` deletes *all* your cron jobs, not just this one.

## Why cron runs `force` and not the plain command

This is the one genuinely confusing part of the design.

Plain `nord-rand` deliberately does nothing if you are already connected — the
idea being "don't yank a working connection out from under a download".

But `nord-rand setup` turns **autoconnect on**, which means NordVPN reconnects
by itself and you are essentially *always* connected. Under autoconnect, plain
`nord-rand` would find an existing connection every single time and skip
forever. It would never rotate.

So cron runs `force`, which disconnects and reconnects regardless. Typing
`nord-rand` by hand keeps the polite skip. If you would rather have the skipping
behaviour on the schedule too, drop the word `force` from the cron line.

## How the country list works

It asks NordVPN for the list fresh on every run rather than hard-coding one, so
new countries appear on their own and retired ones stop being picked.

The raw output is messy — colour codes, commas, separator dashes, different
formats in different client versions — so `list_countries` scrubs it into one
country per line. Names keep NordVPN's own spelling, underscores and all
(`United_Kingdom`), because that is what the connect command expects.

If a randomly chosen country turns out to be unavailable, it tries again, up to
five times total, then gives up and exits 1. If the list comes back empty it
says so — that almost always means the NordVPN service isn't running or you are
not logged in.

To restrict the pool (say, EU only), filter inside `list_countries`.

## What `setup` turns on

Run it **once**, after `nordvpn login`:

| Setting | What it means |
|---|---|
| `technology NordLynx` | the fast modern protocol (WireGuard-based) |
| `firewall on` | lets NordVPN manage firewall rules |
| `killswitch on` | no VPN, no internet — see the warning below |
| `threatprotectionlite on` | blocks ads/trackers/malicious domains at the DNS level |
| `analytics off` | stop sending usage data to NordVPN |
| `autoconnect on` | reconnect automatically, including at boot |
| `post-quantum on` | tried, ignored if your client is too old to support it |

## The kill switch — read this part

**The kill switch blocks all internet traffic whenever the VPN is not up.** That
is the point of it: no accidental leak while reconnecting. But it means that if
the NordVPN background service dies, or fails to start after an update, **your
machine has no internet at all** and nothing on screen explains why.

Two ways out:

```sh
nord-rand kill off                    # turn the kill switch off
sudo systemctl restart nordvpnd       # or just restart the service
```

Worth remembering *before* you need it, because looking it up requires the
internet you no longer have.

## Before any of this works

Three things the script does not do for you:

1. NordVPN installed and its service running — that's
   [`setup_nordvpn.sh`](setup_nordvpn-eli11.md).
2. Your user in the `nordvpn` group, with a logout/login since.
3. `nordvpn login` run once, interactively. It opens a browser.

## When something goes wrong

Cron has no mailbox on this machine, so a failing job says nothing at all. The
log is the only witness:

```sh
tail ~/Desktop/nord-rand.log
```

| Line you might see | What it means |
|---|---|
| `skip: already connected` | plain mode, VPN already up — expected |
| `try 3/5: Iceland` | a pick failed, it is retrying |
| `fail: 5 attempts exhausted` | five unavailable picks in a row; exits 1 |
| `fail: empty country list` | the service is down, or you are not logged in |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | connected, or skipped because already connected |
| 1 | could not connect (empty list, or five failed attempts) |
| 2 | bad arguments |
