# TODO

- `debloat-xfce.sh`: after switching from XFCE to KDE, write a
  parallel to `debloat-mx.sh` that strips XFCE-specific packages
  (`xfce4-*`, thunar, mousepad, ristretto, xfce4-terminal,
  xfce4-screenshooter, parole, etc.). Don't run while XFCE is the
  active session — it'll break the live desktop. Preflight should
  check that another DE is running (`$XDG_CURRENT_DESKTOP`).
  - Does that debloat script do all there is to save RAM, CPU and disk? If not, go through
    all the things it still hasn't done.
- `utils.sh` KDE keybindings: add a KDE-equivalent block to step 13
  (currently XFCE-only via `xfconf-query`). For KDE, use
  `kwriteconfig6 --file kglobalshortcutsrc` (or write directly to
  `~/.config/kglobalshortcutsrc` + `~/.config/khotkeysrc`) and run
  `kquitapp6 kglobalaccel && kglobalaccel6 &` to reload. Bindings to
  set:
  - Meta+K → `systemctl poweroff`
  - Meta+Space → toggle keyboard layout (us↔ru) — handled by KWin's
    `Switch to Next Keyboard Layout` global, or via `setxkbmap`
    helper script in `~/.local/bin/`
  - Meta+L → log out (`qdbus6 org.kde.Shutdown /Shutdown logout`)
  Gate the block on `$XDG_CURRENT_DESKTOP == KDE` (or `command -v
  kwriteconfig6`) so it's a no-op on XFCE.
