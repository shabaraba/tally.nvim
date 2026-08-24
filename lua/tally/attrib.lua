local M = {}

-- UI 部品を提供するだけのプラグインは呼び出し元として扱わない
local UTILITY = {
  ["plenary.nvim"] = true,
  ["nui.nvim"] = true,
  ["nvim-notify"] = true,
  ["dressing.nvim"] = true,
  ["popup.nvim"] = true,
  ["lazy.nvim"] = true,
  ["tally.nvim"] = true,
}

M._index = nil

function M.rhs_kind(rhs)
  if type(rhs) == "function" then
    return "function"
  end
  if type(rhs) ~= "string" then
    return "other"
  end
  local lower = rhs:lower()
  if lower:match("^%s*:") or lower:match("^<cmd>") then
    return "excmd"
  end
  if lower:match("^<plug>") then
    return "plug"
  end
  return "other"
end

function M.parse_keys(keys)
  local out = {}
  if type(keys) ~= "table" then
    return out
  end
  for _, k in ipairs(keys) do
    local lhs, rhs, mode
    if type(k) == "string" then
      lhs, rhs, mode = k, nil, "n"
    elseif type(k) == "table" then
      lhs, rhs, mode = k[1], k[2], k.mode or "n"
    end
    if type(lhs) == "string" then
      local modes = type(mode) == "table" and mode or { mode }
      for _, m in ipairs(modes) do
        out[#out + 1] = { lhs = lhs, mode = m, rhs_kind = M.rhs_kind(rhs) }
      end
    end
  end
  return out
end

function M.parse_cmd(cmd)
  if type(cmd) == "string" then
    return { cmd }
  end
  local out = {}
  if type(cmd) == "table" then
    for _, c in ipairs(cmd) do
      if type(c) == "string" then
        out[#out + 1] = c
      end
    end
  end
  return out
end

function M.build(plugins)
  if not plugins then
    local ok, lazy = pcall(require, "lazy")
    if not ok then
      return nil
    end
    plugins = lazy.plugins()
  end
  if type(plugins) ~= "table" then
    return nil
  end

  local idx = { by_key = {}, by_cmd = {}, dirs = {}, kinds = {} }
  for _, p in ipairs(plugins) do
    if p.name then
      if p.dir then
        idx.dirs[#idx.dirs + 1] = { dir = p.dir, name = p.name }
      end
      for _, k in ipairs(M.parse_keys(p.keys)) do
        idx.by_key[k.mode] = idx.by_key[k.mode] or {}
        idx.by_key[k.mode][k.lhs] = p.name
        idx.kinds[p.name] = idx.kinds[p.name] or {}
        idx.kinds[p.name][k.rhs_kind] = (idx.kinds[p.name][k.rhs_kind] or 0) + 1
      end
      for _, c in ipairs(M.parse_cmd(p.cmd)) do
        idx.by_cmd[c] = p.name
      end
    end
  end
  -- 長いパスを先に見て、短い名前の前方一致による誤判定を防ぐ
  table.sort(idx.dirs, function(a, b)
    return #a.dir > #b.dir
  end)

  M._index = idx
  return idx
end

function M.index()
  return M._index or M.build()
end

function M.plugin_of_path(path, dirs)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path:sub(1, 1) == "@" then
    path = path:sub(2)
  end
  for _, d in ipairs(dirs or {}) do
    if path:sub(1, #d.dir + 1) == d.dir .. "/" then
      return d.name
    end
  end
  return nil
end

function M.resolve(level)
  local idx = M.index()
  if not idx then
    return nil
  end
  local fallback = nil
  for i = level or 2, 30 do
    local info = debug.getinfo(i, "S")
    if not info then
      break
    end
    local name = M.plugin_of_path(info.source, idx.dirs)
    if name then
      if not UTILITY[name] then
        return name
      end
      fallback = fallback or name
    end
  end
  return fallback
end

return M
