-- Unit tests for the pure modules (dom, css, layout, paint, points).
--
-- Run with `/sketch selftest`. Fixtures are inline on purpose: a package does
-- not know its own install path, so it cannot read a sibling tests/ folder.

local dom = require("sketch.dom")
local css = require("sketch.css")
local layout = require("sketch.layout")
local paint = require("sketch.paint")
local points = require("sketch.points")
local text = require("sketch.text")
local render = require("sketch.render")

local M = {}

local function run_suite()
  local passed, failed = 0, {}
  local current = "?"

  local function eq(actual, expected, msg)
    if actual ~= expected then
      error(
        string.format(
          "%s: expected %s, got %s",
          msg or "value",
          tostring(expected),
          tostring(actual)
        ),
        2
      )
    end
  end

  local function truthy(value, msg)
    if not value then
      error(msg or "expected a truthy value", 2)
    end
  end

  local function case(name, fn)
    current = name
    local ok, err = pcall(fn)
    if ok then
      passed = passed + 1
    else
      failed[#failed + 1] = name .. ": " .. tostring(err)
    end
  end

  local function find(root, tag)
    local found
    dom.walk(root, function(node)
      if not found and node.type == "element" and node.tag == tag then
        found = node
      end
    end)
    return found
  end

  -- DOM -------------------------------------------------------------------

  case("dom: attributes, entities, void elements", function()
    local root = dom.parse([[<div class="a b" data-x="1">Hi &amp; bye<br><img src=x alt="pic"></div>]])
    local div = find(root, "div")
    eq(div.attrs.class, "a b", "class attribute")
    eq(div.attrs["data-x"], "1", "data attribute")
    eq(#div.children, 3, "children: text, br, img")
    eq(div.children[1].text, "Hi & bye", "entity decoding")
    eq(div.children[3].tag, "img", "void element")
  end)

  case("dom: style body is raw text", function()
    local root = dom.parse([[<style>.a { color: red }</style><div class="a">x</div>]])
    local style = find(root, "style")
    eq(style.children[1].text, ".a { color: red }", "raw style body")
    eq(style.children[1].raw, true, "raw flag")
  end)

  case("dom: implied closes", function()
    local root = dom.parse([[<ul><li>one<li>two</ul>]])
    local ul = find(root, "ul")
    eq(#ul.children, 2, "two list items")
    eq(ul.children[2].children[1].text, "two", "second item text")
  end)

  -- CSS -------------------------------------------------------------------

  case("css: specificity and inline style", function()
    local root = dom.parse([[
      <style>
        div { color: #0000ff }
        .x { color: #00ff00; padding: 8px }
        #y { color: #ff0000 }
      </style>
      <div class="x" id="y" style="font-size: 24px">z</div>
    ]])
    local author = css.prepare(root)
    local styles = css.compute(root, author)
    local div = find(root, "div")
    eq(styles[div].color, "#ff0000", "id beats class and tag")
    eq(styles[div].font_size, 24, "inline font-size")
    eq(styles[div].padding_left, "8px", "padding shorthand")
  end)

  case("css: :root custom property in a fragment", function()
    local root = dom.parse([[
      <style>:root { --brand: #123456 } .x { color: var(--brand) }</style>
      <div class="x">z</div>
    ]])
    local author = css.prepare(root)
    local styles = css.compute(root, author)
    eq(styles[find(root, "div")].color, "#123456", "var resolved")
  end)

  -- `flex` keywords are not lengths: reading them as grow: 1 pinned items grow
  -- silently, and the design only looked "a bit off".
  case("css: flex keywords do not become flex-grow", function()
    local root = dom.parse([[
      <style>.n { flex: none } .a { flex: auto }</style>
      <div class="n">a</div><div class="a">b</div>
    ]])
    local author = css.prepare(root)
    local styles = css.compute(root, author)
    local grows = {}
    for node, st in pairs(styles) do
      if node.type == "element" and node.attrs then
        local cls = node.attrs["class"]
        if cls == "n" or cls == "a" then
          grows[cls] = st.flex_grow
        end
      end
    end
    eq(grows.n, 0, "flex:none pins the item")
    eq(grows.a, 1, "flex:auto grows")
  end)

  case("css: unknown properties are reported", function()
    local root = dom.parse([[<div style="box-shadow: 0 0 4px red">x</div>]])
    local author = css.prepare(root)
    local _, report = css.compute(root, author)
    local seen = false
    for _, name in ipairs(report) do
      if name == "box-shadow" then
        seen = true
      end
    end
    truthy(seen, "box-shadow reported as ignored")
  end)

  -- Layout ----------------------------------------------------------------

  local function build(html, cols, rows)
    local root = dom.parse(html)
    local author = css.prepare(root)
    local styles = css.compute(root, author)
    return layout.build(root, styles, cols or 20, rows or 10, {
      width = text.width,
      sub_width = text.sub_width,
    }), root, styles
  end

  case("layout: block heights with padding", function()
    local built = build([[
      <div style="padding: 16px">
        <div style="height: 16px"></div>
        <div style="height: 32px"></div>
      </div>
    ]], 20, 10)
    eq(built.body.h, 5, "1+1+2+1 padding and children")
  end)

  case("layout: flex row places children side by side", function()
    local built = build([[
      <div style="display: flex; gap: 8px">
        <div style="flex: 1"></div>
        <div style="flex: 1"></div>
      </div>
    ]], 20, 10)
    local flex
    for _, box in ipairs(built.boxes) do
      if box.style.display == "flex" then
        flex = box
      end
    end
    truthy(flex, "flex box")
    eq(#flex.children, 2, "two children")
    truthy(flex.children[2].x > flex.children[1].x, "second child to the right")
    truthy(flex.children[1].w >= 5, "first child grew")
  end)

  -- Inline runs on either side of a tag belong to one line; measuring each text
  -- node alone made flex items that mix text and inline tags too narrow.
  case("layout: intrinsic width adds inline runs", function()
    local built = build([[
      <div style="display: flex"><div>ab <span>cd</span> ef</div><div style="width: 20px"></div></div>
    ]], 40, 10)
    local row
    for _, box in ipairs(built.boxes) do
      if box.style.display == "flex" then
        row = box
      end
    end
    truthy(row, "flex row")
    eq(row.children[1].w, 8, "text and span measured on one line")
  end)

  -- Bare text in a flex container is an anonymous block box: it must lay out as
  -- text, and it must not repaint the container's own frame.
  case("layout: bare text inside a flex container", function()
    local built = build([[
      <div style="display: flex; gap: 8px; border: 1px solid #ffffff;
                  padding: 8px; background: #112233">ab <span>cd</span></div>
    ]], 20, 10)
    local flex
    for _, box in ipairs(built.boxes) do
      if box.style.display == "flex" then
        flex = box
      end
    end
    truthy(flex, "flex box")
    eq(#flex.children, 2, "anonymous text box plus the span")
    local anon = flex.children[1]
    eq(anon.style.display, "block", "text laid out as a block")
    eq(anon.w, 3, "text keeps its own width")
    eq(anon.style.border_width, "0", "no duplicated border")
    eq(anon.style.background, nil, "no duplicated background")
    truthy(anon.x > flex.x, "text sits inside the container padding")
  end)

  local function find_box(built, tag)
    for _, box in ipairs(built.boxes) do
      if box.node and box.node.tag == tag then
        return box
      end
    end
    return nil
  end

  case("layout: text wraps at the box width", function()
    local built = build([[<div style="width: 80px">aaa bbb ccc</div>]], 20, 10)
    local box = find_box(built, "div")
    truthy(box, "div box")
    local rows = {}
    for _, run in ipairs(box.text_runs) do
      rows[run.y] = true
    end
    local count = 0
    for _ in pairs(rows) do
      count = count + 1
    end
    truthy(count >= 2, "text wrapped onto two rows")
  end)

  case("layout: white-space pre keeps newlines", function()
    local built = build([[<pre>one
two</pre>]], 20, 10)
    local box = find_box(built, "pre")
    truthy(box, "pre box")
    local ys = {}
    for _, run in ipairs(box.text_runs) do
      ys[run.y] = true
    end
    local count = 0
    for _ in pairs(ys) do
      count = count + 1
    end
    truthy(count >= 2, "two rows in pre")
  end)

  -- Paint ----------------------------------------------------------------

  case("paint: border and text", function()
    local built = build([[<div style="border: 1px solid #ffffff; padding: 0">Hi</div>]], 20, 6)
    local grid = paint.grid(built, {}, {
      cols = 20,
      rows = 6,
      canvas_rows = 6,
      fg = nil,
      bg = nil,
      accent = "#ff00ff",
      accent_fg = "#000000",
    })
    local rendered = paint.to_text(grid)
    truthy(rendered:find("┌", 1, true), "top-left corner")
    truthy(rendered:find("Hi", 1, true), "text inside the box")
  end)

  case("paint: badge on the point, no legend under the canvas", function()
    local built = build([[
      <div data-point="login">Login</div>
    ]], 20, 8)
    local found = points.collect(built.boxes)
    eq(#found, 1, "one point")
    eq(found[1].label, "login", "label")
    local grid = paint.grid(built, found, {
      cols = 20,
      rows = 8,
      canvas_rows = 6,
      fg = nil,
      bg = nil,
      accent = "#ff00ff",
      accent_fg = "#000000",
    })
    local rendered = paint.to_text(grid)
    truthy(rendered:find("[1]", 1, true), "badge drawn")
    truthy(not rendered:find("[1] login", 1, true), "no legend row")
  end)

  -- Points ---------------------------------------------------------------

  case("points: numbering in DOM order", function()
    local built = build([[
      <div data-point="one">A</div>
      <div data-point="two">B</div>
    ]], 20, 10)
    local found = points.collect(built.boxes)
    eq(#found, 2, "two points")
    eq(found[1].n, 1, "first number")
    eq(found[2].label, "two", "second label")
  end)

  case("points: row map keeps only the design rows", function()
    local built = build([[
      <div data-point="one">A</div>
      <div data-point="two">B</div>
    ]], 20, 10)
    local found = points.collect(built.boxes)
    local map = points.row_map(found)
    truthy(map[1] and map[1][1] == 1, "row 1 is point 1")
    truthy(map[2] and map[2][1] == 2, "row 2 is point 2")
    truthy(map[9] == nil, "no legend rows below the design")
  end)

  case("points: row map follows the scroll window", function()
    local built = build([[
      <div data-point="one">A</div>
      <div data-point="two">B</div>
    ]], 20, 10)
    local found = points.collect(built.boxes)
    local map = points.row_map(found, { offset = 1, rows = 1 })
    truthy(map[1] and map[1][1] == 2, "content row 2 lands on screen row 1")
    truthy(map[2] == nil, "a point outside the window is dropped")
  end)

  case("points: inventory is compact", function()
    local built = build([[<div data-point="cta">x</div>]], 20, 10)
    local found = points.collect(built.boxes)
    local inv = points.inventory(found)
    truthy(inv:find("1=cta", 1, true), "inventory names the point")
  end)

  case("points: inventory round-trips through the restore parser", function()
    local built = build([[
      <div data-point="nav">A</div>
      <div data-point="card-2">B</div>
    ]], 20, 10)
    local found = points.collect(built.boxes)
    local summary = "sketch 20x10 cells · points: " .. points.inventory(found)
    local rows = points.parse_inventory(summary)
    eq(#rows, 2, "two rows parsed")
    eq(rows[1].n, 1, "first row number")
    eq(rows[1].label, "nav", "first row label")
    eq(rows[2].label, "card-2", "hyphenated label")
    truthy(rows[2].dims:find("div", 1, true), "dims keep the tag")
    local trailing = points.parse_inventory(summary .. " · content taller than the canvas (clipped)")
    eq(#trailing, 2, "a trailing note does not add rows")
  end)

  -- Text -----------------------------------------------------------------

  case("text: widths and utf-8", function()
    eq(text.width("abc"), 3, "ascii width")
    eq(text.width("é"), 1, "latin-1 width")
    eq(text.width("漢"), 2, "cjk width")
    eq(text.len("aé漢"), 3, "codepoint count")
    eq(text.encode(0x1F600), "\240\159\152\128", "emoji encoding")
  end)

  -- Canvas height --------------------------------------------------------

  case("layout: a short design hugs the content instead of the viewport", function()
    local txt = M.render_text('<div style="padding:8px"><div>one</div><div>two</div></div>', 40, 40)
    local lines = 0
    for _ in txt:gmatch("\n") do
      lines = lines + 1
    end
    truthy(lines + 1 < 12, "short preview (" .. (lines + 1) .. " lines for a 40-row viewport)")
  end)

  case("layout: a design taller than the viewport keeps the full height", function()
    local html = '<div style="padding:8px">'
    for i = 1, 60 do
      html = html .. "<div>row " .. i .. "</div>"
    end
    html = html .. "</div>"
    local composed = render.compose(html, 40, 24, {
      accent = "#ff00ff",
      accent_fg = "#000000",
    })
    truthy(composed.content_rows > 24, "content taller than the viewport (" .. composed.content_rows .. " rows)")
    eq(#composed.grid, 24, "the visible window is the viewport")
    eq(composed.offset, 0, "starts at the top")
  end)

  case("render: offset slides the window and clamps at the end", function()
    local html = '<div style="padding:0">'
    for i = 1, 40 do
      html = html .. '<div style="padding:0">L' .. i .. "</div>"
    end
    html = html .. "</div>"

    local top = render.compose(html, 40, 10, {})
    local down = render.compose(html, 40, 10, { offset = 5 })
    eq(top.content_rows, down.content_rows, "scroll does not change the layout")
    eq(down.offset, 5, "offset applied")
    truthy(paint.to_text(top.grid):find("L1", 1, true), "top window starts at L1")
    truthy(paint.to_text(down.grid):find("L6", 1, true), "offset window starts at L6")

    local bottom = render.compose(html, 40, 10, { offset = 9999 })
    eq(bottom.offset, bottom.content_rows - 10, "offset clamps to the last window")
  end)

  local report = {}
  report[#report + 1] = string.format("%d passed, %d failed", passed, #failed)
  for _, line in ipairs(failed) do
    report[#report + 1] = "FAIL " .. line
  end
  return table.concat(report, "\n"), #failed
end

-- Renders any HTML to plain text at a given size. Used by the dev hook to
-- eyeball a design without a terminal.
function M.render_text(html, cols, rows)
  local composed = render.compose(html, cols, rows, {
    accent = "#ff00ff",
    accent_fg = "#000000",
  })
  local inv = points.inventory(composed.points)
  local out = paint.to_text(composed.grid) .. "\n" .. (inv ~= "" and ("points: " .. inv) or "")
  -- Block-only designs print as blank lines; MAKI_SKETCH_CELLS=1 adds a map of
  -- background colours, one letter per cell, so geometry can be checked.
  local cok, cval = pcall(maki.uv.os_getenv, "MAKI_SKETCH_CELLS")
  if cok and cval == "1" then
    local legend, seen, map = {}, {}, {}
    for y = 1, #composed.grid do
      local line = {}
      for x = 1, #composed.grid[y] do
        local bg = composed.grid[y][x].bg or "-"
        local sym = map[bg]
        if not sym then
          sym = string.char(65 + #legend % 26)
          map[bg] = sym
          legend[#legend + 1] = sym .. "=" .. tostring(bg)
        end
        line[#line + 1] = sym
      end
      out = out .. "\n" .. table.concat(line)
    end
    out = out .. "\n" .. table.concat(legend, " ")
  end
  return out, composed.report
end

local function html_escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function style_attr(st)
  if type(st) ~= "table" then
    return ""
  end
  local css = {}
  if st.fg then
    css[#css + 1] = "color:" .. st.fg
  end
  if st.bg then
    css[#css + 1] = "background:" .. st.bg
  end
  if st.bold then
    css[#css + 1] = "font-weight:700"
  end
  if st.italic then
    css[#css + 1] = "font-style:italic"
  end
  if st.underline then
    css[#css + 1] = "text-decoration:underline"
  end
  if st.dim then
    css[#css + 1] = "opacity:.65"
  end
  return table.concat(css, ";")
end

-- Renders any HTML to a fragment of one div per row and one span per styled
-- run. The dev hook uses it to build the documentation screenshots from the
-- same grid the pane paints, so an image cannot drift from the engine.
function M.render_html(html, cols, rows, offset)
  local composed = render.compose(html, cols, rows, {
    accent = "#7aa2f7",
    accent_fg = "#0b0e14",
    offset = offset,
  })
  local lines = paint.to_lines(composed.grid, { bg = nil })
  local out = { '<div class="sk-term">' }
  for _, spans in ipairs(lines) do
    out[#out + 1] = '<div class="sk-row">'
    for _, span in ipairs(spans) do
      local txt = html_escape(tostring(span[1] or ""))
      local st = style_attr(span[2])
      if st ~= "" then
        out[#out + 1] = '<span style="' .. st .. '">' .. txt .. "</span>"
      else
        out[#out + 1] = txt
      end
    end
    out[#out + 1] = "</div>"
  end
  out[#out + 1] = "</div>"
  return table.concat(out), composed
end

-- A realistic fixture, printed by the dev hook so the geometry can be
-- eyeballed without a terminal.
function M.demo()
  local html = [[
    <div style="padding: 24px; background: #111827">
      <div style="display: flex; flex-direction: column; gap: 12px; width: 480px;
                  padding: 24px; background: #1f2937; border: 1px solid #374151;
                  border-radius: 8px">
        <h1 data-point="hero" style="color: #f9fafb; font-size: 32px; margin: 0">Welcome back</h1>
        <p style="color: #9ca3af; margin: 0">Sign in to continue to the console.</p>
        <input placeholder="you@example.com" style="display: block; width: 400px;
               padding: 8px; background: #111827; border: 1px solid #374151; color: #e5e7eb">
        <input placeholder="Password" style="display: block; width: 400px;
               padding: 8px; background: #111827; border: 1px solid #374151; color: #e5e7eb">
        <div style="display: flex; gap: 8px">
          <button data-point="login-cta"
                  style="flex: 1; padding: 8px 16px; background: #2563eb; color: white">Log in</button>
          <button data-point="sso"
                  style="padding: 8px 16px; background: #374151; color: #e5e7eb">SSO</button>
        </div>
        <a data-point="forgot" href="#" style="color: #60a5fa">Forgot your password?</a>
      </div>
    </div>
  ]]
  local root = dom.parse(html)
  local author = css.prepare(root)
  local styles, report = css.compute(root, author)
  local built = layout.build(root, styles, 100, 34, {
    width = text.width,
    sub_width = text.sub_width,
  })
  local found = points.collect(built.boxes)
  local grid = paint.grid(built, found, {
    cols = 100,
    rows = 34,
    canvas_rows = 29,
    accent = "#ff00ff",
    accent_fg = "#000000",
  })
  return paint.to_text(grid), report
end

function M.run()
  local ok, report, failed = pcall(run_suite)
  if not ok then
    return "CRASH " .. tostring(report)
  end
  return report
end

return M
