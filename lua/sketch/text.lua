-- UTF-8 and display-width helpers.
--
-- The plugin never assumes a standalone Lua: Luau's string library is what
-- maki gives us, so codepoints and widths are computed by hand. `maki.ui.
-- display_width` is preferred by the plugin when a UI is attached; this
-- module is the fallback used by the selftest and headless runs.

local M = {}

local function is_wide(cp)
  return (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0x303E)
    or (cp >= 0x3041 and cp <= 0x33FF)
    or (cp >= 0x3400 and cp <= 0x4DBF)
    or (cp >= 0x4E00 and cp <= 0x9FFF)
    or (cp >= 0xA000 and cp <= 0xA4CF)
    or (cp >= 0xA960 and cp <= 0xA97F)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE10 and cp <= 0xFE19)
    or (cp >= 0xFE30 and cp <= 0xFE6F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x1F300 and cp <= 0x1F64F)
    or (cp >= 0x1F900 and cp <= 0x1F9FF)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
end

local function is_zero(cp)
  return (cp >= 0x0300 and cp <= 0x036F)
    or (cp >= 0x1AB0 and cp <= 0x1AFF)
    or (cp >= 0x1DC0 and cp <= 0x1DFF)
    or (cp >= 0x20D0 and cp <= 0x20FF)
    or (cp >= 0xFE00 and cp <= 0xFE0F)
    or (cp >= 0xFE20 and cp <= 0xFE2F)
    or cp == 0x200B
    or cp == 0x200D
end

function M.char_width(cp)
  if is_zero(cp) then
    return 0
  end
  if is_wide(cp) then
    return 2
  end
  return 1
end

-- Returns the number of bytes of the UTF-8 sequence starting at byte i.
local function seq_len(b)
  if b < 0x80 then
    return 1
  elseif b < 0xE0 then
    return 2
  elseif b < 0xF0 then
    return 3
  end
  return 4
end

-- Iterates (codepoint, byte_start, byte_len) over the string.
function M.codepoints(s)
  local i = 1
  local n = #s
  return function()
    if i > n then
      return nil
    end
    local b = s:byte(i)
    local len = seq_len(b)
    if i + len - 1 > n then
      len = 1
    end
    local cp = b
    if len == 2 then
      local b2 = s:byte(i + 1)
      cp = (b - 0xC0) * 64 + (b2 - 0x80)
    elseif len == 3 then
      local b2, b3 = s:byte(i + 1), s:byte(i + 2)
      cp = (b - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
    elseif len == 4 then
      local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
      cp = (b - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80)
    end
    local start = i
    i = i + len
    return cp, start, len
  end
end

function M.encode(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 4096),
      0x80 + math.floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  end
  return string.char(
    0xF0 + math.floor(cp / 262144),
    0x80 + math.floor(cp / 4096) % 64,
    0x80 + math.floor(cp / 64) % 64,
    0x80 + cp % 64
  )
end

function M.width(s)
  local w = 0
  for cp in M.codepoints(s) do
    w = w + M.char_width(cp)
  end
  return w
end

function M.len(s)
  local n = 0
  for _ in M.codepoints(s) do
    n = n + 1
  end
  return n
end

-- Longest byte prefix of {s} whose display width fits in {maxw}.
-- Returns the prefix and its width.
function M.sub_width(s, maxw)
  local w = 0
  local i = 1
  local n = #s
  while i <= n do
    local b = s:byte(i)
    local len = seq_len(b)
    if i + len - 1 > n then
      len = 1
    end
    local piece = s:sub(i, i + len - 1)
    local cw = M.char_width(M.codepoints(piece)())
    if w + cw > maxw then
      break
    end
    w = w + cw
    i = i + len
  end
  return s:sub(1, i - 1), w
end

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Collapses runs of whitespace into single spaces (CSS `white-space: normal`).
function M.collapse(s)
  return (s:gsub("[ \t\r\n\f]+", " "))
end

return M
