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
tally   142 sessions   低頻度 < 14 sess

■ 未ロード  削除候補
  vim-mql5                           0 sess  key 0      cmd 0      last -
■ 低頻度
  refactoring.nvim                   3 sess  key 4      cmd 0      last 2026-06-12
■ 常用
  yanky.nvim                       138 sess  key 47     cmd 0      last 2026-08-24
  telescope.nvim                   141 sess  key 12     cmd 892    last 2026-08-24
```

`:TallyKeys` breaks the same data down per keymap, crossing the stored counts
against the mappings that currently exist so a mapping you defined and never
press shows up as unused.

```
tally keys   142 sessions   低頻度 < 14 回
  21 行は非表示（帰属不明 4 / passive 17）

■ 未使用  見直し候補
       0  <Space>xx                trouble.nvim
       0  gr                       refactoring.nvim
■ 低頻度
       3  <Space>gs                $user
■ 常用
    1204  jj                       $user
     892  <Space>ff                telescope.nvim
```

The lhs is normalized before anything is counted: `<leader>` is expanded the way
`vim.keymap.set` expands it, `<C-w>h` and `<C-W>h` fold together, and a raw space
is spelled `<Space>`. Without that, one key splits into several rows because the
declaration and `nvim_get_keymap` spell it differently.

A row that has never been pressed carries no press record, so its owner comes
from a lazy.nvim spec's `keys` list or from the attribution tally stored when it
wrapped the mapping. Rows whose owner stays unknown, and rows owned by a
`passive` plugin, are counted in the header line instead of being listed — "you
never press this mapping" is only actionable when it says whose mapping it is.
The two are counted separately, because only one of them is something you chose.
Mappings Neovim itself ships are neither measured nor inventoried, so `grn` and
friends never reach the report at all.

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
that match are excluded from the usage verdict, in `:Tally` and in `:TallyKeys`
alike. Use it for colorschemes, and for plugins whose mappings say nothing about
whether you use them — a UI library whose popups bind `<C-f>` while they are open
otherwise dominates the keymap report.

Two switches turn keymap measurement off, and they are not the same switch:

- `track.key = false` stops all keymap counting. No mapping is wrapped by any
  route, and `:TallyKeys` has nothing to report but the mappings that exist.
- `hook_keymap_set = false` stops tally from rewriting mappings *outside* a
  plugin load. It leaves `vim.keymap.set` unhooked, so mappings you or a
  plugin set are registered exactly as written, and it also skips the
  `setup()` sweep, so no pre-existing mapping is touched. Mappings a plugin
  registers while lazy-loading are still wrapped, because that path is driven
  by the `User LazyLoad` diff rather than the hook. Set both to `false` to
  leave every mapping in the editor untouched.

## How it works

Attribution comes from three sources, most precise first:

1. **lazy.nvim specs** — `keys` and `cmd` declare exactly which left-hand sides
   and command names belong to which plugin, with no instrumentation at all.
2. **`User LazyLoad` diffing** — commands and global keymaps a plugin registers
   while loading are attributed to that plugin.
3. **Source paths** — `vim.keymap.set` and `nvim_create_user_command` are hooked,
   and the caller is resolved by walking the stack to the owning plugin
   directory.

A press that cannot be attributed to a plugin this way — because it came from
your own config, or because the startup sweep found a pre-existing mapping it
could not match to a plugin — is credited to `$user`. `$user` shows up as an
owner in `:TallyKeys`; it never appears in `:Tally`, whose plugin list is
built only from your lazy.nvim specs.

Keymaps are counted by wrapping them. A Lua callback is wrapped directly. A
string right-hand side is re-registered as an `expr` mapping that returns the
original string unchanged. The original `noremap` flag is preserved across
that swap, which is what keeps `<Plug>` still expanding while `nnoremap Y y$`
still does not; counts, registers, operator-pending and `operatorfunc` all
keep working. A string right-hand side that is also marked `expr` is left
alone, since that string is a Vimscript expression to evaluate, not a key
sequence.

`<Plug>` never appears as a left-hand side — it is plugin-internal, so only
the user-facing left-hand side is counted. A `<Plug>` mapping you wrote
yourself is credited to the plugin that provides it once tally knows which
plugin that is: either a lazy.nvim spec's `keys` list already names that
exact `<Plug>` string, or tally saw the plugin register it while firing its
own `User LazyLoad`. Until then, the press is still counted — just credited
to whoever wrote your mapping (typically `$user`) instead of the provider.
A plugin that finished loading before `tally.setup()` installed the
`LazyLoad` watcher is never picked up that second way, so for it a `keys`
declaration is the only route to correct attribution for the rest of the
session.

Global mappings that predate the hook are wrapped in a single sweep during
`setup()` — measured at 389 mappings in 2.14-2.80 ms, so the sweep runs
synchronously. Mappings whose callback comes from Neovim's own runtime are
skipped by that sweep: `grn`, `[q` and the rest of `_defaults.lua` are not
yours to prune, and listing them buries the mappings that are. The sweep is
skipped entirely when `hook_keymap_set` is `false`. Buffer-local mappings are
not part of it; see Limitations.

## What gets recorded

Only plugin names, command names, and keymap left-hand sides. No file paths, no
buffer contents, no command arguments. Everything stays under `store_dir`;
nothing is sent anywhere.

Records are appended as JSONL, one line per plugin per flush, holding the delta
since the last flush. Concurrent Neovim instances can append to the same file
safely.

A load is recorded once per session, however many times `User LazyLoad` fires
for that plugin — `:Lazy reload` would otherwise push a plugin's load count past
the session count that is supposed to be its denominator.

## Limitations

- Repeating with `.` is not counted. It does not go through the mapping.
- A right-hand side that is a string *and* marked `expr` is left alone. That
  string is an expression to evaluate, not a key sequence. tally can see that
  such a mapping exists but can never see it pressed, so it is counted among
  the hidden rows rather than listed as unused.
- A `<Nop>` right-hand side is left alone and never counted.
- A global mapping created after `setup()` outside a plugin load — through
  `nvim_set_keymap`, a `:nnoremap` in a Vimscript file sourced later, or a
  `:map` typed at runtime — is never wrapped. The `setup()` sweep has already
  run and the `User LazyLoad` diff only covers mappings a lazy-loading plugin
  registers. tally cannot name an owner for it, so it is counted in the hidden
  tally of the `:TallyKeys` header instead of being listed as unused.
- A mapping Neovim ships with a string right-hand side rather than a Lua
  callback (`&`, for one) cannot be told apart from one you wrote, so it is
  still swept and may surface as unused under `$user`.
- Buffer-local mappings are counted only when set with `vim.keymap.set` after
  the hook is installed. The startup sweep covers global mappings that
  predate the hook, but not buffer-local ones, so a pre-existing buffer-local
  mapping — or one set through a lower-level API such as
  `nvim_buf_set_keymap` — is never counted.
- `:TallyKeys` can only see buffer-local mappings in buffers that are
  currently loaded. An unpressed buffer-local mapping in a buffer that is not
  open right now is simply missing from the report, not shown as used. One
  that has been pressed still appears under its frequency group even while
  its buffer is closed.
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
