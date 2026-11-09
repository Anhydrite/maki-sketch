-- The docked canvas pane: one split window per session, its buffer, click
-- routing and the resize listener.

local M = {}

local states = {}

-- Callbacks set by sketch.lua.
M.on_click = nil
M.on_resize = nil
M.on_key = nil

-- Claimed while the pane is open: Alt chords scroll the design without
-- stealing the plain keys the chat input needs.
local SCROLL_KEYS = {
  "<M-j>",
  "<M-k>",
  "<M-Down>",
  "<M-Up>",
  "<M-d>",
  "<M-u>",
  "<M-PageDown>",
  "<M-PageUp>",
  "<M-g>",
  "<M-G>",
}

-- The click handler is (re)attached on every update: a pane created by an
-- older build of the plugin may be open without one, and `on` replaces the
-- previous handler instead of stacking a second copy.
local function attach_click(s, sid)
  if not s or not s.buf then
    return
  end
  s.buf:on("click", function(ev)
    local row = ev and ev.row or 0
    local ok, dump = pcall(maki.json.encode, ev or {})
    maki.log.debug("sketch: click " .. (ok and dump or "?"))
    if row <= 0 then
      pcall(maki.ui.flash, "sketch: click outside the canvas")
      return
    end
    if M.on_click then
      local pok, perr = pcall(M.on_click, sid, row)
      if not pok then
        maki.log.warn("sketch: click handler failed: " .. tostring(perr))
      end
    else
      maki.log.warn("sketch: click received but no handler is set")
    end
  end)
end

local function fallback_size(opts)
  local size = { cols = 100, rows = 30 }
  local ok, ts = pcall(maki.ui.terminal_size)
  if ok and ts and ts.cols and ts.rows then
    size = ts
  end
  local pct = tonumber(tostring(opts.width or "60%"):match("(%d+)")) or 60
  local cols = math.max(20, math.floor(size.cols * pct / 100) - 2)
  local rows = math.max(6, size.rows - 2)
  return cols, rows
end

local function size_of(win, opts)
  local cols = win and win.width or nil
  local rows = win and win.height or nil
  if not cols or not rows or cols < 10 or rows < 5 then
    return fallback_size(opts)
  end
  return cols, rows
end

function M.get(sid)
  return states[sid]
end

function M.ensure(sid, opts)
  local s = states[sid]
  if s and s.win and s.win:is_open() then
    return s
  end

  local ok, err = pcall(function()
    local buf = maki.ui.buf({ scratch = true })
    local win = maki.ui.open_win(buf, {
      split = "left",
      width = opts.width or "60%",
      border = "rounded",
      focus = false,
      keys = SCROLL_KEYS,
      footer = { { "M-j/k", "scroll" }, { "M-d/u", "page" } },
      title = " sketch ",
      title_pos = "left",
      session = sid,
    })
    if not win then
      return nil
    end

    s = {
      buf = buf,
      win = win,
      scene = nil,
    }
    states[sid] = s
    s.cols, s.rows = size_of(win, opts)

    attach_click(s, sid)

    -- Resize and close events. `recv` needs a coroutine, so it lives in its
    -- own task; the loop ends with the window or with the plugin state.
    maki.async.spawn(function()
      while states[sid] == s and win:is_open() do
        local rok, ev = pcall(win.recv, win, 500)
        if not rok or not ev then
          break
        end
        if ev.type == "resize" then
          -- A split can report a degenerate geometry mid-layout; taking it
          -- would shrink the canvas to a sliver until the next resize.
          if ev.width and ev.width >= 20 then
            s.cols = ev.width
          end
          if ev.height and ev.height >= 5 then
            s.rows = ev.height
          end
          if M.on_resize then
            local pok, perr = pcall(M.on_resize, sid)
            if not pok then
              maki.log.warn("sketch: resize handler failed: " .. tostring(perr))
            end
          end
        elseif ev.type == "key" then
          if M.on_key then
            local pok, perr = pcall(M.on_key, sid, ev.key)
            if not pok then
              maki.log.warn("sketch: key handler failed: " .. tostring(perr))
            end
          end
        elseif ev.type == "close" then
          break
        end
      end
    end)
  end)

  if not ok then
    maki.log.warn("sketch: could not open the pane: " .. tostring(err))
    return nil
  end

  return states[sid]
end

function M.update(sid, lines, title, footer)
  local s = states[sid]
  if not s or not s.win or not s.win:is_open() then
    return false
  end
  attach_click(s, sid)
  s.buf:set_lines(lines)
  if title then
    pcall(s.win.set_config, s.win, { title = title })
  end
  if footer ~= nil then
    pcall(s.win.set_config, s.win, { footer = footer })
  end
  return true
end

-- Draws a real pixel frame in the pane: one cell carries the top pixel as
-- foreground and the bottom one as background, so the frame is {w} x 2*{rows}.
function M.blit(sid, fb, w, h, title)
  local s = states[sid]
  if not s or not s.win or not s.win:is_open() then
    return false
  end
  attach_click(s, sid)
  local ok = pcall(s.buf.blit, s.buf, fb, w, h, { format = "rgb" })
  if title then
    pcall(s.win.set_config, s.win, { title = title })
  end
  return ok
end

function M.size(sid, opts)
  local s = states[sid]
  if s and s.cols and s.rows then
    return s.cols, s.rows
  end
  return fallback_size(opts)
end

function M.close(sid)
  local s = states[sid]
  states[sid] = nil
  if s and s.win then
    pcall(s.win.close, s.win)
  end
end

function M.close_all()
  for sid in pairs(states) do
    M.close(sid)
  end
end

function M.is_open(sid)
  local s = states[sid]
  return s ~= nil and s.win ~= nil and s.win:is_open()
end

return M
