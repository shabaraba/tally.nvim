local M = {}

local attrib = require("tally.attrib")
local counter = require("tally.counter")
local lhs_mod = require("tally.lhs")

M.wrapped_cmds = {}

-- ラップ済みのコールバック。関数の同一性で判定するので lhs の衝突に強い
M._wrapped = setmetatable({}, { __mode = "k" })

-- ラッパ -> 可変の帰属セル。遅延ロードで持ち主が後から判明するため
M._owner = setmetatable({}, { __mode = "k" })

local USER = "$user"

function M.mark_wrapped(fn)
  M._wrapped[fn] = true
  return fn
end

function M.is_plug_lhs(lhs)
  return type(lhs) == "string" and lhs:lower():match("^<plug>") ~= nil
end

-- $user 止まりの帰属だけを、後から判明したプラグインへ格上げする。
-- 実在のプラグイン名が入っているセルは上書きしない
function M.upgrade_owner(fn, plugin)
  local cell = M._owner[fn]
  if cell and cell.plugin == USER and attrib.attributable(plugin) and plugin ~= USER then
    cell.plugin = plugin
  end
end

-- 押下を数えるラッパ。文字列 rhs は expr 化して元の文字列をそのまま返す
function M.make_wrapper(plugin, lhs, rhs)
  local cell = { plugin = plugin }
  -- 記録に残す表記はここで一度だけ正規形へ寄せる
  local key = lhs_mod.canonical(lhs)
  local fn
  if type(rhs) == "function" then
    fn = function(...)
      counter.add(cell.plugin, "key", key)
      return rhs(...)
    end
  else
    -- <Plug> の提供元は遅延ロードで後から判明するので押下時に引く
    local plug = rhs:lower():match("^<plug>") and rhs or nil
    fn = function()
      local owner = plug and attrib.plug_owner(plug) or nil
      -- 緩めたゲート越しに来た plugin は未フィルタなので、fallback 側でも弾く
      local fallback = attrib.attributable(cell.plugin) and cell.plugin or nil
      counter.add(attrib.attributable(owner) and owner or fallback, "key", key)
      return rhs
    end
  end
  M._owner[fn] = cell
  return M.mark_wrapped(fn)
end

-- 一度も押されていないマッピングの持ち主は、包んだ時点の帰属セルにしか残っていない
function M.owner_of(fn)
  local cell = M._owner[fn]
  return cell and cell.plugin or nil
end

