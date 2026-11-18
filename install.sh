#!/usr/bin/env bash
# Installs the snap/fill config into ~/.config. Safe to re-run.
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
hypr="$HOME/.config/hypr"
unit_dir="$HOME/.config/systemd/user"
conf="$hypr/hyprland.lua"

[[ -f $conf ]] || { echo "No $conf found; is this an Omarchy (Lua config) install?" >&2; exit 1; }

mkdir -p "$hypr/snap-preview" "$unit_dir"
for f in snap-top.lua snap-menu.lua snap-preview/shell.qml; do
  [[ -f $hypr/$f ]] && ! cmp -s "$src/hypr/$f" "$hypr/$f" && cp "$hypr/$f" "$hypr/$f.bak.$(date +%s)"
  cp "$src/hypr/$f" "$hypr/$f"
done
cp "$src/systemd/snap-preview.service" "$unit_dir/"

add_require() {
  local mod=$1 comment=$2
  grep -q "require(\"hypr.$mod\")" "$conf" && return
  local line="require(\"hypr.$mod\")"
  if grep -q 'require("hypr.autostart")' "$conf"; then
    sed -i "/require(\"hypr.autostart\")/a\\
\\
-- $comment\\
$line" "$conf"
  else
    printf '\n-- %s\n%s\n' "$comment" "$line" >> "$conf"
  fi
}
# Each block is inserted right after autostart, so add snap-menu first to end up after snap-top.
add_require snap-menu "Hover the maximize button of a floating window for Fill / snap layouts."
add_require snap-top "Drag a floating window to the top middle of the screen to fill it."

systemctl --user daemon-reload
systemctl --user restart snap-preview.service
hyprctl reload >/dev/null 2>&1 || true
echo "Installed. Errors, if any: $(hyprctl configerrors 2>/dev/null)"
