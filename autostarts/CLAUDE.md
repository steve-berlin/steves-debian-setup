# autostarts/

XFCE autostart `.desktop` files. Drop into `~/.config/autostart/` (per
user) or `/etc/xdg/autostart/` (system-wide).

XFCE reads `[Desktop Entry]` files from these dirs at session start and
runs `Exec=` for each. `X-GNOME-Autostart-enabled=true` is honored by
XFCE too despite the GNOME prefix.

## `alacritty-autostart.desktop` — terminal as a service

Starts `alacritty --gapplication-service` at login so subsequent
`alacritty` invocations open a window against the already-running
service (faster spawn, shared font/config cache). `Hidden=true` and
`NoDisplay=true` keep the entry out of the application menu so users
can't accidentally toggle it off from Settings → Session and Startup.

## `brave-autostart.desktop` — browser at login

Plain `brave-browser` at login. `StartupNotify=true` so the cursor
shows the launching state. Visible in the Session and Startup UI on
purpose — you may want to disable this on a low-RAM machine.

## `easyeffects.desktop` — audio EQ as a service

Same `--gapplication-service` pattern as alacritty: start once at
login, all subsequent `easyeffects` calls attach to the running
service. Required if you want presets (EQ, autogain, etc.) to apply
to every audio stream from session start, not from the first time you
open the EasyEffects GUI.

## Notes

- The `nohup` in the `Exec=` lines is defensive — XFCE's session
  manager already detaches autostart processes, but `nohup` ensures
  a stray HUP from a logout-of-the-launching-shell can't kill them.
- Trailing `&` inside `Exec=` is ignored by the .desktop spec but
  harmless; the literal command is run via the spec's own fork.
