# TODO

- `debloat-xfce.sh`: after switching from XFCE to KDE, write a
  parallel to `debloat-mx.sh` that strips XFCE-specific packages
  (`xfce4-*`, thunar, mousepad, ristretto, xfce4-terminal,
  xfce4-screenshooter, parole, etc.). Don't run while XFCE is the
  active session — it'll break the live desktop. Preflight should
  check that another DE is running (`$XDG_CURRENT_DESKTOP`).
