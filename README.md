# tally.nvim

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blueviolet.svg)](https://neovim.io)

Record which Neovim plugins you actually use, so you can decide which ones to remove.

tally.nvim quietly counts plugin loads, command invocations, and keymap presses
across every session, then shows you the tally with `:Tally`. Plugins you have
never loaded show up as zero.

## Requirements

- Neovim >= 0.10
- [lazy.nvim](https://github.com/folke/lazy.nvim) — attribution relies on its spec data

## Installation

```lua
{
  "shabaraba/tally.nvim",
  lazy = false,
  priority = 1000,
  init = function()
    require("tally").early()
  end,
  opts = {
    passive = { "colorscheme%-name", "hlchunk" },
  },
}
```

`init` installs the hooks before other plugins load. It is optional, but without
it command tracking falls back to typed `:` commands only.

## Usage

`:Tally` opens the report.

```
tally   142 sessions

■ 未ロード  削除候補
  vim-mql5                         0 sess  key 0      cmd 0      last -
■ 低頻度
  refactoring.nvim                 3 sess  key 4      cmd 0      last 2026-06-12
■ セッション粒度のみ  <Plug> のため押下回数なし
  yanky.nvim                     138 sess  key 0      cmd 0      last 2026-08-24
■ 常用
  telescope.nvim                 141 sess  key 12     cmd 892    last 2026-08-24
```

## Configuration

```lua
require("tally").setup({
  store_dir = vim.fn.stdpath("state") .. "/tally",
  flush_interval = 300,
  passive = {},
  hook_keymap_set = true,
  track = { load = true, cmd = true, key = true },
})
```

`passive` holds Lua patterns matched as substrings against plugin names. Plugins
that match are excluded from the usage verdict. Use it for colorschemes and
other plugins whose value is not expressed as calls.

## How it works

Attribution comes from three sources, most precise first:

1. **lazy.nvim specs** — `keys` and `cmd` declare exactly which left-hand sides
   and command names belong to which plugin, with no instrumentation at all.
2. **`User LazyLoad` diffing** — commands and global keymaps a plugin registers
   while loading are attributed to that plugin.
3. **Source paths** — `vim.keymap.set` and `nvim_create_user_command` are hooked,
   and the caller is resolved by walking the stack to the owning plugin
   directory.

Counting only ever wraps a Lua callback. String right-hand sides, `expr`
mappings, and string command definitions are passed through untouched.

## What gets recorded

Only plugin names, command names, and keymap left-hand sides. No file paths, no
buffer contents, no command arguments. Everything stays under `store_dir`;
nothing is sent anywhere.

Records are appended as JSONL, one line per plugin per flush, holding the delta
since the last flush. Concurrent Neovim instances can append to the same file
safely.

## Limitations

- Keymaps whose right-hand side is `<Plug>(...)` are counted per session, not per
  press. Wrapping them would change operator-pending semantics.
- Commands defined as Vimscript strings fall back to counting typed invocations.
- Direct Lua API calls are not counted.
- lazy.nvim only.

## Development

```bash
make test        # plenary.busted
make fmt         # stylua
make fmt-check
```

## License

MIT
