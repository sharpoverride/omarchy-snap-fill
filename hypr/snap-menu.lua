-- Hover the maximize button of a floating window to get a layout picker:
-- Fill (the whole work area) plus halves and quarters, like Windows snap
-- layouts / macOS Fill & Arrange.
--
-- Hyprbars has no hover events, so a light timer compares the cursor with the
-- maximize button of the topmost titlebar under it. After a short dwell the
-- state is written to $XDG_RUNTIME_DIR/hypr-snap-menu.state, which the overlay
-- in ~/.config/hypr/snap-preview draws (and handles clicks / hover preview
-- for). A click runs `snap_menu.apply(address, layout)` through hyprctl eval.
-- Choosing the layout a window already has puts it back to its old size.
--
-- Needs snap-top.lua (shared snapped-window bookkeeping and work area).

local top = snap_top
if not top then
  return {}
end

local M = {
  poll_ms = 50,
  dwell_ms = 300, -- hover time on the button before the picker opens
  grace_ms = 250, -- time the cursor may be away before the picker closes
  bar_height = 30,
  -- Maximize button x-range measured from the window's right edge (it sits
  -- between close and minimize; see hyprbars bar_padding/button size).
  button_left = 64,
  button_right = 34,
  menu_w = 266,
  menu_h = 150,
  floating_tag = "omarchy-floating-workspace",
}

