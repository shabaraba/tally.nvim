if vim.g.loaded_tally then
  return
end
vim.g.loaded_tally = true

vim.api.nvim_create_user_command("Tally", function()
  require("tally.report").show()
end, { desc = "Show plugin usage report" })

vim.api.nvim_create_user_command("TallyKeys", function()
  require("tally.keys").show()
end, { desc = "Show keymap usage report" })
