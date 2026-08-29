# `fix-suspend-freeze.sh` explained (ELI11)

A plain-language guide to `installers/fix-suspend-freeze.sh` — the fix for
logins that crash right after the laptop wakes up.

## The symptom

You close the lid, open it later, type your password — and instead of a desktop
you get thrown back to the login screen, often with **"Can't authenticate
user"**. Try again straight away and it usually works. It feels random, which is
the worst kind of bug.

It is not random, and your password is fine.

## What is actually happening

When a modern Linux puts itself to sleep, systemd (the program that starts and
supervises everything else) **freezes** all your programs first. Freezing means
"stop, stay exactly as you are" — it prevents things from half-running while the
hardware is powering down. On wake-up, it unfreezes them.

That thaw takes a moment. And in that moment the login screen is already
accepting your password.

So the login goes through, and then the piece that is supposed to create your
new **session** cannot, because the container it must create the session inside
is still frozen:

```
systemd[1]: Cannot start frozen unit session-N.scope
ly[…]: pam_systemd(ly:session): Failed to create session:
       Job NNNN for unit 'session-N.scope' failed with 'frozen'
```

From there it topples over in sequence: no session means no `/run/user/<your
id>` folder, which is where the desktop keeps its sockets — so the desktop dies
with "Can't open Wayland socket" or "Unable to open lockfile", and the login
screen reports the only thing it can see, which is that the login failed.

You only hit it when your login lands inside that thaw window. Hence
"crashes every few logins".

**This is not a bug in your login screen.** It affects Ly, and it affects a
plain text-console login too. It arrived with systemd version 256.

## The fix

systemd has a documented switch that says "don't freeze user sessions when
sleeping": `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false`.

If nothing is ever frozen, there is no thaw, and no race to lose.

The script writes that setting into a small **drop-in** file — an add-on config
that overrides one setting of a service without editing the service itself — for
all four ways the machine can sleep:

- `systemd-suspend` (sleep to RAM)
- `systemd-hibernate` (sleep to disk)
- `systemd-hybrid-sleep` (both at once)
- `systemd-suspend-then-hibernate` (sleep now, hibernate later)

All four, because otherwise the bug would come back the day you hibernate
instead of suspending.

## How to use it

```sh
bash installers/fix-suspend-freeze.sh              # apply
bash installers/fix-suspend-freeze.sh --dry-run    # print the plan, change nothing
bash installers/fix-suspend-freeze.sh --uninstall  # undo
```

`--reinstall` exists and is identical to a plain run — writing the same file
twice changes nothing. It is there so every installer in this repo takes the
same flags.

**No reboot needed.** It reloads systemd's configuration and the setting applies
to the next suspend.

## Why it checks your systemd version so carefully

The setting only exists in systemd 256 and newer. On an older systemd the
drop-in would be written successfully, be completely ignored, and your logins
would keep crashing while everything looked correctly configured.

So the script does something slightly unusual: it searches the actual
`systemd-sleep` program on disk for the setting's name. If the name isn't in
there, this systemd doesn't know the setting, and the script stops and tells you
rather than leaving you with a silent no-op.

(Under `--dry-run` that check downgrades to a warning, so you can still see the
plan on a machine you haven't finished setting up.)

## Is it safe to turn the freezing off?

The freeze exists to stop programs from racing the hardware while it powers
down. Skipping it is a documented, supported option, and on a laptop the
practical effect is nil — programs already have to cope with time jumping
forward across a suspend.

You are trading a theoretical race during suspend for a real one you are hitting
on resume.

## Checking that it worked

```sh
systemctl show systemd-suspend.service -p Environment
```

should mention `SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=false`. Then suspend, wake
up, and look at the log:

```sh
journalctl -b | grep -i 'unfrozen\|frozen'
```

You want to see `User sessions remain unfrozen on explicit request`, and no new
`'frozen'` errors.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | applied, removed, or dry-run finished |
| 1 | not a systemd machine, no `sudo`, or systemd too old |
| 2 | unknown argument |
