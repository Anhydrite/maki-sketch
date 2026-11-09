-- Wheel events, normalised.
--
-- maki reports a mouse wheel tick in one of two shapes depending on where it
-- lands: a window event (`type = "mouse"`) or a buffer click, both carrying
-- either the SGR button number or a kind string. Terminals differ on the
-- spelling, so every shape is accepted and anything else returns nil.

local M = {}

local STEP = 3 -- rows per tick: one line feels broken, a page is a jump

local function direction(word)
  -- "ScrollUp", "scroll-up", "scroll_up" and "mouse wheel up" are one tick.
  local w = tostring(word or ""):lower():gsub("[%s%-_]+", "")
  if w == "scrollup" or w == "wheelup" or w == "mousewheelup" then
    return -1
  elseif w == "scrolldown" or w == "wheeldown" or w == "mousewheeldown" then
    return 1
  end
  return nil
end

function M.wheel_delta(ev)
  if type(ev) ~= "table" then
    return nil
  end

  -- SGR mouse buttons: 64 = wheel up, 65 = wheel down (bit 6 set).
  local button = tonumber(ev.button)
  if button == 64 then
    return -STEP
  elseif button == 65 then
    return STEP
  end

  -- Anything else that names the tick: `button` as a word, `kind`, `action`.
  for _, field in ipairs({ "button", "kind", "action", "name" }) do
    local dir = direction(ev[field])
    if dir then
      return dir * STEP
    end
  end

  return nil
end

return M
