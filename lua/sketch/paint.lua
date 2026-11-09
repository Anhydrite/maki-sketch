-- Paints laid-out boxes into a cell grid, then turns the grid into the span
-- lines `Buf:set_lines` expects.

local text = require("sketch.text")

local M = {}

local function style_of(st, default_fg)
  local fg = st and st.color or default_fg
  if fg == "currentColor" then
    fg = default_fg
  end
  return {
    fg = fg,
    bg = st and st.background or nil,
    bold = st and st.bold or false,
    italic = st and st.italic or false,
    underline = st and st.underline or false,
    strike = st and st.strike or false,
    dim = st and st.dim or false,
  }
end

local function new_grid(cols, rows, bg)
  local grid = {}
  for y = 1, rows do
    local row = {}
    for x = 1, cols do
      row[x] = { ch = " ", bg = bg }
    end
    grid[y] = row
  end
  return grid
end

local function set_cell(grid, x, y, ch, style)
  local row = grid[y]
  if not row or x < 1 or x > #row then
    return false
  end
  row[x] = {
    ch = ch,
    fg = style.fg,
    bg = style.bg,
    bold = style.bold,
    italic = style.italic,
    underline = style.underline,
    strike = style.strike,
    dim = style.dim,
  }
  return true
end

local function has_border(st)
  local v = tostring(st.border_width or "0"):match("^([%d%.]+)")
  return tonumber(v) ~= nil and tonumber(v) > 0
end

