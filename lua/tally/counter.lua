local M = {}

local data = {}

local function entry(plugin)
  local e = data[plugin]
  if not e then
    e = { load = 0, cmd = {}, key = {} }
    data[plugin] = e
  end
  return e
end

function M.add(plugin, kind, name)
  if not plugin then
    return
  end
  local e = entry(plugin)
  if kind == "load" then
    e.load = e.load + 1
  elseif name then
    e[kind][name] = (e[kind][name] or 0) + 1
  end
end

function M.drain()
  local out = data
  data = {}
  return out
end

function M.peek()
  return data
end

return M
