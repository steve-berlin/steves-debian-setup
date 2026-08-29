# `debloat-kde.sh` explained (ELI11)

A plain-language guide to `debloat_scripts/debloat-kde.sh` — it strips a
Debian/MX **KDE Plasma** desktop down to the parts you actually use.

This is the largest and most dangerous of the three debloat scripts. It is worth
reading the whole page before running it.

## How to use it

```sh
bash debloat_scripts/debloat-kde.sh --dry-run        # read this output first
bash debloat_scripts/debloat-kde.sh
bash debloat_scripts/debloat-kde.sh --no-bluetooth   # also remove Bluetooth
```

Then reboot.

There is **no `--uninstall`.** Bringing something back is `sudo apt install
<name>`; there is no single "undo" because the script does several unrelated
kinds of thing.

It refuses to run unless `plasma-desktop` is installed — that is the real
package (`kde-plasma-desktop` is only a pointer to it), and its absence means
you're on the wrong machine.

## The part that makes it safe

Before removing anything, the script does something that looks unrelated and is
the single most important step in the file:

```
── protecting core KDE from autoremove cascade ──
```

Here is the problem it solves. Linux package managers track *why* a package is
installed: because **you** asked for it ("manual"), or because something else
needed it ("automatic"). `apt autoremove` deletes everything automatic that
nothing needs any more.

KDE ships **meta-packages** — packages that install nothing themselves and exist
only to pull in a group of others. Remove a meta-package, and everything it
pulled in becomes automatic and unreferenced. If some genuinely load-bearing
piece of your desktop was only ever pulled in by that meta, the final
`autoremove` takes it out too.

That is how you end up removing a games bundle and losing your desktop at the
next login. Prior versions of this script did exactly that.

The fix: mark every load-bearing piece **manual** first — the Plasma desktop and
workspace, KWin (the window manager), SDDM (the login screen), System Settings,
Dolphin, Konsole, the network and audio applets, the screen locker, the Breeze
theme, and so on. Marked manual, they are no longer "just a leftover" and
`autoremove` won't touch them.

It only marks packages that are actually installed, it is safe to run twice, and
it is reversible with `apt-mark auto <name>`.

## What it removes

Eleven groups. In outline:

1. **Legacy KDE apps and the whole PIM suite** — Konqueror, Akregator, KMail,
   KOrganizer, KAddressBook, Kontact, Kleopatra, KGpg, KWrite, xterm, three
   media players, GoldenDict, the Debian reference and KHelpCenter.
2. **GIMP.**
3. **Non-Latin input methods** — fcitx, fcitx5, mozc, anthy, ibus and a Thai
   terminal. These matter if you type Japanese, Chinese, Korean or Thai. **If
   you do, edit this group out before running.**
4. **KDE games** — the meta *and* all ~40 individual games. Both, because
   removing only the individual games lets autoremove pull them back later.
5. **KDE educational software** — same pattern, meta plus contents.
6. **Duplicate small utilities** — each has a better modern equivalent.
7. **The Akonadi stack.** This one is worth its own paragraph, below.
8. **Plasma "addons"** — extra widgets, extra KRunner search plugins, extra
   wallpapers, extra background data engines. The panel, desktop and window
   manager are untouched; this only slims the widget picker and stops some
   background daemons.
9. **Services you probably don't use** — KDE Connect, remote desktop client and
   server, Plasma Vault, a hex editor, a font viewer, a disk-usage tool, log
   viewer, debug settings.
10. **Cosmetic packs** — the wallpaper collection, and the legacy Oxygen icon
    and sound themes (Breeze is the default now).
11. **Debian documentation cruft.**

`--no-bluetooth` adds the whole Bluetooth stack to the list. It is off by
default, since most laptops want it.

### Why Akonadi needs an explicit mention

Akonadi is the background service behind KDE's mail, calendar and contacts. It
stores its data in a **real database server** — MariaDB — which it pulls in as a
"recommended" package.

Recommended packages are not removed by autoremove. So removing KMail and
friends leaves an entire database server installed and running, serving data
nobody reads. The script names `mariadb-server` explicitly for that reason.

## The language filter

KDE, Firefox, Thunderbird, spell checkers and manual pages all ship
per-language packages, and a default install carries dozens you can't read.

The script lists every installed language package, keeps English and German
(plus the base English manual pages), and removes the rest. Then it rewrites the
system's locale list to `en_US.UTF-8` and `de_DE.UTF-8` and regenerates it.

**If you read other languages, change the filter before running.** The rule is
in one short `case` block near the middle of the script.

**Keyboard layouts are not touched.** Removing a Russian *language pack* does
not remove the Russian *keyboard layout* — those are separate, and the layouts
(`xkb-data`) are deliberately left alone.

## Two settings changes it makes

**Baloo, the file indexer, is switched off.** Baloo watches your files so search
results are instant. It also reads a lot of disk, continuously. The script
disables the background service but does *not* remove it, because KDE
applications are compiled against its libraries — removing it would break them.

**Three Plasma settings are adjusted**, per user:

| Setting | Change | Why |
|---|---|---|
| `loginMode` | `emptySession` | don't reopen last session's apps at login — saves 50–100 MB and a slow login |
| `AnimationDurationFactor` | `0` | turn off desktop animations; the desktop feels quicker |
| Dolphin preview plugins | image formats only | stop the file manager launching video/PDF/audio helpers just to browse a folder |

That last one is only written **if you have never set it yourself**. An earlier
version wrote it unconditionally and wiped people's own choices on every re-run.

> **Run this script as your normal user, never with `sudo`.** Those three
> settings are per-user files. Under `sudo` they would be written into root's
> configuration and do nothing for you. The script calls `sudo` itself for the
> parts that need it.

## What it installs

Three small things, because they're the KDE-native way to do something you'll
want: the Flatpak backend for Discover (so the app store can install flatpaks),
its settings module, and the Plymouth boot-splash settings module.

Each is checked for availability first — MX's repositories are slimmer than
Debian's, and a missing package would otherwise abort the whole run.

## Afterwards

Reboot. Akonadi and Baloo daemons keep running in your current session even
after their packages are gone, so the memory doesn't come back until you restart.

To restore anything: `sudo apt install <name>`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | finished, nothing to remove, or dry-run finished |
| 1 | Plasma isn't installed, or a required tool is missing |
| 2 | unknown argument |