local state_file = (os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000") .. "/hypr-snap-menu.state"

-- name = { x0, x1, y0, y1 } on a 2x2 grid
local LAYOUTS = {
  { "fill", 0, 2, 0, 2 },
  { "left", 0, 1, 0, 2 },
  { "right", 1, 2, 0, 2 },
  { "top", 0, 2, 0, 1 },
  { "bottom", 0, 2, 1, 2 },
  { "tl", 0, 1, 0, 1 },
  { "tr", 1, 2, 0, 1 },
  { "bl", 0, 1, 1, 2 },
  { "br", 1, 2, 1, 2 },
}

local menu = nil -- { address, rect = {x,y,w,h}, button = {x,y,w,h} }
local hover = { address = nil, since = 0 }
local away_since = nil
local written = nil
local timer = nil

local ticks = 0
local last_cursor = nil
local function now_ms()
  return ticks * M.poll_ms
end

local function write_state(text)
  if text == written then
    return
  end
  local tmp = state_file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
  f:write(text, "\n")
  f:close()
  os.rename(tmp, state_file)
  written = text
end

local function has_tag(w)
  for _, t in ipairs(w.tags or {}) do
    if tostring(t):gsub("%*$", "") == M.floating_tag then
      return true
    end
  end
  return false
end

local function has_titlebar(w)
  return top.eligible(w) and w.workspace and w.workspace.visible and has_tag(w)
end

local function contains(r, p)
  return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h
end

local function button_rect(w)
  return { x = w.at.x + w.size.x - M.button_left, y = w.at.y - M.bar_height, w = M.button_left - M.button_right, h = M.bar_height }
end

-- Layout boxes for a window's monitor. `outer` includes borders and is what
-- the overlay previews; `inner` is what the window is resized to (below its
-- titlebar, which sits above the window box).
local function boxes(mon, bar)
  bar = bar or 0
  local margin = top.margin
  local border = tonumber(hl.get_config("general.border_size")) or 0
  local area = top.work_area(mon)
  local cw = (area.w - 3 * margin) / 2
  local ch = (area.h - 3 * margin) / 2
  local result = {}
  for _, l in ipairs(LAYOUTS) do
    local name, x0, x1, y0, y1 = table.unpack(l)
    local ox = area.x + margin + x0 * (cw + margin)
    local oy = area.y + margin + y0 * (ch + margin)
    local ow = (x1 - x0) * cw + (x1 - x0 - 1) * margin
    local oh = (y1 - y0) * ch + (y1 - y0 - 1) * margin
    result[#result + 1] = {
      name = name,
      outer = { x = ox, y = oy, w = ow, h = oh },
      inner = { x = ox + border, y = oy + border + bar, w = ow - 2 * border, h = oh - 2 * border - bar },
    }
  end
  return result
end

local function hide()
  menu = nil
  away_since = nil
  write_state("hide")
end

-- The topmost titlebar-carrying window whose maximize button is under the cursor.
local function window_under_button(cursor)
  local hit
  for _, w in ipairs(hl.get_windows()) do
    if has_titlebar(w) and contains(button_rect(w), cursor) then
      if not hit or (w.focus_history_id or 0) < (hit.focus_history_id or 0) then
        hit = w
      end
    end
  end
  if not hit then
    return nil
  end
  -- Something more recently focused that covers the button hides it.
  for _, w in ipairs(hl.get_windows()) do
    if w.address ~= hit.address and top.eligible(w) and w.workspace and w.workspace.visible and (w.focus_history_id or 0) < (hit.focus_history_id or 0) then
      local body = { x = w.at.x, y = w.at.y - (has_tag(w) and M.bar_height or 0), w = w.size.x, h = w.size.y + (has_tag(w) and M.bar_height or 0) }
      if contains(body, cursor) then
        return nil
      end
    end
  end
  return hit
end

local function open(w)
  local mon = w.monitor
  if not top.valid_monitor(mon) then
    return
  end
  local btn = button_rect(w)
  local area = top.work_area(mon)
  local px = btn.x + btn.w / 2 - M.menu_w / 2
  px = math.max(area.x + 4, math.min(px, area.x + area.w - M.menu_w - 4))
  local py = btn.y + btn.h
  menu = { address = w.address, rect = { x = px, y = py, w = M.menu_w, h = M.menu_h }, button = btn }

  local lines = { string.format("show %s %s %d %d %d %d", mon.name, w.address, math.floor(px - mon.x), math.floor(py - mon.y), M.menu_w, M.menu_h) }
  for _, b in ipairs(boxes(mon)) do
    local o = b.outer
    lines[#lines + 1] = string.format("box %s %d %d %d %d", b.name, math.floor(o.x - mon.x), math.floor(o.y - mon.y), math.floor(o.w), math.floor(o.h))
  end
  lines[#lines + 1] = "end"
  write_state(table.concat(lines, "\n"))
  top.log("menu open for %s at (%d,%d)", w.address, px, py)
end

local function tick()
  ticks = ticks + 1
  local cursor = hl.get_cursor_pos()
  if not cursor then
    return
  end
  local pressed = hl.is_key_down(0)
  local t = now_ms()

  -- Nothing to do while the pointer rests and no picker or dwell is pending.
  if not menu and not hover.address and last_cursor and last_cursor.x == cursor.x and last_cursor.y == cursor.y then
    return
  end
  last_cursor = { x = cursor.x, y = cursor.y }

  if menu then
    local w = hl.get_window("address:" .. menu.address)
    if not has_titlebar(w) then
      hide()
      return
    end
    -- The window moved (e.g. dragged or snapped): the picker no longer fits it.
    local btn = button_rect(w)
    if math.abs(btn.x - menu.button.x) > 2 or math.abs(btn.y - menu.button.y) > 2 then
      hide()
      return
    end
    local inside = contains(menu.rect, cursor) or contains({ x = btn.x - 2, y = btn.y - 2, w = btn.w + 4, h = btn.h + 4 }, cursor)
    if inside then
      away_since = nil
    else
      away_since = away_since or t
      if t - away_since > M.grace_ms then
        hide()
      end
    end
    return
  end

  if pressed then
    hover.address = nil
    return
  end

  local w = window_under_button(cursor)
  if not w then
    hover.address = nil
    return
  end
  if hover.address ~= w.address then
    hover.address, hover.since = w.address, t
  elseif t - hover.since >= M.dwell_ms then
    hover.address = nil
    open(w)
  end
end

-- Move a floating window to a layout box, or put it back if it already is there.
function M.apply(address, name)
  hide()
  -- The click also reaches snap-top's drag tracking; end it before moving anything.
  top.finish("menu")
  local w = hl.get_window("address:" .. address)
  if not top.eligible(w) then
    return
  end
  local mon = w.monitor
  if not top.valid_monitor(mon) then
    return
  end
  for _, b in ipairs(boxes(mon, has_tag(w) and M.bar_height or 0)) do
    if b.name == name then
      local box = { x = math.floor(b.inner.x), y = math.floor(b.inner.y), w = math.floor(b.inner.w), h = math.floor(b.inner.h) }
      local cur, state = top.geom(w), top.snapped[address]
      local was_snapped = state and top.same_geom(cur, state.snapped)
      if was_snapped and (state.layout == name or top.same_geom(cur, box)) then
        top.place(address, state.pre)
        top.forget(address)
        top.log("menu: restored %s", address)
        return
      end
      top.place(address, box)
      top.snapped[address] = { pre = state and state.pre or cur, snapped = box, layout = name }
      top.save_snapped()
      -- Apps with size limits end up off the box; remember where it really landed.
      hl.timer(function()
        local now = hl.get_window("address:" .. address)
        local st = top.snapped[address]
        if now and st then
          st.snapped = top.geom(now)
          top.save_snapped()
        end
      end, { timeout = 150, type = "oneshot" })
      hl.dispatch(hl.dsp.focus({ window = "address:" .. address }))
      top.log("menu: %s -> %s", address, name)
      return
    end
  end
end

M.hide = hide

local ok = pcall(function()
  timer = hl.timer(function()
    local good, err = xpcall(tick, debug.traceback)
    if not good then
      top.log("ERROR in snap-menu tick: %s", tostring(err))
      menu = nil
      pcall(write_state, "hide")
    end
  end, { timeout = M.poll_ms, type = "repeat" })
end)
if not ok then
  top.log("snap-menu: could not start timer")
end

write_state("hide")

snap_menu = M
return M
