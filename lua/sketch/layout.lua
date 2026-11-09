-- Box layout in terminal cells.
--
-- 1 cell = 8 x 16 CSS px. Widths and heights come out as integers, text is
-- wrapped with the display-width function maki provides, and the result is a
-- flat list of boxes in paint order (parents before children) plus absolute
-- text runs. The layout is deliberately small: block/inline flow, flex rows
-- and columns, the box model, and inline-block atoms placed side by side.

local M = {}

local CELL_W, CELL_H = 8, 16

local function rnd(v)
  return math.max(0, math.floor(v + 0.5))
end

local function len(v, ref, axis)
  if v == nil or v == "" or v == "auto" or v == "none" then
    return nil
  end
  if type(v) == "number" then
    v = tostring(v)
  end
  local n, unit = v:match("^([%-%d%.]+)([%%%a]*)$")
  n = tonumber(n)
  if not n then
    return nil
  end
  if unit == "%" then
    return ref and (ref * n / 100) or nil
  end
  if unit == "em" or unit == "rem" then
    n = n * 16
  end
  if axis == "x" then
    return n / CELL_W
  end
  -- Vertical px are floored: 8px of padding is half a cell, and rounding up
  -- every small padding makes mockups look twice as airy as they are.
  return math.floor(n / CELL_H)
end

M.len = len

local function border_cells(st)
  local bw = len(st.border_width, nil, "x")
  if not bw or bw <= 0 then
    return 0
  end
  return 1
end

local function shift_box(box, dx, dy)
  if dx == 0 and dy == 0 then
    return
  end
  box.x = box.x + dx
  box.y = box.y + dy
  for _, run in ipairs(box.text_runs) do
    run.x = run.x + dx
    run.y = run.y + dy
  end
  for _, child in ipairs(box.children) do
    shift_box(child, dx, dy)
  end
end

-- Gives form controls something to measure and draw: their own text lives in
-- attributes, not children.
local function ensure_children(node)
  if node._synthetic then
    return
  end
  if #(node.children or {}) == 0 then
    local label
    if node.tag == "input" then
      label = node.attrs.value or node.attrs.placeholder or ""
    elseif node.tag == "img" then
      label = "[" .. (node.attrs.alt or "img") .. "]"
    elseif node.tag == "select" then
      label = node.attrs.value or ""
    end
    if label then
      node._synthetic = true
      node.children = { { type = "text", text = label, parent = node } }
    end
  end
end

-- Max-content width: what the box would take if nothing wrapped. A flex row
-- sums its items (plus gaps), a block takes its widest child or text line.
local function max_content(node, st, ctx, limit)
  local w = 0
  if st.display == "flex" and st.flex_direction ~= "column" then
    local total, count = 0, 0
    for _, child in ipairs(node.children or {}) do
      if child.type == "text" then
        if child.text:match("%S") then
          total = total + ctx.width(child.text:gsub("[ \t\r\n\f]+", " "))
          count = count + 1
        end
      else
        local cst = ctx.styles[child]
        if cst and cst.display ~= "none" then
          total = total + max_content(child, cst, ctx, limit)
          count = count + 1
        end
      end
    end
    if count > 1 then
      total = total + rnd(len(st.column_gap, limit, "x") or 0) * (count - 1)
    end
    w = total
  else
    -- Inline content is one line: the text on either side of a <span> or a
    -- <code> adds up, it does not restart. Measuring each text node alone made
    -- every flex item that mixed text and inline tags far too narrow.
    local line = 0
    local function commit()
      w = math.max(w, line)
      line = 0
    end
    for _, child in ipairs(node.children or {}) do
      if child.type == "text" then
        -- A text node only ends a line on a newline it actually contains: the
        -- space before a <span> belongs to the same line as the span's text.
        local raw = child.text
        if st.white_space ~= "pre" then
          raw = raw:gsub("[\r\n]+", " ")
        end
        local from = 1
        while true do
          local nl = raw:find("\n", from, true)
          if not nl then
            line = line + ctx.width(raw:sub(from))
            break
          end
          line = line + ctx.width(raw:sub(from, nl - 1))
          commit()
          from = nl + 1
        end
      else
        local cst = ctx.styles[child]
        local cst = ctx.styles[child]
        if cst and cst.display ~= "none" then
          if child.tag == "br" then
            commit()
          elseif cst.display == "inline" or cst.display == "inline-block" then
            line = line + max_content(child, cst, ctx, limit)
          else
            commit()
            w = math.max(w, max_content(child, cst, ctx, limit))
          end
        end
      end
    end
    commit()
  end
  -- Round each side like layout_node does, otherwise a 12px padding can add
  -- 3 cells here and 4 there, and the text wraps in a box measured wide enough.
  local padl = len(st.padding_left, limit, "x") or 0
  local padr = len(st.padding_right, limit, "x") or 0
  local bw = border_cells(st) * 2
  return math.min(limit, w + rnd(padl) + rnd(padr) + bw)
