-- Persistence for the current design: `<cwd>/.sketch/state.json` plus one
-- HTML file per render, capped so a long session does not grow without bound.

local M = {}

local MAX_VERSIONS = 30

local function sketch_dir(cwd)
  return maki.fs.joinpath(cwd, ".sketch")
end

function M.dir(cwd)
  return sketch_dir(cwd)
end

function M.load(cwd)
  local path = maki.fs.joinpath(sketch_dir(cwd), "state.json")
  local raw = maki.fs.read(path)
  if not raw then
    return nil
  end
  local ok, state = pcall(maki.json.decode, raw)
  if not ok or type(state) ~= "table" then
    return nil
  end
  return state
end

local function prune(cwd, keep)
  local listed = maki.fs.glob("v*.html", { path = sketch_dir(cwd), sort = "name" })
  if not listed then
    return
  end
  for _, path in ipairs(listed) do
    local n = tonumber(maki.fs.basename(path):match("^v(%d+)%.html$") or "")
    if n and n <= keep - MAX_VERSIONS then
      maki.fs.rm(path)
    end
  end
end

-- Saves one version and returns it, or nil plus an error.
function M.save(cwd, html, title, points)
  local dir = sketch_dir(cwd)
  local ok, err = maki.fs.mkdir(dir, { parents = true })
  if not ok then
    return nil, err
  end

  local previous = M.load(cwd)
  local version = (previous and tonumber(previous.version) or 0) + 1

  local html_path = maki.fs.joinpath(dir, string.format("v%d.html", version))
  ok, err = maki.fs.atomic_write(html_path, html)
  if not ok then
    return nil, err
  end

  local state = {
    version = version,
    title = title or "",
    html = html,
    points = points,
    at = os.time(),
  }
  ok, err = maki.fs.atomic_write(
    maki.fs.joinpath(dir, "state.json"),
    maki.json.encode(state)
  )
  if not ok then
    return nil, err
  end

  prune(cwd, version)
  return version
end

function M.export(cwd, path, html)
  local target = path
  if not target or target == "" then
    target = maki.fs.joinpath(sketch_dir(cwd), "export.html")
  elseif target:sub(1, 1) ~= "/" and target:sub(1, 2) ~= "~/" then
    target = maki.fs.joinpath(cwd, target)
  end
  local dir = maki.fs.dirname(target)
  if dir and dir ~= "" then
    maki.fs.mkdir(dir, { parents = true })
  end
  return maki.fs.write(target, html)
end

M.MAX_VERSIONS = MAX_VERSIONS

return M
