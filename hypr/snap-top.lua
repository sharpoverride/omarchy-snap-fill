-- Snap floating windows to fill the screen by dragging them to the top middle.
--
-- Hyprland 0.56 has no move-start/move-end events, so this follows the left
-- mouse button itself:
--   * a transparent, non-consuming bind on press snapshots the floating
--     windows and starts a ~60 Hz poll;
--   * the poll spots the window being moved (position changes, size does not,
--     so resizes and text selections are ignored) and, while the cursor is in
--     the snap zone, shows a click-through preview of the target rectangle
--     (Quickshell overlay in ~/.config/hypr/snap-preview);
--   * the drag ends when no mouse button is held any more. hl.is_key_down(0)
--     reports that: mouse buttons are the only pressed keys with keycode 0.
--     A release bind is kept as a fast path; whichever runs first wins.
-- Works for SUPER + drag and for client titlebar drags alike.
--
-- Dropping in the zone fills the monitor's work area (reserved space such as
-- the bar excluded) with `margin` on every side, exactly the previewed box.
-- Dragging a snapped window away restores its previous size.
--
-- Diagnostics: every drag is traced to /tmp/snap-top.log (see `log` below).

local M = {
  margin = 10, -- gap around a snapped window, logical px
  zone_height = 50, -- zone reaches this far below the bar (the bar strip counts too)
  zone_width = 0.5, -- centered fraction of the monitor width that triggers
  poll_ms = 16,
  debug = true,
}

