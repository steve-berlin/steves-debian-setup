# `nic-boost` explained (ELI11)

A plain-language guide to `launchers/nic-boost` — a temporary speed-up for the
network card, meant to be switched on for one job and then forgotten.

## The trade it makes

Network hardware saves power by **napping**. WiFi chips have "power save": in
the gaps between packets they switch the radio off for a few milliseconds. Wired
ethernet has **EEE** (Energy-Efficient Ethernet), which does the same for the
cable when the link is quiet.

Waking back up takes time. Not much — but it lands as a small delay at the front
of every burst of traffic, which is exactly where you notice it on a big
download or a video call.

`nic-boost` turns the napping off. Faster response, slightly higher battery
drain — roughly 0.3–0.5 W for the WiFi radio and about 0.5 W for an idle
ethernet link.

Here is the important bit: **that cost is highest exactly when the boost is
useless.** Napping only saves power when traffic is low, so switching it off
burns battery while you're doing nothing. That is why this is a per-session
opt-in command rather than a permanent setting.

## How to use it

```sh
nic-boost                    # on; stays on until reboot
nic-boost <command...>       # on, run the command, off again when it exits
nic-boost --off              # off (back to defaults)
```

The middle form is the good one:

```sh
nic-boost yt-dlp https://example.com/big-video
```

Boost applies, the download runs, and the moment it finishes the settings snap
back — including if you Ctrl-C it or the command crashes, because the revert is
attached to the script exiting rather than to the command succeeding.

## How it finds your network cards

It reads the list of interfaces the kernel exposes and sorts them itself,
skipping the ones that aren't real hardware: the loopback device `lo`, virtual
machine interfaces (`vir*`), and Docker's bridges (`docker*`, `br-*`).

Whatever has a `wireless` folder is WiFi; whatever else has a driver is
ethernet. So it works on a laptop with both, one, or a differently-named card,
with nothing to configure.

## One confusing detail

The commands underneath read backwards:

```sh
sudo iw dev wlan0 set power_save off
sudo ethtool --set-eee eth0 eee off
```

**`off` is the boost.** You are turning *power saving* off, not the network. The
script prints which is which so you can tell at a glance:

```
nic-boost on  (wifi power_save=off, eee=off — eth: enp0s31f6  wifi: wlp3s0)
```

## Why you can't break anything with it

Both settings are **runtime-only**. Nothing is written to a config file, no
driver options are made permanent, no NetworkManager hook is installed. The
kernel holds them in memory and forgets them on reboot.

So there are three ways back to normal: `nic-boost --off`, letting a wrapped
command exit, or rebooting. If you forget entirely, the next reboot handles it.

It needs `sudo` — changing hardware settings requires root — and every change is
written so that an interface which doesn't support the knob is skipped quietly
rather than throwing an error. Many ethernet chips have no EEE support at all;
that is not a failure.

## Exit codes

It passes through whatever the wrapped command returned, so
`nic-boost make test` fails when the tests fail. With no command, exit 0.
