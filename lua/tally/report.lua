local attrib = require("tally.attrib")
local config = require("tally.config")
local store = require("tally.store")

local M = {}

local SESSION_KEY = "$session"
local LOW_RATIO = 0.1

function M.aggregate(records)
  local agg = { sessions = 0, plugins = {} }
  for _, rec in ipairs(records) do
    if rec.p == SESSION_KEY then
      agg.sessions = agg.sessions + (rec.load or 0)
    else
      local p = agg.plugins[rec.p]
      if not p then
        p = { sessions = 0, key = {}, cmd = {}, key_total = 0, cmd_total = 0 }
        agg.plugins[rec.p] = p
      end
      p.sessions = p.sessions + (rec.load or 0)
      for name, n in pairs(rec.key or {}) do
        p.key[name] = (p.key[name] or 0) + n
        p.key_total = p.key_total + n
      end
      for name, n in pairs(rec.cmd or {}) do
        p.cmd[name] = (p.cmd[name] or 0) + n
        p.cmd_total = p.cmd_total + n
      end
      if rec.t then
        p.first = math.min(p.first or rec.t, rec.t)
        p.last = math.max(p.last or rec.t, rec.t)
      end
    end
  end
  return agg
end

-- 押下回数を計測できない構成か。keys が <Plug> のみで、コマンドも持たない場合
function M.session_only(plugin, idx)
  local kinds = idx.kinds and idx.kinds[plugin]
  if not kinds then
    return false
  end
  if (kinds["function"] or 0) > 0 or (kinds.excmd or 0) > 0 then
    return false
  end
  if (kinds.plug or 0) == 0 then
    return false
  end
  for _, owner in pairs(idx.by_cmd or {}) do
    if owner == plugin then
      return false
    end
  end
  return true
end

function M.classify(agg, roster, idx)
  local groups = { unloaded = {}, low = {}, high = {}, passive = {}, session_only = {} }
  local threshold = math.max(1, math.floor(agg.sessions * LOW_RATIO))

  for _, name in ipairs(roster) do
    local p = agg.plugins[name] or { sessions = 0, key_total = 0, cmd_total = 0 }
    local row = {
      name = name,
      sessions = p.sessions,
      key_total = p.key_total,
      cmd_total = p.cmd_total,
      last = p.last,
    }
    if config.is_passive(name) then
      table.insert(groups.passive, row)
    elseif p.sessions == 0 then
      table.insert(groups.unloaded, row)
    elseif p.sessions < threshold then
      table.insert(groups.low, row)
    elseif M.session_only(name, idx) then
      table.insert(groups.session_only, row)
    else
      table.insert(groups.high, row)
    end
  end

  for _, list in pairs(groups) do
    table.sort(list, function(a, b)
      if a.sessions ~= b.sessions then
        return a.sessions < b.sessions
      end
      return a.name < b.name
    end)
  end
  return groups
end

local function fmt_date(t)
  return t and os.date("%Y-%m-%d", t) or "-"
end

local function append_group(lines, title, rows, note)
  if #rows == 0 then
    return
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "■ " .. title .. (note and ("  " .. note) or "")
  for _, r in ipairs(rows) do
    lines[#lines + 1] = ("  %-28s %5d sess  key %-6d cmd %-6d last %s"):format(
      r.name,
      r.sessions,
      r.key_total,
      r.cmd_total,
      fmt_date(r.last)
    )
  end
end

function M.render(agg, groups)
  local lines = { ("tally   %d sessions"):format(agg.sessions) }
  append_group(lines, "未ロード", groups.unloaded, "削除候補")
  append_group(lines, "低頻度", groups.low)
  append_group(
    lines,
    "セッション粒度のみ",
    groups.session_only,
    "<Plug> のため押下回数なし"
  )
  append_group(lines, "常用", groups.high)
  append_group(lines, "passive", groups.passive, "判定対象外")
  return lines
end

function M.show()
  local idx = attrib.index() or { by_cmd = {}, kinds = {}, dirs = {} }
  local roster = {}
  local ok, lazy = pcall(require, "lazy")
  if ok then
    for _, p in ipairs(lazy.plugins()) do
      if p.name then
        roster[#roster + 1] = p.name
      end
    end
  end

  local agg = M.aggregate(store.read_all(config.options.store_dir))
  local lines = M.render(agg, M.classify(agg, roster, idx))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "tally"
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd.tabnew()
  vim.api.nvim_win_set_buf(0, buf)
end

return M
