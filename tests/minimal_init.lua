local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. "/.deps/plenary.nvim")
vim.o.swapfile = false
vim.o.shadafile = "NONE"
-- --noplugin で起動するため plenary のコマンド定義を明示的に読み込む
vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
