local attrib = require("tally.attrib")
local config = require("tally.config")
local lhs_mod = require("tally.lhs")
local report = require("tally.report")
local store = require("tally.store")
local track = require("tally.track")
local view = require("tally.view")

local M = {}

local LOW_RATIO = 0.1
local GROUPS = { "unused", "low", "high" }
local UNKNOWN = "-"

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
    -- lazy は keys= の宣言を代理で登録するだけなので、持ち主としては採らない。
    -- ただし押されたという事実は消さず、回数だけは足す
    local ownable = attrib.attributable(plugin)
    for lhs, n in pairs(p.key or {}) do
      local row = rows[lhs]
      if not row then
        row = { lhs = lhs, count = 0, owner = UNKNOWN, top = 0 }
        rows[lhs] = row
      end
      row.count = row.count + n
      if ownable then
        row.owner, row.top = M.better_owner(row.owner, row.top, plugin, n)
      end
    end
  end
  for _, row in pairs(rows) do
    row.top = nil
  end
  return rows
end

-- lhs -> { modes = その lhs が効くモード, owner = 包んだ時点で判った持ち主 }。
-- 一度も押されていない行の持ち主を引くのに、モードと帰属セルの両方が要る
function M.existing()
  local out = {}
  local function add(lhs, mode, callback)
    -- <Plug> はプラグイン内部のもの。Neovim 同梱のマッピングは棚卸しの対象外で、
    -- sweep も包んでいないので在庫にも入れない
    if track.is_plug_lhs(lhs) or attrib.runtime_fn(callback) then
      return
    end
    local key = lhs_mod.canonical(lhs)
    local info = out[key]
    if not info then
      info = { modes = {} }
      out[key] = info
    end
    if not vim.tbl_contains(info.modes, mode) then
      info.modes[#info.modes + 1] = mode
    end
    info.owner = info.owner or track.owner_of(callback)
  end

  -- グローバルだけでなく、ロード中バッファのバッファローカルマッピングも対象にする
  local buffers = vim.tbl_filter(vim.api.nvim_buf_is_loaded, vim.api.nvim_list_bufs())
  for _, mode in ipairs(track.MODES) do
    for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
      add(entry.lhs, mode, entry.callback)
    end
    for _, buf in ipairs(buffers) do
      for _, entry in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        add(entry.lhs, mode, entry.callback)
      end
    end
  end
  return out
end

-- 押されたことがない行の持ち主は、lazy spec の keys 宣言か、
-- 包んだ時点の帰属セルからしか分からない。分からないものを推測はしない
function M.unused_owner(lhs, info)
  if type(info) ~= "table" then
    return UNKNOWN
  end
  return track.spec_owner(info.modes, lhs) or info.owner or UNKNOWN
end

function M.classify(rows, existing, sessions)
  local groups = { hidden = { unknown = 0, passive = 0 } }
  for _, name in ipairs(GROUPS) do
    groups[name] = {}
  end
  local threshold = math.max(1, math.floor(sessions * LOW_RATIO))
  groups.threshold = threshold

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
      if config.is_passive(row.owner) then
        groups.hidden.passive = groups.hidden.passive + 1
      elseif row.count < threshold then
        table.insert(groups.low, row)
      else
        table.insert(groups.high, row)
      end
    elseif existing[lhs] then
      -- 持ち主が分からない行は「このプラグインのために張ったキーを使っていない」を
      -- 読み取れないので候補から外す。passive も同じ理由で判定対象にしない
      local owner = M.unused_owner(lhs, existing[lhs])
      if owner == UNKNOWN then
        groups.hidden.unknown = groups.hidden.unknown + 1
      elseif config.is_passive(owner) then
        groups.hidden.passive = groups.hidden.passive + 1
      else
        table.insert(groups.unused, { lhs = lhs, count = 0, owner = owner })
      end
    end
  end

  for _, name in ipairs(GROUPS) do
    table.sort(groups[name], function(a, b)
      if a.count ~= b.count then
        return a.count > b.count
      end
      return a.lhs < b.lhs
    end)
  end
  return groups
end

local function format_row(r)
  return ("  %6d  %-24s %s"):format(r.count, r.lhs, r.owner)
end

local function append_group(lines, title, rows, note)
  view.append(lines, title, rows, note, format_row)
end

-- 数を絞ったことを黙って隠さない。落とした行数とその理由は必ず見えるようにする
local function append_hidden(lines, hidden)
  local total = hidden.unknown + hidden.passive
  if total == 0 then
    return
  end
  lines[#lines + 1] = ("  %d 行は非表示（帰属不明 %d / passive %d）"):format(
    total,
    hidden.unknown,
    hidden.passive
  )
end

function M.render(sessions, groups)
  local lines = { view.head("tally keys", sessions, groups.threshold, "回") }
  append_hidden(lines, groups.hidden)
  append_group(lines, "未使用", groups.unused, "見直し候補")
  append_group(lines, "低頻度", groups.low)
  append_group(lines, "常用", groups.high)
  return lines
end

function M.show()
  local agg = report.aggregate(store.read_all(config.options.store_dir))
  local groups = M.classify(M.collect(agg), M.existing(), agg.sessions)
  view.open(M.render(agg.sessions, groups))
end

return M
