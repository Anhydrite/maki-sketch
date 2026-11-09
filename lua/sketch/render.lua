-- Composes an HTML design into a cell grid for a cols x rows budget.
--
-- The design is laid out at the full content height, not the pane height: a
-- pane shows a window of it, and `offset` picks the first visible row. A short
-- design still hugs its content so it does not drag dozens of blank rows.

local dom = require("sketch.dom")
local css = require("sketch.css")
local layout = require("sketch.layout")
local paint = require("sketch.paint")
local points = require("sketch.points")
local text = require("sketch.text")

local M = {}

-- Last row the boxes occupy, 0-based boxes counted from the top.
local function content_height(built)
  local h = built.body and built.body.h or 0
  for _, box in ipairs(built.boxes) do
    local bottom = (box.y or 0) + (box.fill_h or box.h or 0)
    if bottom > h then
      h = bottom
    end
  end
  return math.max(1, h)
end

local function window(grid, offset, rows)
  local out = {}
  for y = offset + 1, math.min(#grid, offset + rows) do
    out[#out + 1] = grid[y]
  end
  return out
end

function M.compose(html, cols, rows, opts)
  opts = opts or {}
  local build_opts = {
    width = opts.width or text.width,
    sub_width = text.sub_width,
  }
  local root = dom.parse(html)
  local author = css.prepare(root)
  local styles, report = css.compute(root, author)

  -- Pass 1: the viewport budget, only to measure the design, count the points
  -- and learn how tall it actually is.
  local probe = layout.build(root, styles, cols, rows, build_opts)
  local probe_points = points.collect(probe.boxes)

  -- Painted at the measured height, so a design taller than the pane is not
  -- clipped before its height is trimmed.
  local probe_grid = paint.grid(probe, probe_points, {
    cols = cols,
    rows = content_height(probe),
    canvas_rows = content_height(probe),
    bg = opts.bg,
    fg = opts.fg,
    accent = opts.accent,
    accent_fg = opts.accent_fg,
  })
  local used = paint.used_rows(probe_grid, { bg = opts.bg })
  local canvas_rows = math.max(3, math.min(content_height(probe), used + 1))

  -- Pass 2: the real thing. A design that fits keeps the trimmed viewport (so
  -- a height in vh hugs the content); one that overflows is laid out against
  -- the pane, or scrolling would change its own geometry.
  local viewport_rows = canvas_rows <= rows and canvas_rows or rows
  local built = layout.build(root, styles, cols, viewport_rows, build_opts)
  local found = points.collect(built.boxes)
  local total = math.max(canvas_rows, content_height(built))

  local grid = paint.grid(built, found, {
    cols = cols,
    rows = total,
    canvas_rows = total,
    bg = opts.bg,
    fg = opts.fg,
    accent = opts.accent,
    accent_fg = opts.accent_fg,
    selected = opts.selected,
  })

  local full_used = paint.used_rows(grid, { bg = opts.bg })
  canvas_rows = math.max(3, math.min(total, full_used + 1))
  for y = #grid, canvas_rows + 1, -1 do
    grid[y] = nil
  end

  local max_offset = math.max(0, canvas_rows - rows)
  local offset = math.floor(tonumber(opts.offset) or 0)
  offset = math.max(0, math.min(max_offset, offset))
  local visible = window(grid, offset, rows)

  return {
    cols = cols,
    rows = #visible,
    view_rows = rows,
    canvas_rows = canvas_rows,
    content_rows = canvas_rows,
    offset = offset,
    max_offset = max_offset,
    points = found,
    grid = visible,
    built = built,
    report = report,
  }
end

return M
