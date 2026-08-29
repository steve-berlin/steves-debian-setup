# `check-ly.sh` explained (ELI11)

A plain-language guide to `installers/check-ly.sh` — a health check for the
login screen, run *before* the login screen breaks.

## Why this exists

When a display manager fails, it fails at the worst possible moment: you are
staring at a black screen or a login box that rejects you, with no terminal to
investigate from. Everything you would want to check is on the other side of the
thing that is broken.

So `check-ly.sh` checks all of it now, while you still have a working desktop.
It reads; it never changes anything. Run it any time.

```sh
bash installers/check-ly.sh
sudo bash installers/check-ly.sh    # also scans the system log — see below
```

## Reading the output

Four kinds of line, and the difference matters:

| Marker | Meaning |
|---|---|
| `[OK]` | fine |
| `[FAIL]` | broken, and it will bite you — this is what sets the exit code |
| `[WARN]` | worth knowing, but not broken. Old log entries, missing optional bits |
| `[--]` | information, not a verdict |

**Warnings never fail the run.** That is deliberate: the log scan reports
problems from the *past*, and seeing an old failure that has since been fixed is
useful, not alarming. Exit code 0 means no `[FAIL]`s.

## What it checks, section by section

### Binary & version

Is `/usr/bin/ly` there and runnable, what version does it report, and does that
match the stamp file `install-ly.sh` left behind. A mismatch means someone
installed Ly another way; not fatal, just worth knowing.

(Small quirk it works around: `ly --version` prints to the error channel rather
than the normal one, so the check has to capture both.)

### Config & setup scripts

`/etc/ly/config.ini` must be readable, and the two scripts Ly uses to actually
launch a session — `xsetup.sh` for X11, `wsetup.sh` for Wayland — must be
executable. If either is not, the login succeeds and then nothing starts.

It also checks the folder for the "save file", which is how Ly remembers which
user and session you picked last. Only the folder's existence matters: Ly runs
as root and writes it as root.

### Config-referenced commands

This is the cleverest part. `config.ini` names other programs by path — the X
server, `xauth`, `mcookie`, the commands to reset the terminal, the shutdown and
restart commands. **If any of those names something that isn't installed, Ly
fails at login with no useful message.**

So the check reads each of those settings and verifies the program is really
there. `sleep_cmd` is treated as optional; the rest are failures.

### Login sessions available

A display manager with nothing to launch is a dead end. It counts the `.desktop`
files in the X11 and Wayland session folders and warns if either is empty.

### systemd service wiring

Four things: `ly.service` exists at all; whether Ly is the *current* default
login screen; whether it is enabled to start at boot; and whether a text login
is also enabled on the console Ly wants (tty2 by default).

That last one is a warning rather than a failure — Ly declares a conflict so
systemd will not run both — but two things competing for one console is exactly
the sort of race worth removing rather than trusting.

### PAM stack

**PAM** is the part of Linux that decides whether a password is accepted. Each
service gets a file listing which modules to consult, and those files can
include one another.

The check follows `/etc/pam.d/ly`, one level into its includes, and confirms two
things: every included file exists, and every module those files reference is
really installed. A module listed here but missing on disk means logins fail
outright.

Lines whose type starts with `-` mark a module as optional — PAM skips it
silently if absent — so those are reported as information, not failures.

If `/etc/pam.d/ly` is missing entirely, PAM falls back to a default that denies
everything, which surfaces as **"Can't authenticate user"**. That gets a
`[FAIL]` with that exact explanation.

### logind / XDG_RUNTIME_DIR

A chain that must hold all the way through, checked link by link: systemd is
running as the main process; `systemd-logind` is active; `libpam-systemd` is
installed and its module is present; and your runtime folder `/run/user/<your
id>` is owned by you.

Why it matters: logging in creates a *session*, the session creates that folder,
and the desktop puts its communication sockets in it. Break any link and you get
"Can't open Wayland socket" — which looks like a graphics problem and is not.

If that folder doesn't exist right now, that's a warning, not a failure: it is
created at login and removed when your last session ends.

### Suspend/resume freeze fix

Checks whether the fix from
[`fix-suspend-freeze.sh`](fix-suspend-freeze-eli11.md) is in place on all four
sleep services, so the "login crashes after waking from sleep" bug can be ruled
in or out without reproducing it.

On systemd older than 256 the bug doesn't exist and it says so instead.

### Journal scan

The system log is the only record of a failure that happened while you had no
desktop. This section counts, over the last 30 days:

- session-scope freeze errors (the suspend bug)
- failures to create a session
- Wayland socket and lockfile errors
- password authentication failures
- Ly actually crashing

Each gets a count and the date of the most recent one. All of these are
**warnings by design** — they describe the past. Seeing "3 hits, newest ~two
weeks ago" right after you applied a fix is how you confirm the fix worked.

**Reading the system log needs permission.** The script tries three ways in
order: passwordless sudo, membership in the `adm` or `systemd-journal` group, or
asking you for a sudo password if you're at a terminal. If none works it skips
the section with a warning telling you to re-run with `sudo`.

One deliberate exclusion: a display manager being stopped normally logs a
`status=15` termination. That is a clean shutdown, not a crash, so the check
only counts core dumps and kills.

### Build headers

Last and least: the two development packages needed to *rebuild* Ly. Missing
ones are warnings — you only need them for `install-ly.sh --reinstall`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | no failures (warnings are fine) |
| 1 | at least one `[FAIL]` |

The totals line at the end gives all three counts.
