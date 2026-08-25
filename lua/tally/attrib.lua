local M = {}

-- UI 部品を提供するだけのプラグイン。呼び出し元候補としては後回しにする
local UTILITY = {
  ["plenary.nvim"] = true,
  ["nui.nvim"] = true,
  ["nvim-notify"] = true,
  ["dressing.nvim"] = true,
  ["popup.nvim"] = true,
}

-- 帰属先として絶対に採用しないプラグイン。
-- lazy は keys=/cmd= の宣言を代理で登録するだけで、利用実態を表さない
local NEVER = {
  ["lazy.nvim"] = true,
  ["tally.nvim"] = true,
}

function M.attributable(name)
  return name ~= nil and not NEVER[name]
end

M._index = nil

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
        out[#out + 1] = { lhs = lhs, mode = m, rhs = rhs }
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

  local idx = { by_key = {}, by_cmd = {}, by_plug = {}, dirs = {} }
  for _, p in ipairs(plugins) do
    if p.name then
      if p.dir then
        idx.dirs[#idx.dirs + 1] = { dir = p.dir, name = p.name }
      end
      for _, k in ipairs(M.parse_keys(p.keys)) do
        idx.by_key[k.mode] = idx.by_key[k.mode] or {}
        idx.by_key[k.mode][k.lhs] = p.name
        if type(k.rhs) == "string" and k.rhs:lower():match("^<plug>") then
          idx.by_plug[k.rhs] = p.name
        end
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

function M.plug_owner(rhs)
  local idx = M._index
  if not idx or not idx.by_plug or type(rhs) ~= "string" then
    return nil
  end
  return idx.by_plug[rhs]
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

local USER = "$user"

function M.user_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  if path:sub(1, 1) == "@" then
    path = path:sub(2)
  end
  local cfg = vim.fn.stdpath("config")
  return path:sub(1, #cfg + 1) == cfg .. "/"
end

-- 呼び出し元パスの列から帰属先を決める。resolve から切り出してテスト可能にした
function M.resolve_from(paths)
  local idx = M.index()
  if not idx then
    return nil
  end
  local fallback, user = nil, nil
  for _, path in ipairs(paths) do
    local name = M.plugin_of_path(path, idx.dirs)
    if M.attributable(name) then
      if not UTILITY[name] then
        return name
      end
      fallback = fallback or name
    elseif not user and M.user_path(path) then
      user = USER
    end
  end
  return fallback or user
end

function M.resolve(level)
  local paths = {}
  for i = level or 2, 30 do
    local info = debug.getinfo(i, "S")
    if not info then
      break
    end
    paths[#paths + 1] = info.source
  end
  return M.resolve_from(paths)
end

return M
