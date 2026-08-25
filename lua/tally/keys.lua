local config = require("tally.config")
local report = require("tally.report")
local store = require("tally.store")

local M = {}

local LOW_RATIO = 0.1
local MODES = { "n", "v", "x", "s", "o", "i", "c", "t" }

function M.collect(agg)
  local rows = {}
  for plugin, p in pairs(agg.plugins or {}) do
    for lhs, n in pairs(p.key or {}) do
      local row = rows[lhs]
      if not row then
        row = { lhs = lhs, count = 0, owner = plugin, top = 0 }
        rows[lhs] = row
      end
      row.count = row.count + n
      -- 同じ lhs が複数プラグインに帰属した履歴がある場合は回数の多い側を採る
      if n > row.top then
        row.top, row.owner = n, plugin
      end
    end
  end
  for _, row in pairs(rows) do
    row.top = nil
  end
  return rows
end

function M.existing()
  local out = {}
  for _, mode in ipairs(MODES) do
    for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
      if not entry.lhs:lower():match("^<plug>") then
        out[entry.lhs] = true
      end
    end
  end
  return out
end

function M.classify(rows, existing, sessions)
  local groups = { unused = {}, low = {}, high = {} }
  local threshold = math.max(1, math.floor(sessions * LOW_RATIO))

  for lhs in pairs(existing) do
    local row = rows[lhs] or { lhs = lhs, count = 0, owner = "-" }
    if row.count == 0 then
      table.insert(groups.unused, row)
    elseif row.count < threshold then
      table.insert(groups.low, row)
    else
      table.insert(groups.high, row)
    end
  end

  for _, list in pairs(groups) do
    table.sort(list, function(a, b)
      if a.count ~= b.count then
        return a.count > b.count
      end
      return a.lhs < b.lhs
    end)
  end
  return groups
end

local function append_group(lines, title, rows, note)
  if #rows == 0 then
    return
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "■ " .. title .. (note and ("  " .. note) or "")
  for _, r in ipairs(rows) do
    lines[#lines + 1] = ("  %6d  %-24s %s"):format(r.count, r.lhs, r.owner)
  end
end

function M.render(sessions, groups)
  local lines = { ("tally keys   %d sessions"):format(sessions) }
  append_group(lines, "未使用", groups.unused, "見直し候補")
  append_group(lines, "低頻度", groups.low)
  append_group(lines, "常用", groups.high)
  return lines
end

function M.show()
  local agg = report.aggregate(store.read_all(config.options.store_dir))
  local groups = M.classify(M.collect(agg), M.existing(), agg.sessions)
  local lines = M.render(agg.sessions, groups)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "tally"
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd.tabnew()
  vim.api.nvim_win_set_buf(0, buf)
end

return M