local preview_file = (os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000") .. "/hypr-snap-top.preview"

-- Debug log: cheap, append-only, truncated once it passes 1 MB.
-- Disable with `hyprctl eval 'snap_top.debug = false'`.
local log_file = "/tmp/snap-top.log"
local function log(fmt, ...)
  if not M.debug then
    return
  end
  local ok, msg = pcall(string.format, fmt, ...)
  local f = io.open(log_file, "a")
  if not f then
    return
  end
  if f:seek("end") > 1024 * 1024 then
    f:close()
    f = io.open(log_file, "w")
    if not f then
      return
    end
  end
  f:write(os.date("%H:%M:%S "), ok and msg or ("bad log format: " .. tostring(fmt)), "\n")
  f:close()
end
M.log = log

-- Run fn, logging (instead of losing) any error.
local function guarded(name, fn)
  return function(...)
    local ok, err = xpcall(fn, debug and debug.traceback or tostring, ...)
    if not ok then
      log("ERROR in %s: %s", name, tostring(err))
    end
  end
end

-- [address] = { pre = {x,y,w,h}, snapped = {x,y,w,h} }
-- Kept in a runtime file too: every config reload (Hyprland reloads on any
-- save in ~/.config/hypr) starts a fresh Lua state, which would otherwise
-- forget the sizes to restore.
local snapped = {}
local state_file = (os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000") .. "/hypr-snap-top.state"

local function save_snapped()
  local f = io.open(state_file, "w")
  if not f then
    return
  end
  for address, st in pairs(snapped) do
    local p, b = st.pre, st.snapped
    f:write(string.format("%s %d %d %d %d %d %d %d %d\n", address, p.x, p.y, p.w, p.h, b.x, b.y, b.w, b.h))
  end
  f:close()
end

local function forget(address)
  if snapped[address] then
    snapped[address] = nil
    save_snapped()
  end
end

local function load_snapped()
  local f = io.open(state_file, "r")
  if not f then
    return
  end
  for line in f:lines() do
    local a, n = line:match("^(%S+)"), {}
    for v in line:gmatch("%s(-?%d+)") do
      n[#n + 1] = tonumber(v)
    end
    if a and #n == 8 and hl.get_window("address:" .. a) then
      snapped[a] = { pre = { x = n[1], y = n[2], w = n[3], h = n[4] }, snapped = { x = n[5], y = n[6], w = n[7], h = n[8] } }
    end
  end
  f:close()
end
-- Current drag: { before = {[address] = geom}, mover = address|nil, started = epoch s, ticks = n }
local drag = nil
local poll = nil
local preview_state = nil

local function geom(w)
  return { x = w.at.x, y = w.at.y, w = w.size.x, h = w.size.y }
end

local function near(a, b, tol)
  return math.abs(a - b) <= (tol or 3)
end

local function same_size(a, b)
  return near(a.w, b.w) and near(a.h, b.h)
end

local function same_geom(a, b)
  return same_size(a, b) and near(a.x, b.x) and near(a.y, b.y)
end

local function eligible(w)
  return w and w.mapped and w.floating and (w.fullscreen or 0) == 0
end

local function valid_monitor(mon)
  return mon and mon.scale and mon.scale > 0
end

-- The monitor's usable area in logical global coordinates.
local function work_area(mon)
  local width, height = mon.width, mon.height
  if (mon.transform or 0) % 2 == 1 then
    width, height = height, width
  end
  width, height = width / mon.scale, height / mon.scale
  local r = mon.reserved or {}
  local left, top, right, bottom = r.left or 0, r.top or 0, r.right or 0, r.bottom or 0
  return { x = mon.x + left, y = mon.y + top, w = width - left - right, h = height - top - bottom, mon_w = width }
end

-- Anywhere over the bar strip or up to zone_height below it, middle of the width.
local function in_zone(mon, cursor)
  local area = work_area(mon)
  local center = mon.x + area.mon_w / 2
  return cursor.y <= area.y + M.zone_height and math.abs(cursor.x - center) <= area.mon_w * M.zone_width / 2
end

-- Where a snapped window goes. Borders are drawn outside the window box, so
-- they are kept inside the margin too; `outer` is the box including borders.
local function target(mon)
  local border = tonumber(hl.get_config("general.border_size")) or 0
  local area = work_area(mon)
  local outer = { x = area.x + M.margin, y = area.y + M.margin, w = area.w - 2 * M.margin, h = area.h - 2 * M.margin }
  local inner = { x = outer.x + border, y = outer.y + border, w = outer.w - 2 * border, h = outer.h - 2 * border }
  return inner, outer
end

local function write_preview(state)
  if state == preview_state then
    return
  end
  local f = io.open(preview_file, "w")
  if f then
    f:write(state, "\n")
    f:close()
    preview_state = state
    log("preview -> %s", state)
  else
    log("ERROR: cannot write %s", preview_file)
  end
end

local function show_preview(mon)
  local _, o = target(mon)
  write_preview(string.format("show %s %d %d %d %d", mon.name, math.floor(o.x - mon.x), math.floor(o.y - mon.y), math.floor(o.w), math.floor(o.h)))
end

local function hide_preview()
  write_preview("hide")
end

local function place(address, box)
  local sel = "address:" .. address
  hl.dispatch(hl.dsp.window.resize({ x = math.floor(box.w), y = math.floor(box.h), window = sel }))
  hl.dispatch(hl.dsp.window.move({ x = math.floor(box.x), y = math.floor(box.y), window = sel }))
end

local function snap(w, mon, pre)
  local box = target(mon)
  place(w.address, box)
  snapped[w.address] = { pre = pre, snapped = { x = math.floor(box.x), y = math.floor(box.y), w = math.floor(box.w), h = math.floor(box.h) } }
  save_snapped()
end

-- Shrink a snapped window back to its old size, keeping the grab point under
-- the cursor and the window inside the work area.
local function restore(w, state, cursor)
  local cur, pre = geom(w), state.pre
  local rel = cur.w > 0 and (cursor.x - cur.x) / cur.w or 0.5
  local box = { x = cursor.x - rel * pre.w, y = cur.y, w = pre.w, h = pre.h }

  local mon = hl.get_monitor_at_cursor() or w.monitor
  if valid_monitor(mon) then
    local area = work_area(mon)
    box.x = math.max(area.x, math.min(box.x, area.x + area.w - box.w))
    box.y = math.max(area.y, math.min(box.y, area.y + area.h - box.h))
  end

  forget(w.address)
  place(w.address, box)
end

-- Find the window this drag is moving, once it has started to move.
-- A window whose size changes is being resized (or resized itself) rather than
-- moved, so it drops out; this never cancels the detection for other windows.
local function update_mover(d)
  if d.mover then
    return
  end
  for address, old in pairs(d.before) do
    local w = hl.get_window("address:" .. address)
    if not eligible(w) then
      d.before[address] = nil
    else
      local now = geom(w)
      if not same_size(old, now) then
        log("size change on %s class=%s (%dx%d -> %dx%d); not a move", address, tostring(w.class), old.w, old.h, now.w, now.h)
        d.before[address] = nil
        local active = hl.get_active_window()
        if active and active.address == address then
          forget(address)
        end
      elseif not near(old.x, now.x) or not near(old.y, now.y) then
        d.mover = address
        log("mover %s class=%s (%d,%d) -> (%d,%d) after %d ticks", address, tostring(w.class), old.x, old.y, now.x, now.y, d.ticks or 0)
        return
      end
    end
  end
end

local function finish(reason)
  if not drag then
    return
  end
  local d = drag
  log("finish (%s) after %d ticks, mover=%s", tostring(reason), d.ticks or 0, tostring(d.mover))
  drag = nil
  if poll then
    poll:set_enabled(false)
  end
  hide_preview()

  update_mover(d)
  local address = d.mover
  if not address then
    return
  end
  local w = hl.get_window("address:" .. address)
  local cursor = hl.get_cursor_pos()
  if not eligible(w) or not cursor then
    return
  end

  local old, state = d.before[address], snapped[address]
  local was_snapped = state and same_geom(old, state.snapped)
  local mon = hl.get_monitor_at_cursor()
  local zone = valid_monitor(mon) and in_zone(mon, cursor)
  log("drop at (%.0f,%.0f) on %s in_zone=%s was_snapped=%s", cursor.x, cursor.y, mon and mon.name or "?", tostring(zone), tostring(was_snapped))
  if zone then
    snap(w, mon, was_snapped and state.pre or old)
    local g = geom(hl.get_window("address:" .. address) or w)
    log("snapped %s -> (%d,%d) %dx%d", address, g.x, g.y, g.w, g.h)
  elseif was_snapped then
    restore(w, state, cursor)
    log("restored %s to %dx%d", address, state.pre.w, state.pre.h)
  else
    forget(address)
  end
end

local function tick()
  if not drag then
    if poll then
      poll:set_enabled(false)
    end
    return
  end

  -- Button released (or a stuck drag after two minutes): the drag is over.
  if not hl.is_key_down(0) then
    finish("button up")
    return
  end
  if os.time() - drag.started > 120 then
    finish("timeout")
    return
  end

  drag.ticks = (drag.ticks or 0) + 1
  update_mover(drag)
  local cursor = hl.get_cursor_pos()
  local w = drag.mover and hl.get_window("address:" .. drag.mover)
  local mon = hl.get_monitor_at_cursor()
  local zone = eligible(w) and cursor and valid_monitor(mon) and in_zone(mon, cursor) or false
  if drag.ticks == 1 or drag.ticks % 60 == 0 or zone ~= drag.zone then
    log("tick %d cursor=(%.0f,%.0f) mover=%s in_zone=%s", drag.ticks, cursor and cursor.x or -1, cursor and cursor.y or -1, tostring(drag.mover), tostring(zone))
  end
  drag.zone = zone
  if zone then
    show_preview(mon)
  else
    hide_preview()
  end
end

function M.on_press()
  local before = {}
  for _, w in ipairs(hl.get_windows()) do
    if eligible(w) and w.workspace and w.workspace.visible then
      before[w.address] = geom(w)
    end
  end
  drag = { before = before, started = os.time(), ticks = 0 }
  local cursor = hl.get_cursor_pos()
  local n = 0
  for _ in pairs(before) do
    n = n + 1
  end
  log("press at (%.0f,%.0f), %d floating candidates, button_down=%s", cursor and cursor.x or -1, cursor and cursor.y or -1, n, tostring(hl.is_key_down(0)))

  if poll then
    poll:set_enabled(true)
  else
    poll = hl.timer(guarded("tick", tick), { timeout = M.poll_ms, type = "repeat" })
  end
end

M.finish = finish
M.tick = tick

-- Shared with snap-menu.lua (the maximize-button layout picker).
M.snapped = snapped
M.geom = geom
M.same_geom = same_geom
M.eligible = eligible
M.valid_monitor = valid_monitor
M.work_area = work_area
M.place = place
M.save_snapped = save_snapped
M.forget = forget

-- Any modifiers, never swallow the click, and never shadowed by other binds.
hl.bind("mouse:272", guarded("press", function() M.on_press() end), { ignore_mods = true, non_consuming = true, transparent = true })
hl.bind("mouse:272", guarded("release", function()
  log("release bind")
  hl.timer(guarded("finish", function() M.finish("release bind") end), { timeout = 10, type = "oneshot" })
end), { ignore_mods = true, non_consuming = true, transparent = true, release = true })

hl.on("window.destroy", function(w)
  if w and w.address then
    forget(w.address)
  end
end)

-- The preview overlay runs as a user service (~/.config/systemd/user/
-- snap-preview.service) so it is restarted if it dies and is independent of
-- the Omarchy shell. Starting an already running service is a no-op, so
-- config reloads never spawn a second overlay.
local function start_overlay()
  log("config loaded; ensuring overlay service runs")
  preview_state = nil
  hide_preview()
  hl.exec_cmd("systemctl --user start snap-preview.service")
end

load_snapped()
hl.on("hyprland.start", start_overlay)
if #(hl.get_monitors() or {}) > 0 then
  start_overlay()
end

-- Exposed for tweaking from `hyprctl eval`, e.g. `snap_top.margin = 20`.
snap_top = M

return M
