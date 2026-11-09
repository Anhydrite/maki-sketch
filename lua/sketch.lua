-- /sketch: a terminal design canvas.
--
-- The agent writes HTML/CSS, this module renders it into a left-docked pane
-- with numbered points, and a click writes `#N` into the chat input so the
-- user can answer "#3 I don't like that".

local paint = require("sketch.paint")
local points = require("sketch.points")
local render = require("sketch.render")
local pane = require("sketch.pane")
local store = require("sketch.store")
local text = require("sketch.text")

local BUILD = "2026-11-09-scroll"

local M = {}

local config = {
  width = "60%",
  persist = true,
  -- The design always lives in the docked pane: that is the point of the
  -- feature. Clicks still come from the chat mirror, maki never routes the
  -- mouse to a split.
  max_cols = 140,
  max_rows = 80,
}

-- session id -> scene
local scenes = {}

-- session id -> true while the user is working in sketch mode. The mode can
-- be on with an empty canvas: the agent still has to know the chat is about
-- the design surface.
local sketch_on = {}

local WELCOME = {
  { { " sketch ", { fg = "#61afef", bold = true } } },
  { { " canvas vide", "dim" } },
  { { " " } },
  { { " Demande a l'agent de dessiner, par exemple :" } },
  { { "   « dessine un mockup de page de login »" } },
  { { " " } },
  { { " data-point=\"label\"", { fg = "#61afef" } }, { " numerote un element." } },
}

