# omarchy-snap-fill

Windows/macOS-style window snapping for Omarchy's **floating** workspace mode (Hyprland 0.56 Lua config).

- **Hover the maximize button** of a floating window: a picker opens with **Fill** (whole work area, with margin), halves and quarters. Hovering a tile previews the target; choosing the same layout again restores the old size.
- **Drag a window to the top middle** of the screen to fill it (preview shown while dragging). Dragging a snapped window away restores its size.

## Requirements

- Omarchy with the Lua Hyprland config and floating workspace mode (Super + L) enabled, which provides the hyprbars titlebars
- Quickshell (`qs`), used for the overlay

## Install

```sh
git clone https://github.com/sharpoverride/omarchy-snap-fill
cd omarchy-snap-fill && ./install.sh
```

The script copies the files into `~/.config/hypr` (backing up changed ones), adds the `require` lines to `hyprland.lua`, and enables the `snap-preview` user service. Re-running updates the files.

## Tuning

Values live in the `M` tables at the top of `snap-top.lua` (margin, drag zone) and `snap-menu.lua` (dwell time, popup size). The maximize button hit box (`button_left`/`button_right`) is measured for the default hyprbars button size and padding; adjust it if you change those.

Debug log: `/tmp/snap-top.log`.
