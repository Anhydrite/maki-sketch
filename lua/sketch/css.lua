-- CSS parsing, cascade and computed styles.
--
-- The supported subset is deliberate (see README): block/inline flow, flex
-- rows and columns, box model, colours, borders, text alignment and custom
-- properties. Everything else is collected in `report` so the agent can see
-- what the terminal could not honour.

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_comments(s)
  return (s:gsub("/%*.-%*/", ""))
end

local NAMED = {
  black = "#000000", white = "#ffffff", red = "#ff0000", green = "#008000",
  lime = "#00ff00", blue = "#0000ff", yellow = "#ffff00", cyan = "#00ffff",
  aqua = "#00ffff", magenta = "#ff00ff", fuchsia = "#ff00ff",
  gray = "#808080", grey = "#808080", silver = "#c0c0c0",
  lightgray = "#d3d3d3", lightgrey = "#d3d3d3", darkgray = "#a9a9a9",
  darkgrey = "#a9a9a9", maroon = "#800000", olive = "#808000",
  navy = "#000080", purple = "#800080", teal = "#008080", orange = "#ffa500",
  gold = "#ffd700", pink = "#ffc0cb", brown = "#a52a2a", indigo = "#4b0082",
  violet = "#ee82ee", salmon = "#fa8072", tomato = "#ff6347",
  skyblue = "#87ceeb", steelblue = "#4682b4", crimson = "#dc143c",
  currentcolor = "currentColor",
}

M.NAMED = NAMED

function M.color(value)
  if not value then
    return nil
  end
  local v = trim(tostring(value)):lower()
  if v == "" or v == "transparent" or v == "none" or v == "inherit" or v == "initial" then
    return nil
  end
  if v:sub(1, 1) == "#" then
    local hex = v:sub(2)
    if #hex == 3 then
      return "#" .. hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
    end
    if #hex == 6 then
      return "#" .. hex
    end
    return nil
  end
  local r, g, b, a = v:match("^rgba?%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,?%s*([%d%.]*)%s*%)$")
  if r then
    if a and a ~= "" and tonumber(a) == 0 then
      return nil
    end
    return string.format("#%02x%02x%02x", math.min(255, tonumber(r)), math.min(255, tonumber(g)), math.min(255, tonumber(b)))
  end
  return NAMED[v]
end

