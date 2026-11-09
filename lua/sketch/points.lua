-- Numbered points: collection, the row map used by clicks, and the compact
-- inventory handed back to the model.

local M = {}

function M.collect(boxes)
  local points = {}
  for _, box in ipairs(boxes) do
    if box.point then
      points[#points + 1] = {
        n = #points + 1,
        label = box.point,
        box = box,
        tag = box.node and box.node.tag or "?",
      }
    end
  end
  return points
end

-- Counts `data-point` elements before layout, so click targets can be
-- reserved up front.
function M.count(root)
  local n = 0
  local function walk(node)
    if node.type == "element" and node.attrs and node.attrs["data-point"] then
      n = n + 1
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(root)
  return n
end

-- row (1-based, screen) -> list of point numbers covering it.
--
-- `opts` is the scroll window: a number is a row offset, or `{offset, rows}`
-- when Points outside it must be dropped, so a click maps to what is on screen.
function M.row_map(points, opts)
  local offset, limit = 0, nil
  if type(opts) == "number" then
    offset = opts
  elseif type(opts) == "table" then
    offset = opts.offset or 0
    limit = opts.rows
  end

  local map = {}
  local function add(row, n)
    row = row - offset
    if not row or row < 1 then
      return
    end
    if limit and row > limit then
      return
    end
    local list = map[row]
    if not list then
      list = {}
      map[row] = list
    end
    for _, v in ipairs(list) do
      if v == n then
        return
      end
    end
    list[#list + 1] = n
  end

  for _, p in ipairs(points) do
    local h = p.box.fill_h or p.box.h
    for row = p.box.y + 1, p.box.y + h do
      add(row, p.n)
    end
  end
  return map
end

function M.inventory(points)
  local parts = {}
  for _, p in ipairs(points) do
    parts[#parts + 1] = string.format(
      "%d=%s(%s %dx%d)",
      p.n,
      p.label,
      p.tag,
      p.box.w,
      p.box.fill_h or p.box.h
    )
  end
  return table.concat(parts, " ")
end

-- Parses the "points: 1=nav(div 51x1) 2=..." tail of a rendered summary back
-- into rows, so a restored tool row can rebuild the clickable list.
function M.parse_inventory(text)
  local rows = {}
  text = tostring(text or "")
  local inv = text:match("points:[ ]*(.-)[ ]*·") or text:match("points:[ ]*(.-)$")
  if not inv then
    return rows
  end
  for n, label, dims in inv:gmatch("(%d+)=([^%s%(]+)%(([^%)]*)%)") do
    rows[#rows + 1] = { n = tonumber(n), label = label, dims = dims }
  end
  return rows
end

return M
