-- Lenient HTML parser producing a small DOM tree.
--
-- Not a full HTML5 parser: it handles the shape of hand-written mockups
-- (elements, attributes, text, comments, doctype, raw <style>/<script>
-- bodies, void elements and the implied closes that matter for lists and
-- paragraphs). Anything it cannot understand is skipped, never fatal.

local text = require("sketch.text")

local M = {}

local VOID = {
  area = true, base = true, br = true, col = true, embed = true, hr = true,
  img = true, input = true, link = true, meta = true, param = true,
  source = true, track = true, wbr = true,
}

-- Elements whose body is raw text, not markup.
local RAW = { style = true, script = true, textarea = true, title = true }

-- Starting one of these closes an open <p>.
local CLOSES_P = {
  address = true, article = true, aside = true, blockquote = true, div = true,
  dl = true, fieldset = true, figcaption = true, figure = true, footer = true,
  form = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
  header = true, hr = true, main = true, nav = true, ol = true, p = true,
  pre = true, section = true, table = true, ul = true,
}

-- Starting the key closes an open element of any listed tag.
local AUTO_CLOSE = {
  li = { li = true },
  tr = { tr = true, td = true, th = true },
  td = { td = true, th = true },
  th = { td = true, th = true },
  option = { option = true },
  dt = { dt = true, dd = true },
  dd = { dt = true, dd = true },
}

local ENTITY = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
  copy = "\194\169", reg = "\194\174", hellip = "\226\128\166",
  mdash = "\226\128\148", ndash = "\226\128\147", times = "\195\151",
  laquo = "\194\171", raquo = "\194\187", euro = "\226\130\172",
}

local function decode(s)
  if not s:find("&", 1, true) then
    return s
  end
  s = s:gsub("&#[xX](%x+);", function(h)
    local cp = tonumber(h, 16)
    if cp then
      return text.encode(cp)
    end
    return ""
  end)
  s = s:gsub("&#(%d+);", function(d)
    local cp = tonumber(d)
    if cp then
      return text.encode(cp)
    end
    return ""
  end)
  s = s:gsub("&(%a+);", function(name)
    return ENTITY[name] or ""
  end)
  return s
end

M.decode = decode

local function new_element(tag, attrs)
  return {
    type = "element",
    tag = tag,
    attrs = attrs or {},
    children = {},
  }
end

