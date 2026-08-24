local M = {}

-- 1行あたりの上限。O_APPEND の追記が分割されない 4096 バイトに余裕を持たせる
local LINE_LIMIT = 3900

function M.path(dir, t)
  return dir .. "/" .. os.date("%Y-%m", t) .. ".jsonl"
end

local function build(t, plugin, load, cmd, key)
  local rec = { t = t, p = plugin }
  if load and load > 0 then
    rec.load = load
  end
  if next(cmd) then
    rec.cmd = cmd
  end
  if next(key) then
    rec.key = key
  end
  return vim.json.encode(rec)
end

function M.encode(t, plugin, counts)
  local pending = {}
  for _, kind in ipairs({ "cmd", "key" }) do
    for name, n in pairs(counts[kind] or {}) do
      pending[#pending + 1] = { kind = kind, name = name, n = n }
    end
  end
  table.sort(pending, function(a, b)
    return a.name < b.name
  end)

  local lines = {}
  local load = counts.load or 0
  local i = 1

  repeat
    local cmd, key = {}, {}
    local added = 0
    while i <= #pending do
      local e = pending[i]
      local target = e.kind == "cmd" and cmd or key
      target[e.name] = e.n
      if #build(t, plugin, load, cmd, key) > LINE_LIMIT and added > 0 then
        target[e.name] = nil
        break
      end
      i = i + 1
      added = added + 1
    end
    if load > 0 or added > 0 then
      lines[#lines + 1] = build(t, plugin, load, cmd, key)
    end
    -- load は最初の行にのみ載せる
    load = 0
  until i > #pending

  return lines
end

function M.append(dir, lines)
  if #lines == 0 then
    return true
  end
  vim.fn.mkdir(dir, "p")
  local fd, err = vim.uv.fs_open(M.path(dir, os.time()), "a", 420)
  if not fd then
    return false, err
  end
  -- 1行につき1回の fs_write。まとめて書くと追記の分割不可分性が失われる
  for _, line in ipairs(lines) do
    vim.uv.fs_write(fd, line .. "\n")
  end
  vim.uv.fs_close(fd)
  return true
end

function M.read_all(dir)
  local out = {}
  for _, file in ipairs(vim.fn.glob(dir .. "/*.jsonl", false, true)) do
    for _, line in ipairs(vim.fn.readfile(file)) do
      if line ~= "" then
        local ok, rec = pcall(vim.json.decode, line)
        if ok and type(rec) == "table" and rec.p then
          out[#out + 1] = rec
        end
      end
    end
  end
  return out
end

return M
