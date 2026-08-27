local M = {}

-- 正規形は入力文字列だけで決まるので使い回せる。起動時の sweep では
-- 同じ lhs が宣言側と既存マッピング側から何度も渡ってくる
local cache = {}

local function leader(name, fallback)
  local value = vim.g[name]
  if type(value) ~= "string" or value == "" then
    return fallback
  end
  return value
end

local EXPAND = {
  leader = function()
    return leader("mapleader", "\\")
  end,
  localleader = function()
    return leader("maplocalleader", "\\")
  end,
}

-- 一致しない <...> には nil を返す。gsub はその部分を元のまま残す
local function expand(name)
  local fn = EXPAND[name:lower()]
  return fn and fn() or nil
end

local function has_leader(lhs)
  return lhs:lower():find("leader", 1, true) ~= nil
end

local function normalize(lhs)
  local s = has_leader(lhs) and lhs:gsub("<(%a+)>", expand) or lhs
  s = vim.fn.keytrans(vim.api.nvim_replace_termcodes(s, true, true, true))
  -- 生のスペースはレポート上で空白に見えてしまう
  return (s:gsub(" ", "<Space>"))
end

-- 同じキーでも表記は一つに定まらない。<leader> は keymap.set の中で展開されるため
-- 宣言時の文字列と nvim_get_keymap が返す文字列が食い違い、<C-w> と <C-W> は
-- 大文字小文字が違うだけで別物になる。数える前に表記を一つへ寄せる。
-- keytrans を通すので戻り値は人間が読める正規形であり、二度適用しても変わらない
function M.canonical(lhs)
  if type(lhs) ~= "string" or lhs == "" then
    return lhs
  end
  local hit = cache[lhs]
  if hit then
    return hit
  end
  local ok, out = pcall(normalize, lhs)
  if not ok then
    return lhs
  end
  -- mapleader は実行中に変わりうる。それに依存した結果は使い回さない
  if not has_leader(lhs) then
    cache[lhs] = out
  end
  return out
end

return M