end

local function intrinsic_width(node, st, ctx, limit)
  ensure_children(node)
  local w = len(st.width, limit, "x")
  if w then
    return w
  end
  return math.max(1, max_content(node, st, ctx, limit))
end

local function new_box(node, st, x, y, w)
  return {
    node = node,
    style = st,
    x = x,
    y = y,
    w = w,
    h = 0,
    text_runs = {},
    children = {},
    point = node and node.attrs and node.attrs["data-point"] or nil,
  }
end

-- Turns inline content into flow items: text, line breaks and inline-block
-- atoms. Blocks are handled by the caller.
local function flatten_inline(node, st, items, ctx)
  local children = node.children or {}

  -- Whitespace-only text between two block boxes is not a line (browsers drop
  -- it); between inline boxes it is the space that separates the words.
  local function blockish(child)
    if child == nil or child.type ~= "element" then
      return false
    end
    local cst = ctx.styles[child]
    local d = cst and cst.display or "block"
    return d == "block" or d == "flex" or d == "table"
  end

  for idx, child in ipairs(children) do
    if child.type == "text" then
      if not child.text:match("%S") and st.white_space ~= "pre" then
        local prev_block = idx == 1 or blockish(children[idx - 1])
        local next_block = children[idx + 1] == nil or blockish(children[idx + 1])
        if not (prev_block and next_block) then
          items[#items + 1] = { text = child.text, style = st }
        end
      else
        items[#items + 1] = { text = child.text, style = st }
      end
    else
      local cst = ctx.styles[child] or st
      if cst.display == "none" then
        -- skipped
      elseif child.tag == "br" then
        items[#items + 1] = { br = true }
      elseif child.tag == "img" then
        items[#items + 1] = { text = "[" .. (child.attrs.alt or "img") .. "]", style = cst }
      elseif cst.display == "inline" then
        flatten_inline(child, cst, items, ctx)
      else
        -- Nested inline-blocks inside an inline box: keep their text.
        flatten_inline(child, cst, items, ctx)
      end
    end
  end
end

local function new_line()
  return { runs = {}, width = 0 }
end

-- Pushes text into {cur}, wrapping at {iw}. Returns the list of lines.
local function wrap_runs(items, st, iw, ctx)
  local lines = {}
  local cur = new_line()
  local pre = st.white_space == "pre" or st.white_space == "pre-wrap"

  local function push_line()
    -- Trim trailing spaces and skip empty lines beyond the first.
    while #cur.runs > 0 and cur.runs[#cur.runs].text == " " do
      cur.runs[#cur.runs] = nil
      cur.width = cur.width - 1
    end
    lines[#lines + 1] = cur
    cur = new_line()
  end

  local function hard_break(text, style)
    local rest = text
    while ctx.width(rest) > iw do
      local head = ctx.sub_width(rest, iw)
      if head == "" then
        break
      end
      cur.runs[#cur.runs + 1] = { text = head, style = style }
      cur.width = cur.width + ctx.width(head)
      push_line()
      rest = rest:sub(#head + 1)
    end
    if rest ~= "" then
      cur.runs[#cur.runs + 1] = { text = rest, style = style }
      cur.width = cur.width + ctx.width(rest)
    end
  end

  for _, item in ipairs(items) do
    if item.br then
      push_line()
    elseif item.text then
      local s = item.text
      if not pre then
        s = s:gsub("[ \t\r\n\f]+", " ")
      end
      if pre then
        local first = true
        for piece in (s .. "\n"):gmatch("(.-)\n") do
          if not first then
            push_line()
          end
          if piece ~= "" then
            cur.runs[#cur.runs + 1] = { text = piece, style = item.style }
            cur.width = cur.width + ctx.width(piece)
          end
          first = false
        end
      else
        local i = 1
        while i <= #s do
          local is_space = s:sub(i, i) == " "
          local j = i
          if is_space then
            while j <= #s and s:sub(j, j) == " " do
              j = j + 1
            end
          else
            while j <= #s and s:sub(j, j) ~= " " do
              j = j + 1
            end
          end
          local token = s:sub(i, j - 1)
          if is_space then
            if cur.width > 0 then
              cur.runs[#cur.runs + 1] = { text = " ", style = item.style }
              cur.width = cur.width + 1
            end
          else
            local tw = ctx.width(token)
            if cur.width > 0 and cur.width + tw > iw then
              push_line()
            end
            if tw > iw then
              hard_break(token, item.style)
            else
              cur.runs[#cur.runs + 1] = { text = token, style = item.style }
              cur.width = cur.width + tw
            end
          end
          i = j
        end
      end
    end
  end
  push_line()
  return lines
end

local function emit_lines(box, lines, ix, y, iw, st, ctx)
  local align = st.text_align or "left"
  for li, line in ipairs(lines) do
    while #line.runs > 0 and line.runs[1].text == " " do
      line.runs[1] = nil
    end
    local width = 0
    for _, run in ipairs(line.runs) do
      width = width + ctx.width(run.text)
    end
    local x = ix
    if align == "center" then
      x = ix + math.max(0, math.floor((iw - width) / 2))
    elseif align == "right" then
      x = ix + math.max(0, iw - width)
    end
    for _, run in ipairs(line.runs) do
      if run.text ~= "" then
        box.text_runs[#box.text_runs + 1] = {
          x = x,
          y = y + li - 1,
          text = run.text,
          style = run.style,
        }
        x = x + ctx.width(run.text)
      end
    end
  end
  return y + #lines
end

local layout_node

local function layout_flow(node, st, ix, iy, iw, ctx, box)
  local items = {}
  local cursor = iy

  local function flush_text()
    if #items > 0 then
      local lines = wrap_runs(items, st, iw, ctx)
      cursor = emit_lines(box, lines, ix, cursor, iw, st, ctx)
      items = {}
    end
  end

  local atom = { x = ix, y = iy, h = 0 }

  local function flush_atom()
    if atom.h > 0 then
      cursor = math.max(cursor, atom.y + atom.h)
      atom = { x = ix, y = cursor, h = 0 }
    end
  end

  local children = node.children or {}

  -- Whitespace-only text between two block boxes is not a line (browsers drop
  -- it); between inline boxes it is the space that separates the words.
  local function blockish(child)
    if child == nil or child.type ~= "element" then
      return false
    end
    local cst = ctx.styles[child]
    local d = cst and cst.display or "block"
    return d == "block" or d == "flex" or d == "table"
  end

  for idx, child in ipairs(children) do
    if child.type == "text" then
      if not child.text:match("%S") and st.white_space ~= "pre" then
        local prev_block = idx == 1 or blockish(children[idx - 1])
        local next_block = children[idx + 1] == nil or blockish(children[idx + 1])
        if not (prev_block and next_block) then
          items[#items + 1] = { text = child.text, style = st }
        end
      else
        items[#items + 1] = { text = child.text, style = st }
      end
    else
      local cst = ctx.styles[child] or st
      if cst.display == "none" then
        -- skipped
      elseif child.tag == "br" then
        items[#items + 1] = { br = true }
      elseif cst.display == "inline" then
        flatten_inline(child, cst, items, ctx)
      elseif cst.display == "inline-block" then
        flush_text()
        local w = math.floor(intrinsic_width(child, cst, ctx, iw))
        local ml = len(cst.margin_left, iw, "x") or 0
        local mr = len(cst.margin_right, iw, "x") or 0
        w = math.min(iw, w + rnd(ml) + rnd(mr))
        local x = atom.x
        if atom.h > 0 and atom.x + w > ix + iw then
          flush_atom()
          x = ix
        end
        if atom.h == 0 then
          atom.y = cursor
        end
        local b = layout_node(child, cst, math.floor(x), atom.y, math.max(1, w), ctx)
        box.children[#box.children + 1] = b
        atom.x = x + b.w
        atom.h = math.max(atom.h, b.h)
      else
        flush_text()
        flush_atom()
        local ml = len(cst.margin_left, iw, "x") or 0
        local mr = len(cst.margin_right, iw, "x") or 0
        local mt = len(cst.margin_top, iw, "x") or 0
        local mb = len(cst.margin_bottom, iw, "x") or 0
        local cw = len(cst.width, iw, "x") or math.max(1, iw - rnd(ml) - rnd(mr))
        local x = ix + rnd(ml)
        if cst.margin_left == "auto" and cst.margin_right == "auto" then
          x = ix + math.max(0, math.floor((iw - cw) / 2))
        end
        local b = layout_node(child, cst, math.floor(x), cursor + rnd(mt), math.max(1, math.floor(cw)), ctx)
        box.children[#box.children + 1] = b
        cursor = cursor + rnd(mt) + b.h + rnd(mb)
      end
    end
  end
  flush_text()
  flush_atom()
  return cursor - iy
end

-- Text sitting directly in a flex container is an anonymous block box: it
-- inherits typography from the container but none of its box decoration. Laying
-- it out with the container's own style instead re-entered layout_flex with a
-- fresh text child until the Lua stack overflowed.
local function anonymous_block_style(st)
  local copy = {}
  for k, v in pairs(st) do
    copy[k] = v
  end
  copy.display = "block"
  copy.position = "static"
  copy.width = nil
  copy.height = nil
  copy.min_height = nil
  copy.max_height = nil
  copy.flex_grow = 0
  copy.background = nil
  copy.background_image = nil
  copy.border_width = "0"
  copy.border_radius = 0
  copy.padding_top = "0"
  copy.padding_right = "0"
  copy.padding_bottom = "0"
  copy.padding_left = "0"
  copy.margin_top = "0"
  copy.margin_right = "0"
  copy.margin_bottom = "0"
  copy.margin_left = "0"
  return copy
end

local function layout_flex(node, st, ix, iy, iw, ctx, box)
  local kids = {}
  for _, child in ipairs(node.children or {}) do
    if child.type == "element" then
      local cst = ctx.styles[child]
      if cst and cst.display ~= "none" then
        kids[#kids + 1] = { node = child, st = cst }
      end
    elseif child.type == "text" and child.text:match("%S") then
      kids[#kids + 1] = { text = child.text, st = anonymous_block_style(st) }
    end
  end
  if #kids == 0 then
    return 0
  end

  local gap
  if st.flex_direction == "column" then
    gap = len(st.row_gap, iw, "y") or 0
  else
    gap = len(st.column_gap, iw, "x") or 0
  end
  gap = math.floor(gap + 0.5)

  if st.flex_direction == "column" then
    local cursor = iy
    for i, k in ipairs(kids) do
      if i > 1 then
        cursor = cursor + gap
      end
      local w = k.node and len(k.st.width, iw, "x") or nil
      local ml = k.node and (len(k.st.margin_left, iw, "x") or 0) or 0
      local mr = k.node and (len(k.st.margin_right, iw, "x") or 0) or 0
      local cw = w or math.max(1, iw - rnd(ml) - rnd(mr))
      local x = ix + rnd(ml)
      if st.align_items == "center" then
        x = ix + math.max(0, math.floor((iw - cw) / 2))
      elseif st.align_items == "flex-end" then
        x = ix + math.max(0, iw - cw)
      end
      local target = k.node
      if not target then
        target = {
          type = "element", tag = "#text", attrs = {}, parent = node,
          children = { { type = "text", text = k.text } },
        }
      end
      local b = layout_node(target, k.st, math.floor(x), cursor, math.max(1, math.floor(cw)), ctx)
      box.children[#box.children + 1] = b
      cursor = cursor + b.h
    end
    return cursor - iy
  end

  -- Row: widths first, then positions, then heights.
  local n = #kids
  local widths, grows = {}, 0
  local total = 0
  for i, k in ipairs(kids) do
    local base
    if k.node then
      base = intrinsic_width(k.node, k.st, ctx, iw)
      grows = grows + (k.st.flex_grow or 0)
    else
      base = math.min(iw, ctx.width(k.text))
    end
    widths[i] = math.max(1, math.floor(base))
    total = total + widths[i]
  end

  local gaps = gap * (n - 1)
  local free = iw - total - gaps
  if free > 0 and grows > 0 then
    for i, k in ipairs(kids) do
      local g = (k.node and k.st.flex_grow) or 0
      if g > 0 then
        widths[i] = widths[i] + math.floor(free * g / grows)
      end
    end
    total = 0
    for i = 1, n do
      total = total + widths[i]
    end
    free = iw - total - gaps
  end

  local start, between = 0, 0
  if free > 0 then
    local jc = st.justify_content
    if jc == "center" then
      start = free / 2
    elseif jc == "flex-end" then
      start = free
    elseif jc == "space-between" and n > 1 then
      between = free / (n - 1)
    elseif jc == "space-around" then
      between = free / n
      start = between / 2
    end
  end

  local x = ix + math.floor(start)
  local placed = {}
  local maxh = 0
  for i, k in ipairs(kids) do
    local w = math.max(1, widths[i])
    local target = k.node
    if not target then
      target = {
        type = "element", tag = "#text", attrs = {}, parent = node,
        children = { { type = "text", text = k.text } },
      }
    end
    local b = layout_node(target, k.st, x, iy, w, ctx)
    box.children[#box.children + 1] = b
    placed[#placed + 1] = b
    maxh = math.max(maxh, b.h)
    x = x + w + gap + math.floor(between)
  end

  for _, b in ipairs(placed) do
    if st.align_items == "center" then
      shift_box(b, 0, math.floor((maxh - b.h) / 2))
    elseif st.align_items == "flex-end" then
      shift_box(b, 0, maxh - b.h)
    elseif st.align_items == "stretch" then
      b.fill_h = maxh
    end
  end

  return maxh
end

layout_node = function(node, st, x, y, w, ctx)
  ensure_children(node)
  local box = new_box(node, st, x, y, w)
  ctx.boxes[#ctx.boxes + 1] = box

  local bw = border_cells(st)
  local pl = len(st.padding_left, w, "x") or 0
  local pr = len(st.padding_right, w, "x") or 0
  local pt = len(st.padding_top, w, "y") or 0
  local pb = len(st.padding_bottom, w, "y") or 0

  local ix = x + bw + rnd(pl)
  local iy = y + bw + rnd(pt)
  local iw = math.max(1, w - bw * 2 - rnd(pl) - rnd(pr))

  local content_h
  if st.display == "flex" or st.display == "table" then
    content_h = layout_flex(node, st, ix, iy, iw, ctx, box)
  else
    content_h = layout_flow(node, st, ix, iy, iw, ctx, box)
  end

  local h = content_h + rnd(pt) + rnd(pb) + bw * 2
  local explicit = len(st.height, ctx.viewport_h, "y")
  local min_h = len(st.min_height, ctx.viewport_h, "y")
  local max_h = len(st.max_height, ctx.viewport_h, "y")
  if min_h and h < min_h then
    h = min_h
  end
  if max_h and h > max_h then
    h = max_h
  end
  if explicit then
    h = explicit
  end
  box.h = math.max(1, rnd(h))
  box.content_h = content_h
  return box
end

function M.build(root, styles, cols, rows, opts)
  opts = opts or {}
  local ctx = {
    styles = styles,
    boxes = {},
    viewport_w = cols,
    viewport_h = rows,
    width = opts.width or function(s)
      return #s
    end,
    sub_width = opts.sub_width or function(s, n)
      return s:sub(1, n), math.min(#s, n)
    end,
  }

  local body = nil
  local top = {}
  local function find(n)
    if n.type == "element" and n.tag == "body" then
      body = n
      return
    end
    if n.type == "element" and n.tag == "html" then
      for _, c in ipairs(n.children) do
        if c.type == "element" and c.tag == "body" then
          body = c
          return
        end
      end
    end
    for _, c in ipairs(n.children or {}) do
      find(c)
    end
  end
  find(root)

  if not body then
    local children = {}
    for _, c in ipairs(root.children) do
      if c.type == "element" and c.tag ~= "style" and c.tag ~= "script" and c.tag ~= "head" then
        children[#children + 1] = c
      end
    end
    body = { type = "element", tag = "body", attrs = {}, children = children, parent = root }
    for _, c in ipairs(children) do
      c.parent = body
    end
  end

  local st = styles[body]
  if not st then
    st = {
      display = "block",
      font_size = 16,
      text_align = "left",
      white_space = "normal",
      overflow = "visible",
      margin_top = "0", margin_right = "0", margin_bottom = "0", margin_left = "0",
      padding_top = "0", padding_right = "0", padding_bottom = "0", padding_left = "0",
      border_width = "0", border_color = "#888888", border_radius = 0,
      flex_direction = "row", justify_content = "flex-start", align_items = "stretch",
      flex_grow = 0, gap = "0", row_gap = "0", column_gap = "0",
      position = "static", opacity = 1, vars = {},
    }
  end

  local body_box = layout_node(body, st, 0, 0, cols, ctx)

  -- Absolute positioning is approximated against the page: left/top or
  -- right/bottom in px/% from the canvas edges. Nested absolute boxes move
  -- with their parent.
  for _, box in ipairs(ctx.boxes) do
    local pst = box.style
    local parent_style = box.node and box.node.parent and styles[box.node.parent]
    if pst.position == "absolute" and not (parent_style and parent_style.position == "absolute") then
      local nx, ny = box.x, box.y
      local l = len(pst.left, ctx.viewport_w, "x")
      local t = len(pst.top, ctx.viewport_h, "y")
      local r = len(pst.right, ctx.viewport_w, "x")
      local b = len(pst.bottom, ctx.viewport_h, "y")
      if l then
        nx = rnd(l)
      elseif r then
        nx = ctx.viewport_w - box.w - rnd(r)
      end
      if t then
        ny = rnd(t)
      elseif b then
        ny = ctx.viewport_h - box.h - rnd(b)
      end
      shift_box(box, nx - box.x, ny - box.y)
    end
  end

  return {
    boxes = ctx.boxes,
    body = body_box,
    width = cols,
    height = rows,
    overflow = body_box.h > rows,
    ctx = ctx,
  }
end

M.shift_box = shift_box

return M
