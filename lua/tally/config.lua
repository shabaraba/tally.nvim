local M = {}

M.defaults = {
  store_dir = vim.fn.stdpath("state") .. "/tally",
  flush_interval = 300,
  passive = {},
  hook_keymap_set = true,
  track = { load = true, cmd = true, key = true },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

function M.is_passive(name)
  for _, pattern in ipairs(M.options.passive or {}) do
    local ok, found = pcall(string.find, name, pattern)
    if ok and found then
      return true
    end
  end
  return false
end

return M
