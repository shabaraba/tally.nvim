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

  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    once = true,
    callback = function()
      counter.add("$session", "load")
      M.flush()
    end,
  })

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
