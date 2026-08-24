# `install-music-dl.sh` explained (ELI11)

A plain-language guide to `installers/install-music-dl.sh` — what it puts on
the box, why each tool is separate, and which parts need you to pay for
something first.

## What it installs

Three command-line programs that turn a web link into audio files on disk:

| Command | Where it downloads from | What you need |
|---|---|---|
| `rip` (streamrip) | Qobuz, Tidal, Deezer, SoundCloud | your own paid account |
| `spotdl` | Spotify playlists and albums | nothing |
| `yt-dlp` | YouTube, SoundCloud, Bandcamp, ~1800 sites | nothing |

Plus two supporting packages from apt: `pipx` (explained below) and `ffmpeg`
(the program that converts audio between formats — without it you get raw
streams instead of playable FLAC or MP3 files).

## What `pipx` is, and why not plain `pip`

These three tools are written in Python. Python programs depend on *libraries* —
prewritten chunks of code. The problem: two programs often want **different
versions of the same library**, and if you install both the normal way (`pip`),
they share one pile of libraries and fight over it. One wins, the other breaks.

`pipx` fixes that by giving each program its own private sandbox (a
"virtual environment") with its own private copy of every library it needs.

This is not a theoretical worry here. streamrip and spotdl share 16 libraries,
and they disagree about one of them: a picture-handling library called `pillow`.
streamrip wants version 10.4.0, spotdl wants 12.3.0. Installed the old shared
way, whichever one you installed second would overwrite the other's copy and
quietly break it. With pipx they each keep their own and never notice.

This repo already got bitten by exactly this problem: `utils.sh` step 9b had to
put `yewtube` on a separate `pip` line, because `yewtube` demands an old version
of a library called `httpx` and would have dragged `yt-dlp`, `tldr` and
`platformio` down with it. pipx makes that whole class of problem go away.

## The confusing bit: how spotdl handles Spotify

Spotify does not let programs download its audio. So `spotdl` does a two-step
trick:

1. It asks Spotify's **public information service** what is in your playlist —
   song titles, artists, album art, track order. That is just a list. No audio.
2. It then searches **YouTube** for each of those songs and downloads the audio
   from there.

So the *playlist* comes from Spotify and the *sound* comes from YouTube. You do
not need a Spotify account, and nothing is taken from Spotify but the list.

## The bit that needs your own subscription

`rip` (streamrip) is the only one that reaches real lossless audio — FLAC files
that are bit-for-bit identical to the CD, rather than squashed-down MP3. It gets
there by logging in **as you**, with your own account, and asking for the same
stream the official app would play.

That means:

- **Tidal and Qobuz**: you need a paid plan with lossless included. No plan,
  no lossless.
- **Deezer**: the free tier only serves 128kbps MP3. Lossless needs Deezer HiFi.
- **SoundCloud**: open, no account needed.

The script deliberately writes **no** login details. That is a rule for this
whole repo — no credentials ever go into git, because the repo is public. You
add yours by hand, once:

```sh
rip config open
```

That opens `~/.config/streamrip/config.toml` in your editor. Fill in the
service you actually subscribe to and save.

## How to use it

```sh
installers/install-music-dl.sh --dry-run   # print the plan, change nothing
installers/install-music-dl.sh             # install (or upgrade) all three
installers/install-music-dl.sh --reinstall # rebuild each sandbox from scratch
installers/install-music-dl.sh --uninstall # remove the three, keep pipx/ffmpeg
```

Re-running the plain version is safe: it upgrades anything out of date and
leaves everything else alone.

Then:

```sh
rip url https://tidal.com/album/12345678
spotdl download https://open.spotify.com/playlist/abc123
yt-dlp -x --audio-format flac https://youtube.com/watch?v=xyz
```

## The `yt-dlp` complication

`yt-dlp` can end up on the box three different ways: from apt (`/usr/bin`), from
`utils.sh` step 9's `pip` line, and from pipx. All three want to be the program
that runs when you type `yt-dlp`.

Which one actually wins is decided by **PATH** — a list of folders your shell
searches, in order, top to bottom. The first match wins and the rest are
invisible.

On this T480, `~/.local/bin` sits at the *bottom* of that list, below
`/usr/bin`. So the apt copy wins, and a `pipx upgrade yt-dlp` upgrades a program
your shell never reaches. That is genuinely confusing — the upgrade succeeds and
nothing changes — so the script checks for it and prints a warning:

```
warning: pipx manages /home/steve/.local/bin/yt-dlp, but 'yt-dlp' resolves to /usr/bin/yt-dlp
```

Two ways to fix it, pick one:

- move `~/.local/bin` earlier in `PATH` in `~/.zshrc`, or
- `sudo apt purge yt-dlp` so the apt copy is gone and pipx's is the only one.

This matters because the distro copy goes stale. YouTube changes how its pages
work every few weeks, and yt-dlp ships fixes within days; Debian's packaged
version is frozen at whatever shipped with the release. A stale yt-dlp fails on
YouTube with a confusing extraction error.

## The VPN problem (you will hit this)

Your box keeps NordVPN connected all the time and rotates country every six
hours. That means your traffic leaves from an IP address **shared by lots of
strangers**. Websites cannot tell you apart from the rest, so they treat the
whole address as suspicious and put up a challenge.

There are two different challenges, and they need two different fixes.

**Cloudflare's 403.** Cloudflare guards a lot of sites and can tell a program
from a real browser by the exact way each one starts an encrypted connection —
a sort of fingerprint. Message looks like:

```
ERROR: [generic] Got HTTP Error 403 caused by Cloudflare anti-bot challenge
```

Fixed already. The script installs a library called `curl-cffi` that lets
yt-dlp copy a real browser's fingerprint:

```sh
yt-dlp --impersonate chrome <URL>
```

**YouTube's bot gate.** Different and harder:

```
ERROR: [youtube] Sign in to confirm you're not a bot.
```

Fingerprint-copying does *not* get past this one — tested, it still fails.
YouTube wants proof you are a signed-in person, which means handing over the
cookies from a browser where you are already logged in:

```sh
yt-dlp --cookies-from-browser firefox <URL>
spotdl --cookie-file ~/cookies.txt download <URL>
```

Because `spotdl` gets its actual audio from YouTube, **spotdl cannot download
anything while the VPN is up unless you give it cookies.** Its Spotify half
still works — it will correctly list every song in your playlist and then fail
to fetch the sound. That is the VPN, not a broken install.

## What was actually tested (2026-08-24)

| Tool | Result |
|---|---|
| `yt-dlp` | Full download, converted to FLAC 44.1kHz stereo, checked with `ffprobe`. Works. |
| `spotdl` | Spotify song lookup works (correct artist, album). YouTube audio leg blocked by the bot gate above. |
| `rip` | Creates its config, asks for your login, exits cleanly if you don't give one. The real download needs a paid account, so it could not be tested here. |

One quirk worth knowing: `rip search` opens an interactive menu and needs a real
terminal. Inside a script it crashes with `No such device or address:
'/dev/tty'`. Use `rip url` instead when scripting.

## What the script refuses to touch

- It never writes credentials, and never will.
- It never removes the apt or pip copies of `yt-dlp` for you — it tells you
  they are there and lets you decide.
- `--uninstall` leaves `pipx` and `ffmpeg` alone, because other things on the
  box use them, and leaves `~/.config/streamrip/` alone because it may hold
  your login details.
