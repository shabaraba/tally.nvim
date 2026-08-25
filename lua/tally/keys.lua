local config = require("tally.config")
local report = require("tally.report")
local store = require("tally.store")
local track = require("tally.track")

local M = {}

local LOW_RATIO = 0.1
local MODES = { "n", "v", "x", "s", "o", "i", "c", "t" }

-- 同じ lhs が複数プラグインに帰属した履歴がある場合の持ち主を決める。
-- 回数が多い方を採用し、同数なら pairs() の走査順に依存しないよう名前の昇順で選ぶ
function M.better_owner(owner, top, plugin, n)
  if n > top or (n == top and plugin < owner) then
    return plugin, n
  end
  return owner, top
end

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
      row.owner, row.top = M.better_owner(row.owner, row.top, plugin, n)
    end
  end
  for _, row in pairs(rows) do
    row.top = nil
  end
  return rows
end

local function is_plug(lhs)
  return lhs:lower():match("^<plug>") ~= nil
end

-- lhs -> その lhs が効くモードの一覧。
-- 一度も押されていない行の持ち主を lazy spec から引くのにモードが要る
function M.existing()
  local out = {}
  local function add(lhs, mode)
    if is_plug(lhs) then
      return
    end
    local modes = out[lhs]
    if not modes then
      out[lhs] = { mode }
    elseif not vim.tbl_contains(modes, mode) then
      modes[#modes + 1] = mode
    end
  end

  for _, mode in ipairs(MODES) do
    for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
      add(entry.lhs, mode)
    end
    -- グローバルだけでなく、ロード中バッファのバッファローカルマッピングも対象にする
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        for _, entry in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
          add(entry.lhs, mode)
        end
      end
    end
  end
  return out
end

-- 押されたことがない行の持ち主は、lazy spec の keys 宣言からしか分からない。
-- 分からないものを推測はしない
function M.unused_owner(lhs, modes)
  if type(modes) ~= "table" then
    return "-"
  end
  return track.spec_owner(modes, lhs) or "-"
end

function M.classify(rows, existing, sessions)
  local groups = { unused = {}, low = {}, high = {} }
  local threshold = math.max(1, math.floor(sessions * LOW_RATIO))

  -- unused は「今バインドされているのに一度も押されていない」ものだけを対象にする
  -- （現存しないマッピングを未使用として出しても意味がない）。
  -- low/high は逆に、いま現存するかどうかに関わらず記録された回数で決める
  -- （バッファローカルな束縛は、そのバッファが開かれていないと existing に現れないため）。
  local candidates = {}
  for lhs in pairs(existing) do
    candidates[lhs] = true
  end
  for lhs, row in pairs(rows) do
    if row.count > 0 then
      candidates[lhs] = true
    end
  end

  for lhs in pairs(candidates) do
    local row = rows[lhs]
    if row and row.count > 0 then
      if row.count < threshold then
        table.insert(groups.low, row)
      else
        table.insert(groups.high, row)
      end
    elseif existing[lhs] then
      table.insert(
        groups.unused,
        row or { lhs = lhs, count = 0, owner = M.unused_owner(lhs, existing[lhs]) }
      )
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
