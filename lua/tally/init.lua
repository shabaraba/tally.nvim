local config = require("tally.config")
local counter = require("tally.counter")
local store = require("tally.store")
local track = require("tally.track")

local M = {}

M._timer = nil

-- 他プラグインより先にフックを張るため lazy spec の init から呼ぶ
function M.early()
  track.hook(config.options)
end

function M._vim_entered()
  return vim.v.vim_did_enter == 1
end

-- セッション数の分母。起動直後に落ちても失われないよう即 flush する
function M.record_session()
  counter.add("$session", "load")
  M.flush()
end

function M.flush()
  local data = counter.drain()
  local t = os.time()
  local lines = {}
  for plugin, counts in pairs(data) do
    vim.list_extend(lines, store.encode(t, plugin, counts))
  end
  store.append(config.options.store_dir, lines)
end

function M.setup(opts)
  local cfg = config.setup(opts)

  track.hook(cfg)
  track.attach(cfg)

  local group = vim.api.nvim_create_augroup("Tally", { clear = true })

  -- setup が VimEnter より後に呼ばれた場合、autocmd は二度と発火しないので即記録する
  if M._vim_entered() then
    M.record_session()
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      once = true,
      callback = function()
        M.record_session()
      end,
    })
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.flush()
    end,
  })

  if M._timer then
    M._timer:stop()
    M._timer:close()
  end
  M._timer = vim.uv.new_timer()
  local interval = cfg.flush_interval * 1000
  M._timer:start(interval, interval, vim.schedule_wrap(M.flush))
end

return M