local rules_done = false
local function ensure_input_rules()
  if rules_done then
    return
  end
  rules_done = true
  pcall(maki.ui.input_rules, {
    ns = "sketch",
    pattern = [[#(\d+)]],
    mark = { hl = "accent", bold = true },
  })
end

local function cwd_for(sid)
  local ok, session = pcall(maki.session.read, { session = sid })
  if ok and session and session.cwd then
    return session.cwd
  end
  return maki.uv.cwd()
end

local function width_fn(s)
  local ok, w = pcall(maki.ui.display_width, s)
  if ok and type(w) == "number" then
    return w
  end
  return text.width(s)
end

local function theme()
  local function col(name, fallback)
    local ok, value = pcall(maki.ui.theme_color, name)
    if ok and value and value ~= "" then
      return value
    end
    return fallback
  end
  local fg = col("foreground", nil)
  local bg = col("background", nil)
  local accent = col("accent", "#61afef")
  return {
    fg = fg,
    bg = bg,
    accent = accent,
    accent_fg = bg or "#000000",
  }
end

local function current_session()
  local ok, sid = pcall(maki.session.current)
  if ok then
    return sid
  end
  return nil
end

local function pane_title(scene)
  local title = " sketch "
  if scene.version then
    title = string.format(" sketch · v%d ", scene.version)
  end
  if scene.content_rows and scene.content_rows > scene.view_rows then
    local first = (scene.offset or 0) + 1
    local last = math.min(scene.content_rows, first + scene.view_rows - 1)
    title = title:gsub("%s+$", "") .. string.format(" · %d-%d/%d ", first, last, scene.content_rows)
  end
  if scene.selected then
    local p = scene.points[scene.selected]
    if p then
      title = title:gsub("%s+$", "") .. " · #" .. p.n .. " " .. p.label .. " "
    end
  end
  return title
end

-- The chat body mirrors the canvas one line per row: a click only reports a
-- row, so the mirror must stay 1:1 with the design for the mapping to hold.
-- The 4-cell gutter carries the number the user dropped on that line.
local function body_lines(scene)
  local accent = theme().accent
  -- A bitmap scene carries no glyphs to mirror: the transcript shows the image.
  if scene.mirror then
    return scene.mirror
  end
  local source = scene.lines_clean or scene.lines
  local out = {}
  local count = math.min(scene.view_rows or scene.canvas_rows or #source, #source)
  -- Drop the blank tail: the mirror would otherwise push dozens of empty
  -- lines into the transcript. Row numbers stay valid, they are 1-based.
  local last = 0
  for i = 1, count do
    local marked = scene.marks_by_row and scene.marks_by_row[i]
    local text = ""
    for _, span in ipairs(source[i] or {}) do
      text = text .. tostring(span[1] or "")
    end
    if marked or text:match("%S") then
      last = i
    end
  end
  count = math.max(last, 1)
  for i = 1, count do
    local mark = scene.marks_by_row and scene.marks_by_row[i]
    local spans = {
      {
        string.format("%-4s ", mark and ("#" .. mark) or ""),
        mark and { fg = accent, bold = true } or "dim",
      },
    }
    for _, span in ipairs(source[i] or {}) do
      spans[#spans + 1] = span
    end
    out[i] = spans
  end
  return out
end

local function row_text(scene, row)
  local cells = scene.grid and scene.grid[row]
  if not cells then
    return ""
  end
  local parts = {}
  for x = 1, #cells do
    parts[#parts + 1] = cells[x].ch or ""
  end
  return (table.concat(parts):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function marks_inventory(scene)
  local keys = {}
  for n in pairs(scene.marks or {}) do
    keys[#keys + 1] = n
  end
  table.sort(keys)
  local parts = {}
  for _, n in ipairs(keys) do
    parts[#parts + 1] = string.format("%d=l%d", n, scene.marks[n].row)
  end
  return table.concat(parts, " ")
end

-- Drops a number on the clicked line; the same line reuses its number.
-- Marks are stored in content coordinates so they follow the design when the
-- pane scrolls, and re-projected onto screen rows at each render.
local function mark_row(sid, scene, row)
  local existing = scene.marks_by_row[row]
  if existing then
    return existing
  end
  local n = #scene.points
  for key in pairs(scene.marks) do
    if key > n then
      n = key
    end
  end
  n = n + 1
  scene.marks[n] = {
    row = row + (scene.offset or 0),
    text = row_text(scene, row),
  }
  scene.marks_by_row[row] = n
  paint.stamp_marks(scene.grid, scene.marks_by_row, {
    cols = scene.cols,
    accent = theme().accent,
    bg = theme().bg,
  })
  scene.lines = paint.to_lines(scene.grid, { bg = theme().bg })
  pane.update(sid, scene.lines, pane_title(scene))
  maki.log.info(string.format("sketch: mark %d on row %d", n, row))
  return n
end

-- Without the side pane the design is laid out for the chat column. The width
-- is capped so a wide terminal does not stretch a design authored for ~124
-- cells, and the height is generous: the transcript scrolls, so nothing needs
-- clipping here.
local function chat_size()
  local ok, ts = pcall(maki.ui.terminal_size)
  local cols = 110
  if ok and ts and ts.cols then
    cols = math.max(40, math.min(ts.cols - 8, config.max_cols or 140))
  end
  return cols, config.max_rows or 80
end

local function render_scene(sid, html, title, persist, selected, offset)
  ensure_input_rules()
  sketch_on[sid] = true
  -- The pane is the canvas. Without a real terminal (maki -p) the tool body
  -- carries the design instead, so fall back to the chat budget.
  local p = pane.ensure(sid, config)
  local cols, rows
  if p and pane.is_open(sid) then
    cols, rows = pane.size(sid, config)
  else
    cols, rows = chat_size()
  end
  if not cols or not rows then
    cols, rows = 100, 30
  end

  local previous = scenes[sid]
  local same = previous and previous.html == html
  if offset == nil then
    offset = (same and previous.offset) or 0
  end

  local colours = theme()

  local composed = render.compose(html, cols, rows, {
    width = width_fn,
    bg = colours.bg,
    fg = colours.fg,
    accent = colours.accent,
    accent_fg = colours.accent_fg,
    selected = selected,
    offset = offset,
  })
  local found = composed.points
  local content_rows = composed.content_rows
  local view_rows = composed.view_rows
  local scroll = composed.offset or 0
  local grid = composed.grid
  local css_report = composed.report or {}

  -- Marks live in content coordinates, so writing one while scrolled lands on
  -- the design row the user clicked, not on the pane row number.
  local marks = (same and previous.marks) or {}
  local marks_by_row = {}
  for n, m in pairs(marks) do
    local screen_row = (m.row or 0) - scroll
    if screen_row >= 1 and screen_row <= view_rows then
      marks_by_row[screen_row] = n
    end
  end

  local scene = {
    html = html,
    title = title or "",
    cols = cols,
    rows = view_rows,
    view_rows = view_rows,
    content_rows = content_rows,
    canvas_rows = content_rows,
    offset = scroll,
    max_offset = composed.max_offset or 0,
    -- A redraw or a scroll is not a new version: keep the label from the
    -- render that was persisted.
    version = same and previous.version or nil,
    points = found,
    selected = selected,
    -- Keep the click-cycle position while the same design is redrawn.
    cycle = (same and previous.cycle) or {},
    -- User marks (numbers dropped by clicking a line) survive a redraw of the
    -- same design, and die with it.
    marks = marks,
    marks_by_row = marks_by_row,
    unsupported = css_report,
    sid = sid,
    updated = os.time(),
  }

  -- The unstamped lines are what the chat mirror shows: the right-edge stamp
  -- would wrap in the narrower chat column and land on the next row.
  scene.lines_clean = paint.to_lines(grid, { bg = colours.bg })
  paint.stamp_marks(grid, scene.marks_by_row, { cols = cols, accent = colours.accent, bg = colours.bg })
  scene.lines = paint.to_lines(grid, { bg = colours.bg })
  scene.grid = grid
  scene.row_map = points.row_map(found, { offset = scroll, rows = view_rows })
  scene.inventory = points.inventory(found)
  scene.overflow = content_rows > view_rows

  local mark_inv = marks_inventory(scene)
  local summary = string.format("sketch %dx%d cells", cols, content_rows)
  if scene.overflow then
    summary = summary .. string.format(
      " · view %d-%d/%d (scroll: M-j/k, M-d/u, M-g/G)",
      scroll + 1,
      math.min(content_rows, scroll + view_rows),
      content_rows
    )
  end
  if scene.inventory ~= "" then
    summary = summary .. " · points: " .. scene.inventory
  else
    summary = summary .. " · no points (add data-point=\"label\" to an element)"
  end
  if mark_inv ~= "" then
    summary = summary .. " · marks: " .. mark_inv
  end
  if #css_report > 0 then
    summary = summary .. " · ignored: " .. table.concat(css_report, ", ")
  end
  scene.summary = summary

  if persist then
    local cwd = cwd_for(sid)
    local version, err = store.save(cwd, html, title or "", scene.inventory)
    if version then
      scene.version = version
    else
      maki.log.warn("sketch: could not save the design: " .. tostring(err))
    end
  end

  scenes[sid] = scene
  local footer = scene.overflow and {
    { "M-j/k", "scroll" },
    { "M-d/u", "page" },
    { "M-g/G", "top/bottom" },
  } or {}
  pane.update(sid, scene.lines, pane_title(scene), footer)
  maki.log.info(string.format("sketch: rendered %dx%d, %d points", cols, content_rows, #found))

  return scene
end

local function redraw(sid)
  local scene = scenes[sid]
  if not scene then
    return
  end
  local ok, err = pcall(render_scene, sid, scene.html, scene.title, false, scene.selected, scene.offset)
  if not ok then
    maki.log.warn("sketch: redraw failed: " .. tostring(err))
  end
end

local function scroll_to(sid, target)
  local scene = scenes[sid]
  if not scene then
    return
  end
  if (scene.content_rows or 0) <= (scene.view_rows or 0) then
    pcall(maki.ui.flash, "sketch: le design tient dans le canvas")
    return
  end
  local max = scene.max_offset or math.max(0, (scene.content_rows or 0) - (scene.view_rows or 0))
  local offset = math.max(0, math.min(max, math.floor(tonumber(target) or 0)))
  if offset == scene.offset then
    pcall(maki.ui.flash, offset == 0 and "sketch: déjà en haut" or "sketch: déjà en bas")
    return
  end
  render_scene(sid, scene.html, scene.title, false, scene.selected, offset)
end

local function scroll_by(sid, delta)
  local scene = scenes[sid]
  if not scene then
    return
  end
  scroll_to(sid, (scene.offset or 0) + delta)
end

local function insert_ref(token)
  local ok, st = pcall(maki.ui.input)
  if not ok or not st then
    return false
  end
  local current = st.text or ""
  local at = #current
  local prefix = ""
  if at > 0 and not current:sub(at):match("%s") then
    prefix = " "
  end
  local payload = prefix .. token .. " "
  local done = maki.ui.input_edit({
    start = at,
    stop = at,
    text = payload,
    cursor = at + #payload,
    version = st.version,
    session_id = st.session_id,
  })
  if not done then
    pcall(maki.ui.flash, "sketch: could not write into the prompt")
    return false
  end
  return true
end

local function pick(sid, n)
  local scene = scenes[sid]
  if not scene then
    return
  end
  local point = scene.points[n]
  if not point then
    return
  end
  maki.log.info(string.format("sketch: pick %d (%s)", n, point.label))
  if not insert_ref("#" .. n) then
    maki.log.warn("sketch: could not write the reference for point " .. n)
  end
  pcall(maki.ui.flash, string.format("point %d → #%d %s", n, n, point.label))
  render_scene(sid, scene.html, scene.title, false, n, scene.offset)
end

pane.on_key = function(sid, key)
  local scene = scenes[sid]
  if not scene then
    return
  end
  local page = math.max(1, math.floor((scene.view_rows or 10) / 2))
  if key == "<M-j>" or key == "<M-Down>" then
    scroll_by(sid, 1)
  elseif key == "<M-k>" or key == "<M-Up>" then
    scroll_by(sid, -1)
  elseif key == "<M-d>" or key == "<M-PageDown>" then
    scroll_by(sid, page)
  elseif key == "<M-u>" or key == "<M-PageUp>" then
    scroll_by(sid, -page)
  elseif key == "<M-g>" then
    scroll_to(sid, 0)
  elseif key == "<M-G>" then
    scroll_to(sid, math.huge)
  end
end

pane.on_scroll = function(sid, delta)
  scroll_by(sid, delta)
end

pane.on_click = function(sid, row)
  local scene = scenes[sid]
  if not scene or row < 1 then
    return
  end
  local list = scene.row_map[row]
  if not list or #list == 0 then
    pcall(maki.ui.flash, string.format("sketch: no point on row %d", row))
    return
  end
  local n
  if #list == 1 then
    n = list[1]
  else
    local key = tostring(row)
    scene.cycle[key] = (scene.cycle[key] or 0) + 1
    n = list[(scene.cycle[key] - 1) % #list + 1]
  end
  pick(sid, n)
end

-- A drag-resize fires dozens of events; the screenshot costs half a second,
-- so only the last geometry is rendered. Stale captures are dropped by the
-- cast's generation counter.
local resize_gen = 0
pane.on_resize = function(sid)
  resize_gen = resize_gen + 1
  local gen = resize_gen
  maki.async.spawn(function()
    maki.async.sleep(280)
    if gen ~= resize_gen then
      return
    end
    redraw(sid)
  end)
end

-- Public entry point used by the tool.
function M.render(sid, html, title)
  return render_scene(sid, html, title, true)
end

function M.setup(opts)
  for k, v in pairs(opts or {}) do
    config[k] = v
  end
  return M
end

-- Slash command ------------------------------------------------------------

local function open(sid)
  ensure_input_rules()
  sketch_on[sid] = true
  pcall(maki.ui.set_status_hint, {
    { "sketch", "canvas" },
    { "#N", "point" },
  }, { session = sid })
  pane.ensure(sid, config)
  local scene = scenes[sid]
  if scene then
    render_scene(sid, scene.html, scene.title or "", false)
  else
    -- A reload wipes the in-memory scene; reopen on the last saved design so
    -- the canvas comes back instead of the welcome screen.
    local last = store.load(cwd_for(sid))
    if last and type(last.html) == "string" and last.html ~= "" then
      render_scene(sid, last.html, last.title or "", false)
    else
      pane.update(sid, WELCOME, " sketch ")
    end
  end
  pcall(maki.ui.flash, "sketch: panneau ouvert")
end

local function clear(sid)
  scenes[sid] = nil
  pane.update(sid, WELCOME, " sketch ")
  pcall(maki.ui.flash, "sketch: canvas vide")
end

local function export(sid, path)
  local scene = scenes[sid]
  if not scene then
    local state = store.load(cwd_for(sid))
    if not state then
      pcall(maki.ui.flash, "sketch: rien à exporter")
      return
    end
    scene = state
  end
  local ok, err = store.export(cwd_for(sid), path, scene.html)
  if ok then
    pcall(maki.ui.flash, "sketch: exporté vers " .. (path or ".sketch/export.html"))
  else
    pcall(maki.ui.flash, "sketch: export échoué: " .. tostring(err))
  end
end

local function versions(sid)
  local dir = store.dir(cwd_for(sid))
  local listed = maki.fs.glob("v*.html", { path = dir, sort = "name" })
  if not listed or #listed == 0 then
    pcall(maki.ui.flash, "sketch: aucune version")
    return
  end
  local names = {}
  for _, path in ipairs(listed) do
    names[#names + 1] = maki.fs.basename(path)
  end
  local tail = {}
  for i = math.max(1, #names - 2), #names do
    tail[#tail + 1] = names[i]
  end
  pcall(maki.ui.flash, string.format("sketch: %d versions (%s)", #names, table.concat(tail, ", ")))
end

local function selftest()
  local ok, report = pcall(function()
    return require("sketch.selftest").run()
  end)
  if not ok then
    maki.log.error("sketch: selftest crashed: " .. tostring(report))
    pcall(maki.ui.flash, "sketch selftest: CRASH (voir le log)")
    return
  end
  maki.log.info("sketch selftest\n" .. report)
  local first = report:match("^[^\n]+") or "selftest"
  pcall(maki.ui.flash, "sketch " .. first)
end

maki.api.register_command({
  name = "/sketch",
  description = "Terminal design canvas (HTML/CSS, numbered points)",
  nargs = "*",
  handler = function(opts)
    local args = opts.fargs or {}
    local sub = (args[1] or ""):lower()
    local sid = current_session()

    if sub == "selftest" then
      selftest()
      return
    end
    if not sid then
      pcall(maki.ui.flash, "sketch: aucune session focus")
      return
    end

    if sub == "" or sub == "open" then
      open(sid)
    elseif sub == "close" then
      pane.close(sid)
      scenes[sid] = nil
      sketch_on[sid] = nil
      pcall(maki.ui.set_status_hint, nil, { session = sid })
      pcall(maki.ui.flash, "sketch: canvas fermé")
    elseif sub == "clear" then
      clear(sid)
    elseif sub == "width" then
      local value = args[2]
      if value and value:match("^%d+%%?$") then
        if not value:match("%%$") then
          value = value .. "%"
        end
        config.width = value
        local s = pane.get(sid)
        if s then
          pcall(s.win.set_config, s.win, { width = value })
          maki.defer_fn(function()
            redraw(sid)
          end, 150)
        end
        pcall(maki.ui.flash, "sketch: largeur " .. value)
      else
        pcall(maki.ui.flash, "sketch: /sketch width 70%")
      end
    elseif sub == "mark" or sub == "pick" then
      local scene = scenes[sid]
      local n = tonumber(args[2] or "")
      local visible = scene and (scene.view_rows or scene.canvas_rows) or 0
      if not scene then
        pcall(maki.ui.flash, "sketch: aucun canvas, fais un rendu d'abord")
      elseif not n then
        pcall(maki.ui.flash, string.format("sketch: /sketch %s <numero 1-%d>", sub, visible))
      elseif sub == "pick" then
        pick(sid, n)
      elseif n < 1 or n > visible then
        pcall(maki.ui.flash, string.format("sketch: ligne hors du canvas (1-%d)", visible))
      else
        local mark = mark_row(sid, scene, n)
        insert_ref("#" .. mark)
        pcall(maki.ui.flash, string.format("#%d posé sur la ligne %d", mark, n))
      end
    elseif sub == "scroll" then
      local scene = scenes[sid]
      local arg = (args[2] or ""):lower()
      local page = scene and math.max(1, math.floor((scene.view_rows or 10) / 2)) or 1
      if not scene then
        pcall(maki.ui.flash, "sketch: aucun canvas, fais un rendu d'abord")
      elseif arg == "" then
        pcall(maki.ui.flash, string.format(
          "sketch: lignes %d-%d sur %d",
          (scene.offset or 0) + 1,
          math.min(scene.content_rows or 0, (scene.offset or 0) + (scene.view_rows or 0)),
          scene.content_rows or 0
        ))
      elseif arg == "top" then
        scroll_to(sid, 0)
      elseif arg == "bottom" then
        scroll_to(sid, math.huge)
      elseif arg == "up" then
        scroll_by(sid, -3)
      elseif arg == "down" then
        scroll_by(sid, 3)
      elseif arg == "page-up" then
        scroll_by(sid, -page)
      elseif arg == "page-down" then
        scroll_by(sid, page)
      else
        local n = tonumber(arg)
        if not n then
          pcall(maki.ui.flash, "sketch: /sketch scroll [up|down|page-up|page-down|top|bottom|<ligne>]")
        elseif arg:sub(1, 1) == "+" or arg:sub(1, 1) == "-" then
          scroll_by(sid, n)
        else
          scroll_to(sid, n)
        end
      end
    elseif sub == "points" then
      local scene = scenes[sid]
      if scene and scene.inventory ~= "" then
        pcall(maki.ui.flash, scene.inventory)
      else
        pcall(maki.ui.flash, "sketch: aucun point")
      end
    elseif sub == "export" then
      export(sid, args[2])
    elseif sub == "versions" then
      versions(sid)
    else
      pcall(maki.ui.flash, "sketch: open|close|clear|width|scroll|points|mark <ligne>|pick <n>|export|versions|selftest")
    end
  end,
})

-- Tools --------------------------------------------------------------------

maki.api.register_tool({
  name = "sketch_render",
  description = [[Render an HTML/CSS design into the user's terminal canvas.

The canvas is docked on the left; the user sees the design while reading this
chat. A small built-in engine lays the HTML out on a terminal cell grid
(1 cell = 8 x 16 CSS px): flex, borders, colours and backgrounds work; images,
shadows, gradients, transforms and real fonts are ignored and reported back.
Write a fragment or a whole document.

The pane is a picture: elements are not clickable there. The tool body is a
1:1 mirror in the chat, and clicking a line picks a data-point or writes #N.
The user can also refer to regions by position ("the second column", "the dark
block at the top").

The layout is fluid at the pane size. A design taller than the pane keeps its
height and scrolls; use percentages and flex rather than fixed page sizes.]],
  kind = "ui",
  audiences = { "main" },
  schema = {
    type = "object",
    properties = {
      html = {
        type = "string",
        description = "HTML document or fragment. Laid out by the built-in cell-grid CSS engine.",
      },
      title = { type = "string", description = "Short label for this version." },
    },
    required = { "html" },
  },
  -- Rebuilds the clickable point list from the saved output when the runtime
  -- replays a click on an old tool row (session reload, theme rebake).
  restore = function(_input, output, is_error)
    local buf = maki.ui.buf()
    local rows = is_error and {} or points.parse_inventory(output)
    if #rows == 0 then
      buf:line({ { " aucun point", "dim" } })
      return buf
    end
    for _, r in ipairs(rows) do
      buf:line({
        { tostring(r.n), { bold = true } },
        { string.format("  %-18s", "#" .. r.label) },
        { r.dims, "dim" },
      })
    end
    buf:on("click", function(ev)
      local row = ev and ev.row or 0
      maki.log.info(string.format("sketch: restored click row=%d", row))
      local r = rows[row]
      if r then
        insert_ref("#" .. r.n)
        pcall(maki.ui.flash, string.format("point %d → #%d %s", r.n, r.n, r.label))
      end
    end)
    return buf
  end,

  handler = function(input, ctx)
    local sid = ctx and ctx:session_id() or current_session()
    if not sid then
      return { llm_output = "error: no focused session", is_error = true }
    end
    if type(input.html) ~= "string" or input.html == "" then
      return { llm_output = "error: html is required", is_error = true }
    end

    local ok, scene = pcall(render_scene, sid, input.html, input.title or "", true)
    if not ok then
      maki.log.error("sketch: render failed: " .. tostring(scene))
      return { llm_output = "error: " .. tostring(scene), is_error = true }
    end

    -- maki 0.7 only routes mouse clicks through the chat transcript (a click
    -- never lands on a docked split), so the body is a 1:1 mirror of the
    -- canvas: clicking any line either picks the data-point that covers it or
    -- drops a number on that line.
    local body = maki.ui.buf()
    body:set_lines(body_lines(scene))
    body:on("click", function(ev)
      local row = ev and ev.row or 0
      maki.log.info(string.format("sketch: body click row=%d", row))
      local current = scenes[sid]
      if not current or current.html ~= scene.html then
        pcall(maki.ui.flash, "sketch: rendu obsolète, utilise le dernier")
        return
      end
      if row < 1 then
        return
      end
      local list = current.row_map[row]
      if list and #list > 0 then
        local n
        if #list == 1 then
          n = list[1]
        else
          local key = tostring(row)
          current.cycle[key] = (current.cycle[key] or 0) + 1
          n = list[(current.cycle[key] - 1) % #list + 1]
        end
        pick(sid, n)
        body:set_lines(body_lines(current))
        return
      end
      if row > (current.view_rows or current.canvas_rows or 0) then
        pcall(maki.ui.flash, "sketch: hors du design, clique une ligne du dessin")
        return
      end
      local n = mark_row(sid, current, row)
      local wrote = insert_ref("#" .. n)
      maki.log.info(string.format("sketch: mark %d row %d inserted=%s", n, row, tostring(wrote)))
      if wrote then
        pcall(maki.ui.flash, string.format("#%d posé sur la ligne %d", n, row))
      else
        pcall(maki.ui.flash, string.format("#%d posé (prompt non modifiable)", n))
      end
      body:set_lines(body_lines(current))
    end)

    -- Register the body as this call's live buffer. Without it the UI never
    -- puts the buf in its watched set, and a click on a finished tool is
    -- dropped unless the tool has a `restore` hook: `toggle_at` sends the
    -- restore request and finds no item to replay.
    if ctx then
      local lok, lerr = pcall(function()
        return ctx:live_buf(body)
      end)
      if not lok then
        maki.log.warn("sketch: live_buf failed: " .. tostring(lerr))
      end
    end

    local output = scene.summary
    if scene.content_rows > scene.view_rows then
      output = output .. " · content taller than the canvas (scroll with M-j/k, M-d/u, M-g/G)"
    end

    return {
      llm_output = output,
      body = body,
      annotation = string.format("%dx%d", scene.cols, scene.canvas_rows),
      state = { version = scene.version, inventory = scene.inventory },
    }
  end,
})

maki.api.register_tool({
  name = "sketch_state",
  description = [[Read the current terminal-canvas sketch: its numbered points
and, unless include_html is false, the HTML source last rendered. Use it when
the user refers to "#N" and the inventory is not in context anymore.]],
  kind = "ui",
  audiences = { "main" },
  schema = {
    type = "object",
    properties = {
      include_html = { type = "boolean", description = "Include the HTML source (default true)." },
    },
  },
  handler = function(input, ctx)
    local sid = ctx and ctx:session_id() or current_session()
    local scene = sid and scenes[sid] or nil
    if not scene then
      local sid2 = sid or current_session()
      if sid2 then
        local state = store.load(cwd_for(sid2))
        if state then
          local out = string.format("sketch v%d · points: %s", state.version or 0, state.points or "")
          if input.include_html ~= false and state.html then
            out = out .. "\n\n--- html ---\n" .. state.html
          end
          return out
        end
      end
      return "no sketch rendered yet"
    end

    local out = scene.summary
    local keys = {}
    for n in pairs(scene.marks or {}) do
      keys[#keys + 1] = n
    end
    if #keys > 0 then
      table.sort(keys)
      local lines = {}
      for _, n in ipairs(keys) do
        local m = scene.marks[n]
        lines[#lines + 1] = string.format("#%d (ligne %d) : %s", n, m.row, m.text)
      end
      out = out .. "\n\n--- marks ---\n" .. table.concat(lines, "\n")
    end
    if input.include_html ~= false then
      out = out .. "\n\n--- html ---\n" .. scene.html
    end
    return out
  end,
})

-- Prompt hint --------------------------------------------------------------

maki.api.register_prompt_hint({
  slot = "tool_usage",
  content = function()
    local sid = current_session()
    if not sid then
      return ""
    end
    local scene = scenes[sid]
    if not sketch_on[sid] and not scene then
      return ""
    end

    local cols, rows
    if scene then
      cols, rows = scene.cols, scene.canvas_rows
    else
      cols, rows = pane.size(sid, config)
      rows = rows and math.max(3, rows - 3) or 27
    end
    cols = cols or 110
    local canvas_h = rows or 27
    local inventory = scene and scene.inventory or ""

    local lines = {
      "SKETCH MODE: the user is designing in a terminal canvas docked on the left; this chat is its control panel.",
      "- Treat every request as a change to the canvas. Answer by calling sketch_render with the FULL updated HTML, then say in one short line what changed. Do not describe the design in prose instead of rendering it.",
      string.format(
        "- Canvas: %dx%d cells. The built-in engine lays the HTML out at %dx%d CSS px (1 cell = 8x16) and paints it into the pane: flex, borders and colours work; images, shadows and gradients do not.",
        cols,
        canvas_h,
        cols * 8,
        canvas_h * 16
      ),
      "- The canvas is a picture: no element is clickable or numbered. When the user points at something, it is by position (\"la 2e colonne\", \"le bloc du haut\"), not by a #N badge.",
    }
    if scene then
      lines[#lines + 1] = string.format(
        "- Last render: v%s%s.",
        tostring(scene.version or "?"),
        scene.title ~= "" and (" \"" .. scene.title .. "\"") or ""
      )
    else
      lines[#lines + 1] = "- The canvas is still empty: render the first design."
    end
    return table.concat(lines, "\n")
  end,
})

-- Lifecycle ----------------------------------------------------------------

maki.api.create_autocmd({ "SessionReset", "SessionEnd" }, {
  callback = function(ev)
    local sid = ev.data and ev.data.session_id
    if sid then
      scenes[sid] = nil
      sketch_on[sid] = nil
    end
  end,
})

maki.api.create_autocmd({ "TurnStart", "SessionFocusChanged" }, {
  callback = function(ev)
    local sid = ev.data and ev.data.session_id
    if sid and scenes[sid] and pane.is_open(sid) then
      redraw(sid)
    end
  end,
})

-- Development helper: `MAKI_SKETCH_SELFTEST=1 maki index README.md` runs the
-- pure-module tests at load and writes the report to the log, without a UI.
-- It needs the `env` permission, so it is enabled by the temporary manifest
-- used in the dev loop, not by the shipped one.
do
  local ok, flag = pcall(maki.uv.os_getenv, "MAKI_SKETCH_SELFTEST")
  if ok and flag == "1" then
    local rok, report = pcall(function()
      return require("sketch.selftest").run()
    end)
    print("SKETCH-SELFTEST\n" .. tostring(report))
    local hok, html = pcall(maki.uv.os_getenv, "MAKI_SKETCH_HTML")
    if not (hok and html and html ~= "") then
      local dok, demo = pcall(function()
        return require("sketch.selftest").demo()
      end)
      if dok then
        print(demo)
      end
    end
    if hok and html and html ~= "" then
      local cok, cval = pcall(maki.uv.os_getenv, "MAKI_SKETCH_COLS")
      local rok2, rval = pcall(maki.uv.os_getenv, "MAKI_SKETCH_ROWS")
      local ook, oval = pcall(maki.uv.os_getenv, "MAKI_SKETCH_OFFSET")
      local mok, mode = pcall(maki.uv.os_getenv, "MAKI_SKETCH_MODE")
      local cols = (cok and tonumber(cval)) or 110
      local rows = (rok2 and tonumber(rval)) or 38
      local offset = (ook and tonumber(oval)) or 0
      if mok and mode == "html" then
        local rok, fragment = pcall(function()
          return (require("sketch.selftest").render_html(html, cols, rows, offset))
        end)
        if rok then
          print("SKETCH-HTML\n" .. fragment)
        else
          print("SKETCH-RENDER-ERROR\n" .. tostring(fragment))
        end
      else
        local rok, rendered = pcall(function()
          return require("sketch.selftest").render_text(html, cols, rows)
        end)
        if rok then
          print(rendered)
        else
          print("SKETCH-RENDER-ERROR\n" .. tostring(rendered))
        end
      end
    end
  end
end

maki.log.info("sketch: plugin loaded, build " .. BUILD)

return M