local function split_ws(s)
  local out = {}
  for part in s:gmatch("%S+") do
    out[#out + 1] = part
  end
  return out
end

-- Expands shorthands into longhand properties. Unknown properties are kept
-- as-is so `report` can name them.
local function parse_decls(body)
  local decls = {}
  local order = {}
  for chunk in (body .. ";"):gmatch("([^;]+);") do
    local prop, value = chunk:match("^%s*([%w%-_]+)%s*:%s*(.-)%s*$")
    if prop then
      prop = prop:lower()
      value = value:gsub("%s*!important%s*$", "")
      local function set(k, v)
        if not decls[k] then
          order[#order + 1] = k
        end
        decls[k] = v
      end

      if prop == "padding" or prop == "margin" then
        local parts = split_ws(value)
        local t, r, b, l
        if #parts == 1 then
          t, r, b, l = parts[1], parts[1], parts[1], parts[1]
        elseif #parts == 2 then
          t, b, r, l = parts[1], parts[1], parts[2], parts[2]
        elseif #parts == 3 then
          t, r, b, l = parts[1], parts[2], parts[3], parts[2]
        else
          t, r, b, l = parts[1], parts[2], parts[3], parts[4]
        end
        set(prop .. "-top", t)
        set(prop .. "-right", r)
        set(prop .. "-bottom", b)
        set(prop .. "-left", l)
      elseif prop == "border" then
        local width, style, color
        for _, part in ipairs(split_ws(value)) do
          if M.color(part) then
            color = part
          elseif part:match("^[%d%.]+[%a%%]*$") then
            width = part
          else
            style = part
          end
        end
        if style == "none" or style == "hidden" then
          width = "0"
        end
        set("border-width", width or "1px")
        set("border-color", color or "#888888")
      elseif prop == "border-width" or prop == "border-color" then
        local parts = split_ws(value)
        set(prop, parts[1] or value)
      elseif prop == "border-radius" then
        set("border-radius", value)
      elseif prop == "background" then
        local color, image
        for _, part in ipairs(split_ws(value)) do
          if M.color(part) then
            color = part
          elseif part:find("url%(") or part:find("gradient%(") then
            image = part
          end
        end
        if image then
          set("background-image", image)
        end
        if color then
          set("background-color", color)
        end
      elseif prop == "flex" then
        -- `none` and `auto` are keywords, not numbers: parsing them as "1"
        -- silently grew items the author had pinned.
        if value == "none" then
          set("flex-grow", "0")
        elseif value == "auto" then
          set("flex-grow", "1")
        else
          local grow = value:match("^([%d%.]+)")
          set("flex-grow", grow or "1")
        end
      elseif prop == "gap" then
        set("gap", value)
        set("row-gap", value)
        set("column-gap", value)
      elseif prop == "font" then
        -- Only the size is meaningful here; the rest is fixed by the terminal.
        local size = value:match("([%d%.]+)px")
        if size then
          set("font-size", size .. "px")
        end
      else
        set(prop, value)
      end
    end
  end
  return decls, order
end

-- Selector chains: a list of { simple = {...}, comb = " " | ">" }.
-- `comb` is the relation to the element on its left in the chain.
local function parse_simple(part)
  local simple = { tag = nil, id = nil, classes = {}, attrs = {} }
  local i = 1
  local n = #part
  if part == "" then
    return nil
  end
  while i <= n do
    local c = part:sub(i, i)
    if c == "*" then
      i = i + 1
    elseif c == "." then
      local s, e = part:find("^[%w%-_]+", i + 1)
      if not s then
        return nil
      end
      simple.classes[#simple.classes + 1] = part:sub(s, e)
      i = e + 1
    elseif c == "#" then
      local s, e = part:find("^[%w%-_]+", i + 1)
      if not s then
        return nil
      end
      simple.id = part:sub(s, e)
      i = e + 1
    elseif c == "[" then
      local e = part:find("]", i, true)
      if not e then
        return nil
      end
      local inner = part:sub(i + 1, e - 1)
      local name, op, value = inner:match("^%s*([%w%-_]+)%s*([=~|^$*]?=?)%s*(.-)%s*$")
      if name then
        value = value:gsub('^["\']', ""):gsub('["\']$', "")
        simple.attrs[#simple.attrs + 1] = { name = name:lower(), op = op, value = value }
      end
      i = e + 1
    elseif c == ":" then
      local s, e = part:find("^[%w%-_%(%)]+", i + 1)
      if not s then
        return nil
      end
      local pseudo = part:sub(s, e)
      if pseudo == "root" then
        simple.root = true
      elseif pseudo ~= "first-child" then
        -- Drop unsupported pseudo-classes: `a:hover` still matches `a`.
      end
      i = e + 1
    else
      local s, e = part:find("^[%w%-_]+", i)
      if s then
        simple.tag = part:sub(s, e):lower()
        i = e + 1
      else
        return nil
      end
    end
  end
  return simple
end

local function parse_selector(raw)
  raw = trim(raw)
  if raw == "" then
    return nil
  end
  local chain = {}
  local i = 1
  local n = #raw
  local pending_comb = " "
  local spec = 0

  while i <= n do
    local c = raw:sub(i, i)
    if c:match("%s") then
      i = i + 1
      if #chain > 0 and pending_comb == " " then
        pending_comb = " "
      end
    elseif c == ">" then
      pending_comb = ">"
      i = i + 1
    else
      local s = i
      while i <= n do
        local d = raw:sub(i, i)
        if d:match("%s") or d == ">" then
          break
        end
        i = i + 1
      end
      local part = raw:sub(s, i - 1)
      local simple = parse_simple(part)
      if not simple then
        return nil
      end
      spec = spec + (simple.id and 100 or 0)
      spec = spec + (#simple.classes + #simple.attrs) * 10
      if simple.tag then
        spec = spec + 1
      end
      chain[#chain + 1] = { simple = simple, comb = #chain == 0 and " " or pending_comb }
      pending_comb = " "
    end
  end

  if #chain == 0 then
    return nil
  end
  return { chain = chain, spec = spec }
end

function M.parse(css_text)
  local rules = {}
  local i = 1
  local source = strip_comments(css_text or "")

  while true do
    local open = source:find("{", i, true)
    if not open then
      break
    end
    local prelude = trim(source:sub(i, open - 1))
    local depth = 0
    local j = open
    local close = nil
    while j <= #source do
      local c = source:sub(j, j)
      if c == "{" then
        depth = depth + 1
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 then
          close = j
          break
        end
      end
      j = j + 1
    end
    if not close then
      break
    end
    local body = source:sub(open + 1, close - 1)
    i = close + 1

    if prelude ~= "" and prelude:sub(1, 1) ~= "@" then
      for part in prelude:gmatch("[^,]+") do
        local sel = parse_selector(part)
        if sel then
          local decls, order = parse_decls(body)
          rules[#rules + 1] = {
            sel = sel,
            decls = decls,
            order = order,
            spec = sel.spec,
            seq = #rules + 1,
          }
        end
      end
    end
  end

  return rules
end

local UA_CSS = [[
html, body, div, p, section, article, header, footer, main, nav, aside,
form, fieldset, figure, figcaption, blockquote, dl, dt, dd, ul, ol, li,
table, thead, tbody, tfoot, tr, td, th, pre, h1, h2, h3, h4, h5, h6, hr {
  display: block;
}
span, a, b, i, em, strong, code, small, label, u, s, sub, sup, mark, kbd,
abbr, cite, q, time { display: inline; }
button, input, select, textarea, img { display: inline-block; }
body { font-size: 16px; }
h1 { font-size: 32px; font-weight: bold; margin: 8px 0; }
h2 { font-size: 24px; font-weight: bold; margin: 6px 0; }
h3 { font-size: 20px; font-weight: bold; margin: 4px 0; }
h4, h5, h6 { font-size: 16px; font-weight: bold; margin: 4px 0; }
p { margin: 4px 0; }
ul, ol { margin: 4px 0; padding: 0 0 0 16px; }
li { display: block; }
a { color: #4aa3ff; text-decoration: underline; }
b, strong { font-weight: bold; }
i, em { font-style: italic; }
code, pre { background-color: #1b1b1b; }
pre { padding: 8px; white-space: pre; }
hr { border: 1px solid #555555; margin: 4px 0; }
button { border: 1px solid #666666; padding: 4px 8px; background-color: #2a2a2a; text-align: center; }
input { border: 1px solid #666666; padding: 2px 4px; background-color: #1a1a1a; }
table { border: 1px solid #444444; }
tr { display: flex; flex-direction: row; }
td, th { flex: 1; padding: 2px 4px; border: 1px solid #444444; }
th { font-weight: bold; }
]]

local UA_RULES = M.parse(UA_CSS)

local function class_set(node)
  if node._classes then
    return node._classes
  end
  local set = {}
  local cls = node.attrs and node.attrs["class"] or ""
  for name in cls:gmatch("%S+") do
    set[name] = true
  end
  node._classes = set
  return set
end

local function simple_match(simple, node)
  if not node or node.type ~= "element" then
    return false
  end
  if simple.root then
    return node.tag == "html"
  end
  if simple.tag and simple.tag ~= node.tag then
    return false
  end
  if simple.id and node.attrs.id ~= simple.id then
    return false
  end
  if #simple.classes > 0 then
    local set = class_set(node)
    for _, name in ipairs(simple.classes) do
      if not set[name] then
        return false
      end
    end
  end
  for _, a in ipairs(simple.attrs) do
    local v = node.attrs[a.name]
    if v == nil then
      return false
    end
    if a.op == "=" and v ~= a.value then
      return false
    elseif a.op == "~=" and not (" " .. v .. " "):find(" " .. a.value .. " ", 1, true) then
      return false
    elseif a.op == "^=" and v:sub(1, #a.value) ~= a.value then
      return false
    elseif a.op == "$=" and v:sub(-#a.value) ~= a.value then
      return false
    elseif a.op == "*=" and not v:find(a.value, 1, true) then
      return false
    end
  end
  return true
end

local function chain_match(chain, idx, node)
  if not simple_match(chain[idx].simple, node) then
    return false
  end
  if idx == 1 then
    return true
  end
  local comb = chain[idx].comb
  if comb == ">" then
    local p = node.parent
    while p and p.type ~= "element" do
      p = p.parent
    end
    return p ~= nil and chain_match(chain, idx - 1, p)
  end
  local p = node.parent
  while p do
    if p.type == "element" and chain_match(chain, idx - 1, p) then
      return true
    end
    p = p.parent
  end
  return false
end

local function apply_decls(target, decls, order)
  for _, key in ipairs(order) do
    target[key] = decls[key]
  end
end

local function resolve_vars(value, vars, depth)
  if type(value) ~= "string" or not value:find("var%(", 1) then
    return value
  end
  depth = depth or 0
  if depth > 6 then
    return ""
  end
  local out = value:gsub("var%(%s*(%-%-[%w%-_]+)%s*,?%s*([^)]*)%)", function(name, fallback)
    local v = vars[name]
    if v == nil or v == "" then
      v = fallback ~= "" and fallback or ""
    end
    return resolve_vars(v, vars, depth + 1)
  end)
  return out
end

local function num(v, ref)
  if v == nil then
    return nil
  end
  local n, unit = tostring(v):match("^([%-%d%.]+)([%%%a]*)$")
  n = tonumber(n)
  if not n then
    return nil
  end
  if unit == "%" then
    return ref and (ref * n / 100) or nil
  end
  if unit == "em" or unit == "rem" then
    return n * 16
  end
  return n
end

local SUPPORTED = {
  ["display"] = true, ["color"] = true, ["background-color"] = true,
  ["background"] = true, ["background-image"] = true,
  ["font-size"] = true, ["font-weight"] = true, ["font-style"] = true,
  ["text-decoration"] = true, ["text-align"] = true, ["white-space"] = true,
  ["line-height"] = true, ["width"] = true, ["height"] = true,
  ["min-width"] = true, ["max-width"] = true, ["min-height"] = true,
  ["max-height"] = true, ["overflow"] = true, ["opacity"] = true,
  ["margin-top"] = true, ["margin-right"] = true, ["margin-bottom"] = true,
  ["margin-left"] = true, ["padding-top"] = true, ["padding-right"] = true,
  ["padding-bottom"] = true, ["padding-left"] = true,
  ["border-width"] = true, ["border-color"] = true, ["border-radius"] = true,
  ["flex-direction"] = true, ["justify-content"] = true,
  ["align-items"] = true, ["flex-grow"] = true, ["gap"] = true,
  ["row-gap"] = true, ["column-gap"] = true,
  ["position"] = true, ["top"] = true, ["right"] = true, ["bottom"] = true,
  ["left"] = true,
}

local function compute_style(decl, parent, vars)
  local function inherited(key)
    return decl[key] or (parent and parent[key])
  end

  local display = decl.display or "block"
  local color = resolve_vars(decl.color, vars)
  color = M.color(color) or (parent and parent.color)

  local bg = resolve_vars(decl["background-color"], vars)
  bg = M.color(bg) or nil

  local weight = resolve_vars(decl["font-weight"], vars)
  local style = resolve_vars(decl["font-style"], vars)
  local decoration = resolve_vars(decl["text-decoration"], vars) or ""
  local size = num(resolve_vars(decl["font-size"], vars)) or (parent and parent.font_size) or 16

  local st = {
    display = display,
    color = color,
    background = bg,
    background_image = decl["background-image"],
    font_size = size,
    bold = weight == "bold" or weight == "bolder" or (tonumber(weight) or 0) >= 600,
    italic = style == "italic" or style == "oblique",
    underline = decoration:find("underline", 1, true) ~= nil,
    strike = decoration:find("line-through", 1, true) ~= nil,
    text_align = resolve_vars(decl["text-align"], vars) or (parent and parent.text_align) or "left",
    white_space = resolve_vars(decl["white-space"], vars) or (parent and parent.white_space) or "normal",
    line_height = num(resolve_vars(decl["line-height"], vars)),
    overflow = resolve_vars(decl.overflow, vars) or "visible",
    opacity = tonumber(resolve_vars(decl.opacity, vars)) or 1,
    width = resolve_vars(decl.width, vars),
    height = resolve_vars(decl.height, vars),
    min_width = resolve_vars(decl["min-width"], vars),
    max_width = resolve_vars(decl["max-width"], vars),
    min_height = resolve_vars(decl["min-height"], vars),
    max_height = resolve_vars(decl["max-height"], vars),
    margin_top = resolve_vars(decl["margin-top"], vars) or "0",
    margin_right = resolve_vars(decl["margin-right"], vars) or "0",
    margin_bottom = resolve_vars(decl["margin-bottom"], vars) or "0",
    margin_left = resolve_vars(decl["margin-left"], vars) or "0",
    padding_top = resolve_vars(decl["padding-top"], vars) or "0",
    padding_right = resolve_vars(decl["padding-right"], vars) or "0",
    padding_bottom = resolve_vars(decl["padding-bottom"], vars) or "0",
    padding_left = resolve_vars(decl["padding-left"], vars) or "0",
    border_width = resolve_vars(decl["border-width"], vars) or "0",
    border_color = M.color(resolve_vars(decl["border-color"], vars)) or "#888888",
    border_radius = num(resolve_vars(decl["border-radius"], vars)) or 0,
    flex_direction = resolve_vars(decl["flex-direction"], vars) or "row",
    justify_content = resolve_vars(decl["justify-content"], vars) or "flex-start",
    align_items = resolve_vars(decl["align-items"], vars) or "stretch",
    flex_grow = tonumber(resolve_vars(decl["flex-grow"], vars)) or 0,
    gap = resolve_vars(decl.gap, vars) or "0",
    row_gap = resolve_vars(decl["row-gap"], vars) or resolve_vars(decl.gap, vars) or "0",
    column_gap = resolve_vars(decl["column-gap"], vars) or resolve_vars(decl.gap, vars) or "0",
    position = resolve_vars(decl.position, vars) or "static",
    top = resolve_vars(decl.top, vars),
    right = resolve_vars(decl.right, vars),
    bottom = resolve_vars(decl.bottom, vars),
    left = resolve_vars(decl.left, vars),
    vars = vars,
  }
  return st
end

function M.compute(root, author_rules)
  author_rules = author_rules or {}
  local styles = {}
  local seen = {}
  local report = {}

  local function note(key)
    if not seen[key] then
      seen[key] = true
      report[#report + 1] = key
    end
  end

  local function visit(node, parent_style, parent_vars)
    if node.type == "element" then
      local matched = {}
      for _, rule in ipairs(UA_RULES) do
        if chain_match(rule.sel.chain, #rule.sel.chain, node) then
          matched[#matched + 1] = { rule = rule, spec = rule.spec, seq = -10000 + rule.seq }
        end
      end
      for _, rule in ipairs(author_rules) do
        if chain_match(rule.sel.chain, #rule.sel.chain, node) then
          matched[#matched + 1] = { rule = rule, spec = rule.spec, seq = rule.seq }
        end
      end
      table.sort(matched, function(a, b)
        if a.spec == b.spec then
          return a.seq < b.seq
        end
        return a.spec < b.spec
      end)

      local decl = {}
      local order = {}
      for _, m in ipairs(matched) do
        for _, key in ipairs(m.rule.order) do
          if not decl[key] then
            order[#order + 1] = key
          end
          decl[key] = m.rule.decls[key]
        end
      end

      local inline = node.attrs.style
      if inline and inline ~= "" then
        local idecl, iorder = parse_decls(inline)
        apply_decls(decl, idecl, iorder)
      end

      -- Custom properties inherit.
      local vars = {}
      if parent_vars then
        for k, v in pairs(parent_vars) do
          vars[k] = v
        end
      end
      for k, v in pairs(decl) do
        if k:sub(1, 2) == "--" then
          vars[k] = v
        end
      end

      for k, v in pairs(decl) do
        if k:sub(1, 2) ~= "--" and not SUPPORTED[k] then
          note(k)
        end
      end
      if decl["background-image"] then
        note("background-image")
      end
      if decl["position"] == "fixed" or decl["position"] == "sticky" then
        note("position:" .. decl["position"])
      end

      local st = compute_style(decl, parent_style, vars)
      styles[node] = st

      for _, child in ipairs(node.children) do
        visit(child, st, vars)
      end
    else
      for _, child in ipairs(node.children or {}) do
        visit(child, parent_style, parent_vars)
      end
    end
  end

  -- `:root` custom properties are global: fragments have no <html>, so they
  -- are merged into the variables every element inherits from.
  local root_vars = {}
  local function collect_root_vars(rules)
    for _, rule in ipairs(rules) do
      local chain = rule.sel.chain
      if #chain == 1 and chain[1].simple.root then
        for k, v in pairs(rule.decls) do
          if k:sub(1, 2) == "--" then
            root_vars[k] = v
          end
        end
      end
    end
  end
  collect_root_vars(UA_RULES)
  collect_root_vars(author_rules)

  visit(root, nil, root_vars)
  return styles, report
end

-- Builds the author rule list for the next `compute` call.
function M.prepare(root, report)
  local chunks = {}
  local function visit(node)
    if node.type == "element" and node.tag == "style" then
      local body = {}
      for _, child in ipairs(node.children) do
        if child.type == "text" then
          body[#body + 1] = child.text
        end
      end
      chunks[#chunks + 1] = table.concat(body, "\n")
      return
    end
    for _, child in ipairs(node.children or {}) do
      visit(child)
    end
  end
  visit(root)
  local rules = {}
  for _, chunk in ipairs(chunks) do
    for _, rule in ipairs(M.parse(chunk)) do
      rules[#rules + 1] = rule
    end
  end
  if report and #rules == 0 then
    report[#report + 1] = "no stylesheet"
  end
  return rules
end

M.compute_style = compute_style
M.parse_decls = parse_decls
M.num = num

return M