function M.extract_cmd_name(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end
  local s = line:gsub("^[%s:]+", "")
  -- range 接頭辞を読み飛ばす
  s = s:gsub("^'[<>%a],?'?[<>%a]?", "")
  s = s:gsub("^[%%%d,%.%$%+%-]+", "")
  s = s:gsub("^[%s:]+", "")
  return s:match("^(%a[%w_]*)")
end

-- 包む側とレポート側が同じモード集合を見ないと、計測範囲と在庫がずれる
M.MODES = { "n", "v", "x", "s", "o", "i", "c", "t" }
local MODES = M.MODES

M._hooked = false
M.orig_keymap_set = nil

-- lazy spec の keys 宣言から lhs の持ち主を引く。
-- keys= のマップは lazy が代理で登録するため、スタック解決より spec が正確
function M.spec_owner(mode, lhs)
  local idx = attrib.index()
  if not idx or not idx.by_key then
    return nil
  end
  local modes = type(mode) == "table" and mode or { mode }
  local key = lhs_mod.canonical(lhs)
  for _, m in ipairs(modes) do
    local owner = idx.by_key[m] and idx.by_key[m][key]
    if owner then
      return owner
    end
  end
  return nil
end

local function hook_keymap_set()
  local orig = vim.keymap.set
  M.orig_keymap_set = orig
  vim.keymap.set = function(mode, lhs, rhs, opts)
    local key = type(lhs) == "table" and lhs[1] or lhs
    local is_expr = opts and opts.expr
    -- <Nop> を剥がすのは do_map であって replace_termcodes ではない。
    -- expr 化すると "<Nop>" の 5 文字がそのまま打鍵として実行されてしまう
    local is_nop = type(rhs) == "string" and rhs:lower() == "<nop>"
    local wrappable = (type(rhs) == "function")
      or (type(rhs) == "string" and rhs ~= "" and not is_nop and not is_expr)

    if wrappable and not M.is_plug_lhs(key) then
      local plugin = M.spec_owner(mode, key) or attrib.resolve(3)
      -- <Plug> の rhs は帰属を押下時に引き直すので、宣言元が解決できなくても包む
      local rhs_is_plug = type(rhs) == "string" and M.is_plug_lhs(rhs)
      if attrib.attributable(plugin) or rhs_is_plug then
        if type(rhs) == "string" then
          opts = opts and vim.deepcopy(opts) or {}
          opts.expr = true
          opts.replace_keycodes = true
        end
        rhs = M.make_wrapper(plugin, key, rhs)
      end
    end
    return orig(mode, lhs, rhs, opts)
  end
end

local function hook_user_command()
  local orig = vim.api.nvim_create_user_command
  vim.api.nvim_create_user_command = function(name, command, opts)
    if type(command) == "function" then
      local idx = attrib.index()
      local plugin = (idx and idx.by_cmd[name]) or attrib.resolve(3)
      if attrib.attributable(plugin) then
        local inner = command
        M.wrapped_cmds[name] = true
        command = function(...)
          counter.add(plugin, "cmd", name)
          return inner(...)
        end
      end
    end
    return orig(name, command, opts)
  end
end

function M.hook(opts)
  if M._hooked then
    return
  end
  M._hooked = true
  if opts.track.key and opts.hook_keymap_set then
    hook_keymap_set()
  end
  if opts.track.cmd then
    hook_user_command()
  end
end

function M.snapshot()
  local snap = { cmds = {}, keys = {} }
  for name in pairs(vim.api.nvim_get_commands({ builtin = false })) do
    snap.cmds[name] = true
  end
  for _, mode in ipairs(MODES) do
    snap.keys[mode] = {}
    for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
      snap.keys[mode][entry.lhs] = true
    end
  end
  return snap
end

-- nvim_get_keymap はモードのビットで一致するため、"v" の列挙には x 専用・s 専用の
-- マッピングも混ざる。ループ側のモードで張り直すと適用範囲が広がってしまうので、
-- 常に entry.mode を使う。" " は :map（nvo+select）、"!" は :map! に対応する
local function target_mode(mode, entry)
  if entry.mode == nil or entry.mode == "" then
    return mode
  end
  return entry.mode == " " and "" or entry.mode
end

local function wrap_existing(mode, entry, plugin)
  if M.is_plug_lhs(entry.lhs) then
    return
  end

  -- Neovim 同梱のマッピングは計測しない。包まなければ記録も帰属も残らず、
  -- レポートの「未使用」が defaults.lua 由来の行で埋まらずに済む
  if attrib.runtime_fn(entry.callback) then
    return
  end

  local lhs = entry.lhs
  plugin = M.spec_owner(mode, lhs) or plugin

  -- ラップ済みなら張り直さない。ただし $user 止まりの帰属だけは格上げする。
  -- 設定ディレクトリから張られたプラグインのマッピングは、フック時点では
  -- $user にしか解決できず、LazyLoad の差分で初めて持ち主が分かる
  if entry.callback and M._wrapped[entry.callback] then
    M.upgrade_owner(entry.callback, plugin)
    return
  end

  local rhs, expr
  if type(entry.callback) == "function" then
    rhs, expr = entry.callback, entry.expr == 1
  elseif type(entry.rhs) == "string" and entry.rhs ~= "" and entry.expr ~= 1 then
    rhs, expr = entry.rhs, true
  else
    return
  end

  if not attrib.attributable(plugin) then
    return
  end

  -- フック済みの vim.keymap.set を呼ぶと二重ラップになるため元の関数を使う
  local set = M.orig_keymap_set or vim.keymap.set
  set(target_mode(mode, entry), lhs, M.make_wrapper(plugin, lhs, rhs), {
    expr = expr,
    replace_keycodes = type(rhs) == "string" or nil,
    remap = entry.noremap ~= 1,
    silent = entry.silent == 1,
    nowait = entry.nowait == 1,
    desc = entry.desc,
  })
end

function M.diff_and_wrap(plugin, prev)
  local now = M.snapshot()
  local idx = attrib.index()

  for name in pairs(now.cmds) do
    if not prev.cmds[name] and idx and not idx.by_cmd[name] then
      idx.by_cmd[name] = plugin
    end
  end

  for _, mode in ipairs(MODES) do
    for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
      if not prev.keys[mode][entry.lhs] then
        if M.is_plug_lhs(entry.lhs) then
          if idx and idx.by_plug and not idx.by_plug[entry.lhs] then
            idx.by_plug[entry.lhs] = plugin
          end
        else
          wrap_existing(mode, entry, plugin)
        end
      end
    end
  end

  return M.snapshot()
end

-- early() より前から存在するマッピングを包み直す。
-- Neovim 標準のマッピングや、フック設置前に読まれた設定が対象
function M.sweep(opts)
  -- エディタ中の全マッピングを張り直す最も侵襲的な経路なので、
  -- hook_keymap_set を切った利用者の意図どおり黙る
  if not opts.track.key or not opts.hook_keymap_set then
    return
  end
  for _, mode in ipairs(MODES) do
    for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
      wrap_existing(mode, entry, USER)
    end
  end
end

function M.attach(opts)
  local group = vim.api.nvim_create_augroup("TallyTrack", { clear = true })
  local snap = M.snapshot()

  if opts.track.load or opts.track.key or opts.track.cmd then
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "LazyLoad",
      callback = function(args)
        local plugin = args.data
        if type(plugin) ~= "string" or not attrib.attributable(plugin) then
          return
        end
        if opts.track.load then
          counter.add(plugin, "load")
        end
        if opts.track.key or opts.track.cmd then
          snap = M.diff_and_wrap(plugin, snap)
        end
      end,
    })
  end

  if opts.track.cmd then
    vim.api.nvim_create_autocmd("CmdlineLeave", {
      group = group,
      callback = function()
        if vim.fn.getcmdtype() ~= ":" then
          return
        end
        if vim.v.event and vim.v.event.abort then
          return
        end
        local name = M.extract_cmd_name(vim.fn.getcmdline())
        if not name or M.wrapped_cmds[name] then
          return
        end
        local idx = attrib.index()
        local plugin = idx and idx.by_cmd[name]
        counter.add(plugin, "cmd", name)
      end,
    })
  end
end

return M