local function append(parent, child)
  child.parent = parent
  parent.children[#parent.children + 1] = child
end

local function add_text(parent, raw)
  if raw == "" then
    return
  end
  local value = decode(raw)
  if value == "" then
    return
  end
  append(parent, { type = "text", text = value })
end

-- Reads a start tag at byte {i} (which points at '<').
-- Returns tag, attrs, self_closing, next_index.
local function read_start(s, i)
  local n = #s
  local j = i + 1
  local name_start = j
  while j <= n do
    local c = s:sub(j, j)
    if c == " " or c == "\t" or c == "\r" or c == "\n" or c == "/" or c == ">" then
      break
    end
    j = j + 1
  end
  local tag = s:sub(name_start, j - 1):lower()
  local attrs = {}
  local self_closing = false

  while j <= n do
    local c = s:sub(j, j)
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      j = j + 1
    elseif c == ">" then
      j = j + 1
      break
    elseif c == "/" then
      if s:sub(j + 1, j + 1) == ">" then
        self_closing = true
        j = j + 2
        break
      end
      j = j + 1
    else
      local ks = j
      while j <= n do
        local d = s:sub(j, j)
        if d == " " or d == "\t" or d == "\r" or d == "\n" or d == "=" or d == "/" or d == ">" then
          break
        end
        j = j + 1
      end
      local key = s:sub(ks, j - 1):lower()
      while j <= n and s:sub(j, j):match("%s") do
        j = j + 1
      end
      local value = ""
      if s:sub(j, j) == "=" then
        j = j + 1
        while j <= n and s:sub(j, j):match("%s") do
          j = j + 1
        end
        local q = s:sub(j, j)
        if q == '"' or q == "'" then
          local e = s:find(q, j + 1, true)
          value = s:sub(j + 1, (e or n + 1) - 1)
          j = e and (e + 1) or (n + 1)
        else
          local vs = j
          while j <= n do
            local d = s:sub(j, j)
            if d == " " or d == "\t" or d == "\r" or d == "\n" or d == ">" then
              break
            end
            j = j + 1
          end
          value = s:sub(vs, j - 1)
        end
      end
      if key ~= "" then
        attrs[key] = decode(value)
      end
    end
  end

  return tag, attrs, self_closing, j
end

local function close_implied(stack, tag)
  local top = stack[#stack]
  if not top or top.type ~= "element" then
    return
  end
  local auto = AUTO_CLOSE[tag]
  if auto and auto[top.tag] then
    stack[#stack] = nil
    return
  end
  if CLOSES_P[tag] then
    -- Close the nearest open <p>, if it is the current block.
    for k = #stack, 2, -1 do
      local el = stack[k]
      if el.type ~= "element" then
        break
      end
      if el.tag == "p" then
        for m = #stack, k, -1 do
          stack[m] = nil
        end
        break
      end
      if el.tag == "div" or el.tag == "section" or el.tag == "body" or el.tag == "html" then
        break
      end
    end
  end
end

function M.parse(html)
  local root = { type = "document", tag = "#document", attrs = {}, children = {} }
  local stack = { root }
  local i = 1
  local n = #html

  while i <= n do
    local lt = html:find("<", i, true)
    if not lt then
      add_text(stack[#stack], html:sub(i))
      break
    end
    if lt > i then
      add_text(stack[#stack], html:sub(i, lt - 1))
    end

    if html:sub(lt, lt + 3) == "<!--" then
      local e = html:find("-->", lt + 4, true)
      i = e and (e + 3) or (n + 1)
    elseif html:sub(lt, lt + 1) == "<!" or html:sub(lt, lt + 1) == "<?" then
      local e = html:find(">", lt + 2, true)
      i = e and (e + 1) or (n + 1)
    elseif html:sub(lt, lt + 1) == "</" then
      local e = html:find(">", lt + 2, true)
      local tag = html:sub(lt + 2, (e or n + 1) - 1):lower():gsub("%s+", "")
      if tag ~= "" then
        for k = #stack, 2, -1 do
          if stack[k].type == "element" and stack[k].tag == tag then
            for m = #stack, k, -1 do
              stack[m] = nil
            end
            break
          end
        end
      end
      i = e and (e + 1) or (n + 1)
    else
      local tag, attrs, self_closing, next_i = read_start(html, lt)
      if tag == "" then
        add_text(stack[#stack], "<")
        i = lt + 1
      else
        close_implied(stack, tag)
        local el = new_element(tag, attrs)
        append(stack[#stack], el)
        i = next_i

        if RAW[tag] and not self_closing then
          local close = html:lower():find("</" .. tag, i, true)
          local body = html:sub(i, (close or n + 1) - 1)
          if body ~= "" then
            local raw_node = { type = "text", text = body, raw = true }
            append(el, raw_node)
          end
          if close then
            local e = html:find(">", close, true)
            i = e and (e + 1) or (n + 1)
          else
            i = n + 1
          end
        elseif self_closing or VOID[tag] then
          -- element stands alone
        else
          stack[#stack + 1] = el
        end
      end
    end
  end

  return root
end

-- Depth-first walk, parents before children.
function M.walk(node, fn)
  fn(node)
  if node.children then
    for _, child in ipairs(node.children) do
      M.walk(child, fn)
    end
  end
end

function M.classes(node)
  local cls = node.attrs and node.attrs["class"] or ""
  local out = {}
  for name in cls:gmatch("%S+") do
    out[name] = true
  end
  return out
end

function M.text_content(node)
  local parts = {}
  M.walk(node, function(n)
    if n.type == "text" then
      parts[#parts + 1] = n.text
    end
  end)
  return table.concat(parts)
end

return M
