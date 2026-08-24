local M = {}

M.wrapped_cmds = {}

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

function M.should_wrap_keymap(entry)
  if type(entry.callback) ~= "function" then
    return false
  end
  if entry.expr == 1 then
    return false
  end
  return true
end

local attrib = require("tally.attrib")
local counter = require("tally.counter")

local MODES = { "n", "v", "x", "s", "o", "i", "c", "t" }

M._hooked = false
M.orig_keymap_set = nil

local function hook_keymap_set()
  local orig = vim.keymap.set
  M.orig_keymap_set = orig
  vim.keymap.set = function(mode, lhs, rhs, opts)
    if type(rhs) == "function" and not (opts and opts.expr) then
      local plugin = attrib.resolve(3)
      if plugin then
        local inner = rhs
        local key = type(lhs) == "table" and lhs[1] or lhs
        rhs = function(...)
          counter.add(plugin, "key", key)
          return inner(...)
        end
      end
    end
    return orig(mode, lhs, rhs, opts)
  end
end

local function hook_user_command()
  local orig = vim.api.nvim_create_user_command
  vim.api.nvim_create_user_command = function(name, command, opts)
    if type(command) == "function" then
      local plugin = attrib.resolve(3)
      if plugin then
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

local function wrap_existing(mode, entry, plugin)
  if not M.should_wrap_keymap(entry) then
    return
  end
  local inner = entry.callback
  local lhs = entry.lhs
  -- フック済みの vim.keymap.set を呼ぶと二重ラップになるため元の関数を使う
  local set = M.orig_keymap_set or vim.keymap.set
  set(mode, lhs, function(...)
    counter.add(plugin, "key", lhs)
    return inner(...)
  end, {
    silent = entry.silent == 1,
    noremap = entry.noremap == 1,
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
        wrap_existing(mode, entry, plugin)
      end
    end
  end

  return M.snapshot()
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
        if type(plugin) ~= "string" then
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