local function fill_rect(grid, x, y, w, h, color)
  if not color then
    return
  end
  for yy = math.max(1, y), math.min(#grid, y + h - 1) do
    for xx = math.max(1, x), math.min(#grid[yy], x + w - 1) do
      grid[yy][xx].bg = color
    end
  end
end

local function put_text(grid, x, y, s, style, clip_x1, clip_x2)
  local row = grid[y]
  if not row then
    return
  end
  clip_x1 = clip_x1 or 1
  clip_x2 = clip_x2 or #row
  local cx = x
  for cp, start, blen in text.codepoints(s) do
    local cw = text.char_width(cp)
    local piece = s:sub(start, start + blen - 1)
    if cw == 0 then
      -- Combining mark on the previous cell.
      local prev = row[cx - 1]
      if prev then
        prev.ch = prev.ch .. piece
      end
    elseif cx + cw - 1 > clip_x2 then
      break
    elseif cx >= clip_x1 then
      set_cell(grid, cx, y, piece, style)
      if cw == 2 then
        set_cell(grid, cx + 1, y, "", style)
      end
      cx = cx + cw
    else
      cx = cx + cw
    end
  end
end

local function draw_border(grid, box)
  local x, y, w, h = box.x + 1, box.y + 1, box.w, box.fill_h or box.h
  if w < 2 or h < 2 then
    return
  end
  local rounded = (box.style.border_radius or 0) > 0
  local tl = rounded and "╭" or "┌"
  local tr = rounded and "╮" or "┐"
  local bl = rounded and "╰" or "└"
  local br = rounded and "╯" or "┘"
  local bstyle = { fg = box.style.border_color }

  for xx = x + 1, x + w - 2 do
    set_cell(grid, xx, y, "─", bstyle)
    set_cell(grid, xx, y + h - 1, "─", bstyle)
  end
  for yy = y + 1, y + h - 2 do
    set_cell(grid, x, yy, "│", bstyle)
    set_cell(grid, x + w - 1, yy, "│", bstyle)
  end
  set_cell(grid, x, y, tl, bstyle)
  set_cell(grid, x + w - 1, y, tr, bstyle)
  set_cell(grid, x, y + h - 1, bl, bstyle)
  set_cell(grid, x + w - 1, y + h - 1, br, bstyle)
end

-- A single-cell accent outline, used for the point the user just picked.
local function outline(grid, box, color)
  local x, y, w, h = box.x + 1, box.y + 1, box.w, box.h
  local style = { fg = color, bold = true }
  if w < 1 or h < 1 then
    return
  end
  for xx = x, x + w - 1 do
    set_cell(grid, xx, y, "─", style)
    if h > 1 then
      set_cell(grid, xx, y + h - 1, "─", style)
    end
  end
  for yy = y, y + h - 1 do
    set_cell(grid, x, yy, "│", style)
    if w > 1 then
      set_cell(grid, x + w - 1, yy, "│", style)
    end
  end
end

-- True when the cells a badge would take hold no text yet.
local function cells_free(grid, x, y, n)
  local row = grid[y]
  if not row then
    return false
  end
  for i = 0, n - 1 do
    local cell = row[x + i]
    if not cell then
      return false
    end
    if cell.ch ~= " " and cell.ch ~= "" then
      return false
    end
  end
  return true
end

local function badge(grid, box, n, opts, parent_box)
  local label = "[" .. n .. "]"
  local style = { fg = opts.accent_fg, bg = opts.accent, bold = true }

  -- Put the badge after the first line of the element's own text when there
  -- is room, so it reads `Welcome back [1]` instead of covering the text.
  local first_y, end_x, start_x = nil, nil, nil
  for _, run in ipairs(box.text_runs) do
    local w = text.width(run.text)
    if first_y == nil or run.y < first_y then
      first_y = run.y
      end_x = run.x + w
      start_x = run.x
    elseif run.y == first_y then
      end_x = math.max(end_x, run.x + w)
      start_x = math.min(start_x, run.x)
    end
  end

  -- The parent box is the nearest wall: a marker may sit just outside the
  -- element (so the text stays readable) but never outside its container.
  local left = parent_box and (parent_box.x + 1) or 1
  local right = parent_box and (parent_box.x + parent_box.w) or opts.cols

  local x, y
  if first_y == nil and box.x + box.w + #label + 1 <= right
    and cells_free(grid, box.x + box.w + 1, box.y + 1, #label) then
    -- A container with no text of its own: sit right after it.
    x = box.x + box.w + 1
    y = box.y + 1
  elseif first_y ~= nil and end_x + #label + 1 <= right
    and cells_free(grid, end_x + 1, first_y + 1, #label) then
    x = end_x + 1
    y = first_y + 1
  elseif first_y ~= nil and start_x - #label - 1 >= left
    and cells_free(grid, start_x - #label - 1, first_y + 1, #label) then
    x = start_x - #label - 1
    y = first_y + 1
  else
    -- A full-width row: prefer the rightmost free slot inside the container
    -- over punching the end of the row, so its last column stays readable.
    local slot = nil
    for xx = right - #label, left, -1 do
      if cells_free(grid, xx, box.y + 1, #label) then
        slot = xx
        break
      end
    end
    x = slot or math.max(left, math.min(right - #label, box.x + box.w - #label - 1))
    y = box.y + 1
  end
  if y > #grid then
    return
  end
  for i = 1, #label do
    local row = grid[y]
    if not row or x + i - 1 > #row then
      break
    end
    row[x + i - 1] = {
      ch = label:sub(i, i),
      fg = style.fg,
      bg = style.bg,
      bold = true,
    }
  end
end

function M.grid(layout, points, opts)
  opts = opts or {}
  local cols = opts.cols or layout.width
  local rows = opts.rows or layout.height
  local canvas_rows = opts.canvas_rows or rows
  local grid = new_grid(cols, rows, opts.bg)

  for _, box in ipairs(layout.boxes) do
    if box.y + 1 <= canvas_rows then
      local h = math.min(box.fill_h or box.h, canvas_rows - box.y)
      local bg = box.style.background
      if bg and bg ~= "currentColor" then
        fill_rect(grid, box.x + 1, box.y + 1, box.w, h, bg)
      end
      if has_border(box.style) then
        draw_border(grid, { x = box.x, y = box.y, w = box.w, h = h, style = box.style })
      end
      local run_style = style_of(box.style, opts.fg)
      for _, run in ipairs(box.text_runs) do
        local ry = run.y + 1
        if ry >= 1 and ry <= canvas_rows then
          local clip1 = box.x + 1
          local clip2 = box.x + box.w
          put_text(grid, run.x + 1, ry, run.text, style_of(run.style, opts.fg), clip1, clip2)
        end
      end
    end
  end

  local by_node = {}
  for _, box in ipairs(layout.boxes) do
    if box.node then
      by_node[box.node] = box
    end
  end
  for _, p in ipairs(points or {}) do
    local parent = p.box.node and p.box.node.parent
    badge(grid, p.box, p.n, opts, parent and by_node[parent])
  end

  if opts.selected then
    for _, p in ipairs(points or {}) do
      if p.n == opts.selected then
        outline(grid, p.box, opts.accent)
      end
    end
  end

  return grid
end

local function cell_style(cell)
  local st = {}
  if cell.fg then
    st.fg = cell.fg
  end
  if cell.bg then
    st.bg = cell.bg
  end
  if cell.bold then
    st.bold = true
  end
  if cell.italic then
    st.italic = true
  end
  if cell.underline then
    st.underline = true
  end
  if cell.strike then
    st.strike = true
  end
  if cell.dim then
    st.dim = true
  end
  return st
end

-- Coalesces cells into `{ {text, style}, ... }` spans, trimming trailing
-- default-coloured blanks so lines stay short.
-- Blends two `#rrggbb` colours; returns {r, g, b} as a hex string.
local function blend(a, b, t)
  local function parts(hex)
    local r = tonumber(hex:sub(2, 3), 16)
    local g = tonumber(hex:sub(4, 5), 16)
    local bl = tonumber(hex:sub(6, 7), 16)
    if not (r and g and bl) then
      return nil
    end
    return r, g, bl
  end
  local ar, ag, ab = parts(a)
  local br, bg, bb = parts(b)
  if not (ar and br) then
    return a
  end
  return string.format(
    "#%02x%02x%02x",
    math.floor(ar + (br - ar) * t + 0.5),
    math.floor(ag + (bg - ag) * t + 0.5),
    math.floor(ab + (bb - ab) * t + 0.5)
  )
end

-- Puts a user mark (`#N`) on a row: the line gets a tinted background so the
-- spot is obvious, and the number sits at its right edge. Rows are the finest
-- granularity a click carries (the event has no column).
function M.stamp_marks(grid, marks, opts)
  if not grid or not marks then
    return
  end
  opts = opts or {}
  local tint = opts.bg and opts.accent and blend(opts.bg, opts.accent, 0.22) or nil
  for row, n in pairs(marks) do
    local cells = grid[row]
    if cells then
      if tint then
        for x = 1, #cells do
          cells[x].bg = tint
        end
      end
      local txt = "#" .. tostring(n)
      local width = opts.cols or #cells
      local start = width - #txt + 1
      if start < 1 then
        start = 1
      end
      for i = 1, #txt do
        local c = cells[start + i - 1]
        if c then
          c.ch = txt:sub(i, i)
          c.fg = opts.accent
          c.bg = tint or opts.bg
          c.bold = true
          c.dim = false
        end
      end
    end
  end
end

-- Last row that carries something (text, a border, a background different
-- from the design's dominant one). Used to trim the blank tail of a short
-- design. The dominant background is a mode rather than opts.bg: a design
-- usually paints its own page background over the whole viewport.
function M.used_rows(grid, opts)
  opts = opts or {}
  local counts, base, best = {}, opts.bg, -1
  for _, row in ipairs(grid) do
    for _, cell in ipairs(row) do
      if cell.bg then
        counts[cell.bg] = (counts[cell.bg] or 0) + 1
      end
    end
  end
  for bg, n in pairs(counts) do
    if n > best then
      base, best = bg, n
    end
  end
  local used = 0
  for y = 1, #grid do
    for _, cell in ipairs(grid[y]) do
      local ch = cell.ch or ""
      if (ch ~= " " and ch ~= "") or (cell.bg and cell.bg ~= base) then
        used = y
        break
      end
    end
  end
  return used
end

function M.to_lines(grid, opts)
  opts = opts or {}
  local lines = {}
  for y = 1, #grid do
    local row = grid[y]
    local last = #row
    while last > 1 do
      local c = row[last]
      if (c.ch == " " or c.ch == "") and not c.fg and not c.bold and not c.underline
        and (c.bg == nil or c.bg == opts.bg) then
        last = last - 1
      else
        break
      end
    end
    local spans = {}
    local cur_text, cur_key, cur_style = "", nil, nil
    local function flush()
      if cur_text ~= "" then
        spans[#spans + 1] = { cur_text, cur_style }
      end
      cur_text, cur_key, cur_style = "", nil, nil
    end
    for x = 1, last do
      local c = row[x]
      local st = cell_style(c)
      local key = table.concat({
        tostring(st.fg), tostring(st.bg), tostring(st.bold),
        tostring(st.italic), tostring(st.underline), tostring(st.strike),
        tostring(st.dim),
      }, "|")
      if key ~= cur_key then
        flush()
        cur_key = key
        cur_style = st
      end
      cur_text = cur_text .. (c.ch or "")
    end
    flush()
    if #spans == 0 then
      spans[1] = { " " }
    end
    lines[y] = spans
  end
  return lines
end

function M.to_text(grid)
  local out = {}
  for y = 1, #grid do
    local parts = {}
    for x = 1, #grid[y] do
      parts[#parts + 1] = grid[y][x].ch or ""
    end
    out[#out + 1] = (table.concat(parts):gsub("%s+$", ""))
  end
  return table.concat(out, "\n")
end

return M
