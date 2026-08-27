local attrib = require("tally.attrib")
local config = require("tally.config")
local lhs_mod = require("tally.lhs")
local store = require("tally.store")
local view = require("tally.view")

local M = {}

local SESSION_KEY = "$session"
local LOW_RATIO = 0.1
local GROUPS = { "unloaded", "low", "high", "passive" }

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
      -- 記録された表記のゆれはここで畳む。以降の key の空間は正規形だけになる
      for name, n in pairs(rec.key or {}) do
        local key = lhs_mod.canonical(name)
        p.key[key] = (p.key[key] or 0) + n
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

function M.classify(agg, roster)
  local groups = {}
  for _, name in ipairs(GROUPS) do
    groups[name] = {}
  end
  local threshold = math.max(1, math.floor(agg.sessions * LOW_RATIO))
  groups.threshold = threshold

  for _, name in ipairs(roster) do
    -- 計測対象外のプラグインを「削除候補」として出さない
    if attrib.attributable(name) then
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
      else
        table.insert(groups.high, row)
      end
    end
  end

  for _, name in ipairs(GROUPS) do
    table.sort(groups[name], function(a, b)
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

local function format_row(r)
  return ("  %-30s %5d sess  key %-6d cmd %-6d last %s"):format(
    r.name,
    r.sessions,
    r.key_total,
    r.cmd_total,
    fmt_date(r.last)
  )
end

local function append_group(lines, title, rows, note)
  view.append(lines, title, rows, note, format_row)
end

function M.render(agg, groups)
  local lines = { view.head("tally", agg.sessions, groups.threshold, "sess") }
  append_group(lines, "未ロード", groups.unloaded, "削除候補")
  append_group(lines, "低頻度", groups.low)
  append_group(lines, "常用", groups.high)
  append_group(lines, "passive", groups.passive, "判定対象外")
  return lines
end

function M.show()
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
  view.open(M.render(agg, M.classify(agg, roster)))
end

return M
