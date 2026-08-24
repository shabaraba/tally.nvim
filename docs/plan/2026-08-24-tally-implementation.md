# tally.nvim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Neovim プラグインの使用状況（ロード・コマンド実行・keymap 発火）を常時記録し、`:Tally` で棚卸しの判断材料を提示するプラグインを作る。

**Architecture:** 計測 (`track`) → 帰属解決 (`attrib`) → メモリ上の差分カウンタ (`counter`) → JSONL への定期追記 (`store`) → 集計と描画 (`report`) の一方向パイプライン。帰属は lazy.nvim の spec 情報を最優先の情報源とし、`vim.keymap.set` と `vim.api.nvim_create_user_command` を起動最初期にフックして計測点を仕掛ける。

**Tech Stack:** Lua / Neovim 0.10+ / lazy.nvim / plenary.busted / stylua

**Spec:** `docs/design/2026-08-24-tally-design.md`

## Global Constraints

- Neovim >= 0.10（`vim.uv`、`vim.json` を使う）
- lazy.nvim 必須。他のプラグインマネージャは対応しない
- ライセンス MIT、著作者 `shabaraba`、年 `2026`
- コードコメントは日本語・必要最小限。README と `doc/tally.txt` は英語
- 記録してよいのはプラグイン名・コマンド名・keymap の lhs のみ。ファイルパス、cwd、バッファ内容、コマンド引数は記録しない
- 外部送信は一切行わない
- フックは「ラップできる条件を満たすときだけラップし、それ以外は引数に一切手を触れず素通しする」を厳守する
- 整形は `stylua`。インデント2スペース
- コミットは Semantic Commit Messages（英語）

---

### Task 1: リポジトリ骨格とテスト基盤

**Files:**
- Create: `.stylua.toml`
- Create: `Makefile`
- Create: `tests/minimal_init.lua`
- Create: `tests/smoke_spec.lua`
- Create: `.github/workflows/ci.yml`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: なし
- Produces: `make test` / `make fmt-check` コマンド。以降の全タスクがこれでテストを回す

- [ ] **Step 1: `.stylua.toml` を作る**

```toml
column_width = 100
line_endings = "Unix"
indent_type = "Spaces"
indent_width = 2
quote_style = "AutoPreferDouble"
call_parentheses = "Always"
```

- [ ] **Step 2: `.gitignore` に `.deps/` を追加**

```
.DS_Store
.deps/
```

- [ ] **Step 3: `tests/minimal_init.lua` を作る**

```lua
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. "/.deps/plenary.nvim")
vim.o.swapfile = false
vim.o.shadafile = "NONE"
require("plenary.busted")
```

- [ ] **Step 4: `Makefile` を作る**

```make
.PHONY: deps test fmt fmt-check

deps:
	@test -d .deps/plenary.nvim || git clone --depth 1 \
	  https://github.com/nvim-lua/plenary.nvim .deps/plenary.nvim

test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"

fmt:
	stylua lua tests

fmt-check:
	stylua --check lua tests
```

- [ ] **Step 5: ハーネスが動くことを示す失敗テストを書く**

`tests/smoke_spec.lua`:

```lua
describe("test harness", function()
  it("can require the tally module", function()
    local ok, mod = pcall(require, "tally")
    assert.is_true(ok)
    assert.is_table(mod)
  end)
end)
```

- [ ] **Step 6: 失敗を確認する**

Run: `make test`
Expected: FAIL。`tally` モジュールが存在しないため `pcall` が false を返す

- [ ] **Step 7: 最小の `lua/tally/init.lua` を作る**

```lua
local M = {}

return M
```

- [ ] **Step 8: テストが通ることを確認する**

Run: `make test`
Expected: PASS（1 success / 0 failures）

- [ ] **Step 9: CI を作る**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          version: stable
      - run: make test

  format:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: JohnnyMorganz/stylua-action@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          version: latest
          args: --check lua tests
```

- [ ] **Step 10: 整形を確認してコミット**

```bash
make fmt-check
git add .stylua.toml Makefile tests/ .github/ .gitignore lua/
git commit -m "chore: set up test harness and CI"
```

---

### Task 2: `config.lua` — 設定のマージと passive 判定

**Files:**
- Create: `lua/tally/config.lua`
- Test: `tests/config_spec.lua`

**Interfaces:**
- Consumes: なし
- Produces:
  - `config.defaults` — table
  - `config.options` — table（`setup` 後の実効設定）
  - `config.setup(opts: table|nil) -> table`
  - `config.is_passive(name: string) -> boolean`

- [ ] **Step 1: 失敗テストを書く**

`tests/config_spec.lua`:

```lua
local config = require("tally.config")

describe("config", function()
  before_each(function()
    config.setup({})
  end)

  it("has defaults", function()
    assert.equals(300, config.options.flush_interval)
    assert.is_true(config.options.hook_keymap_set)
    assert.is_true(config.options.track.load)
    assert.same({}, config.options.passive)
  end)

  it("merges user options over defaults", function()
    config.setup({ flush_interval = 60, track = { key = false } })
    assert.equals(60, config.options.flush_interval)
    assert.is_false(config.options.track.key)
    assert.is_true(config.options.track.load)
  end)

  it("does not leak state between setup calls", function()
    config.setup({ flush_interval = 60 })
    config.setup({})
    assert.equals(300, config.options.flush_interval)
  end)

  it("matches passive patterns as substrings", function()
    config.setup({ passive = { "solarized%-osaka", "hlchunk" } })
    assert.is_true(config.is_passive("solarized-osaka.nvim"))
    assert.is_true(config.is_passive("hlchunk.nvim"))
    assert.is_false(config.is_passive("telescope.nvim"))
  end)

  it("supports anchored patterns for exact match", function()
    config.setup({ passive = { "^oil%.nvim$" } })
    assert.is_true(config.is_passive("oil.nvim"))
    assert.is_false(config.is_passive("oil.nvim.extra"))
  end)

  it("ignores malformed patterns instead of erroring", function()
    config.setup({ passive = { "[unclosed" } })
    assert.is_false(config.is_passive("telescope.nvim"))
  end)
end)
```

- [ ] **Step 2: 失敗を確認する**

Run: `make test`
Expected: FAIL。`module 'tally.config' not found`

- [ ] **Step 3: 実装する**

`lua/tally/config.lua`:

```lua
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
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `make test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
make fmt-check
git add lua/tally/config.lua tests/config_spec.lua
git commit -m "feat: add config module with passive pattern matching"
```

---

### Task 3: `counter.lua` — メモリ上の差分カウンタ

**Files:**
- Create: `lua/tally/counter.lua`
- Test: `tests/counter_spec.lua`

**Interfaces:**
- Consumes: なし
- Produces:
  - `counter.add(plugin: string|nil, kind: "load"|"cmd"|"key", name: string|nil)` — `plugin` が nil なら何もしない
  - `counter.drain() -> table` — `{ [plugin] = { load = n, cmd = { [name] = n }, key = { [lhs] = n } } }` を返し、内部状態を空にする
  - `counter.peek() -> table` — 空にせず現在値を返す

- [ ] **Step 1: 失敗テストを書く**

`tests/counter_spec.lua`:

```lua
local counter = require("tally.counter")

describe("counter", function()
  before_each(function()
    counter.drain()
  end)

  it("accumulates load counts", function()
    counter.add("flash.nvim", "load")
    counter.add("flash.nvim", "load")
    assert.equals(2, counter.peek()["flash.nvim"].load)
  end)

  it("accumulates named key and cmd counts", function()
    counter.add("telescope.nvim", "cmd", "Telescope")
    counter.add("telescope.nvim", "cmd", "Telescope")
    counter.add("flash.nvim", "key", "gs")
    local data = counter.peek()
    assert.equals(2, data["telescope.nvim"].cmd["Telescope"])
    assert.equals(1, data["flash.nvim"].key["gs"])
  end)

  it("ignores nil plugin", function()
    counter.add(nil, "key", "gs")
    assert.same({}, counter.peek())
  end)

  it("drain empties internal state", function()
    counter.add("oil.nvim", "load")
    local first = counter.drain()
    assert.equals(1, first["oil.nvim"].load)
    assert.same({}, counter.peek())
  end)

  it("drain returns a snapshot unaffected by later adds", function()
    counter.add("oil.nvim", "load")
    local snapshot = counter.drain()
    counter.add("oil.nvim", "load")
    assert.equals(1, snapshot["oil.nvim"].load)
  end)
end)
```

- [ ] **Step 2: 失敗を確認する**

Run: `make test`
Expected: FAIL。`module 'tally.counter' not found`

- [ ] **Step 3: 実装する**

`lua/tally/counter.lua`:

```lua
local M = {}

local data = {}

local function entry(plugin)
  local e = data[plugin]
  if not e then
    e = { load = 0, cmd = {}, key = {} }
    data[plugin] = e
  end
  return e
end

function M.add(plugin, kind, name)
  if not plugin then
    return
  end
  local e = entry(plugin)
  if kind == "load" then
    e.load = e.load + 1
  elseif name then
    e[kind][name] = (e[kind][name] or 0) + 1
  end
end

function M.drain()
  local out = data
  data = {}
  return out
end

function M.peek()
  return data
end

return M
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `make test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
make fmt-check
git add lua/tally/counter.lua tests/counter_spec.lua
git commit -m "feat: add in-memory delta counter"
```

---

### Task 4: `store.lua` — JSONL の書き出しと読み出し

**Files:**
- Create: `lua/tally/store.lua`
- Test: `tests/store_spec.lua`

**Interfaces:**
- Consumes: なし
- Produces:
  - `store.path(dir: string, t: number) -> string` — `<dir>/YYYY-MM.jsonl`
  - `store.encode(t: number, plugin: string, counts: table) -> string[]` — 各要素が 1 行の JSON。4096 バイト未満に分割される
  - `store.append(dir: string, lines: string[]) -> boolean, string|nil`
  - `store.read_all(dir: string) -> table[]` — デコード済みレコードの配列

`counts` は `counter.drain()` の1プラグイン分、すなわち `{ load = n, cmd = {...}, key = {...} }`。

- [ ] **Step 1: 失敗テストを書く**

`tests/store_spec.lua`:

```lua
local store = require("tally.store")

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

describe("store", function()
  it("builds a monthly path", function()
    local t = os.time({ year = 2026, month = 3, day = 15, hour = 12 })
    assert.equals("/tmp/x/2026-03.jsonl", store.path("/tmp/x", t))
  end)

  it("encodes a single compact line", function()
    local lines = store.encode(100, "flash.nvim", { load = 1, cmd = {}, key = { gs = 3 } })
    assert.equals(1, #lines)
    local rec = vim.json.decode(lines[1])
    assert.equals("flash.nvim", rec.p)
    assert.equals(100, rec.t)
    assert.equals(1, rec.load)
    assert.equals(3, rec.key.gs)
    assert.is_nil(rec.cmd)
  end)

  it("omits zero load", function()
    local lines = store.encode(100, "oil.nvim", { load = 0, cmd = { Oil = 1 }, key = {} })
    local rec = vim.json.decode(lines[1])
    assert.is_nil(rec.load)
    assert.equals(1, rec.cmd.Oil)
  end)

  it("encodes nothing when there is no activity", function()
    assert.same({}, store.encode(100, "oil.nvim", { load = 0, cmd = {}, key = {} }))
  end)

  it("splits oversized records into multiple lines under 4096 bytes", function()
    local key = {}
    for i = 1, 400 do
      key[("lhs_%03d_%s"):format(i, string.rep("x", 20))] = i
    end
    local lines = store.encode(100, "big.nvim", { load = 1, cmd = {}, key = key })
    assert.is_true(#lines > 1)
    for _, line in ipairs(lines) do
      assert.is_true(#line < 4096, "line too long: " .. #line)
    end
    local total, load_seen = 0, 0
    for _, line in ipairs(lines) do
      local rec = vim.json.decode(line)
      load_seen = load_seen + (rec.load or 0)
      for _, n in pairs(rec.key or {}) do
        total = total + n
      end
    end
    assert.equals(1, load_seen)
    assert.equals(400 * 401 / 2, total)
  end)

  it("round-trips through append and read_all", function()
    local dir = tmpdir()
    store.append(dir, store.encode(100, "flash.nvim", { load = 1, cmd = {}, key = { gs = 2 } }))
    store.append(dir, store.encode(200, "flash.nvim", { load = 1, cmd = {}, key = { gs = 5 } }))
    local records = store.read_all(dir)
    assert.equals(2, #records)
    local sum = 0
    for _, rec in ipairs(records) do
      sum = sum + rec.key.gs
    end
    assert.equals(7, sum)
  end)

  it("creates the directory if missing", function()
    local dir = vim.fn.tempname() .. "/nested"
    assert.is_true(store.append(dir, store.encode(100, "a.nvim", { load = 1 })))
    assert.equals(1, #store.read_all(dir))
  end)

  it("skips malformed lines", function()
    local dir = tmpdir()
    store.append(dir, store.encode(100, "flash.nvim", { load = 1 }))
    local path = store.path(dir, os.time())
    local fd = vim.uv.fs_open(path, "a", 420)
    vim.uv.fs_write(fd, '{"p":"broken"\n')
    vim.uv.fs_close(fd)
    local records = store.read_all(dir)
    assert.equals(1, #records)
    assert.equals("flash.nvim", records[1].p)
  end)

  it("returns an empty list for a missing directory", function()
    assert.same({}, store.read_all(vim.fn.tempname()))
  end)
end)
```

- [ ] **Step 2: 失敗を確認する**

Run: `make test`
Expected: FAIL。`module 'tally.store' not found`

- [ ] **Step 3: 実装する**

`lua/tally/store.lua`:

```lua
local M = {}

-- 1行あたりの上限。O_APPEND の追記が分割されない 4096 バイトに余裕を持たせる
local LINE_LIMIT = 3900

function M.path(dir, t)
  return dir .. "/" .. os.date("%Y-%m", t) .. ".jsonl"
end

local function build(t, plugin, load, cmd, key)
  local rec = { t = t, p = plugin }
  if load and load > 0 then
    rec.load = load
  end
  if next(cmd) then
    rec.cmd = cmd
  end
  if next(key) then
    rec.key = key
  end
  return vim.json.encode(rec)
end

function M.encode(t, plugin, counts)
  local pending = {}
  for _, kind in ipairs({ "cmd", "key" }) do
    for name, n in pairs(counts[kind] or {}) do
      pending[#pending + 1] = { kind = kind, name = name, n = n }
    end
  end
  table.sort(pending, function(a, b)
    return a.name < b.name
  end)

  local lines = {}
  local load = counts.load or 0
  local i = 1

  repeat
    local cmd, key = {}, {}
    local added = 0
    while i <= #pending do
      local e = pending[i]
      local target = e.kind == "cmd" and cmd or key
      target[e.name] = e.n
      if #build(t, plugin, load, cmd, key) > LINE_LIMIT and added > 0 then
        target[e.name] = nil
        break
      end
      i = i + 1
      added = added + 1
    end
    if load > 0 or added > 0 then
      lines[#lines + 1] = build(t, plugin, load, cmd, key)
    end
    -- load は最初の行にのみ載せる
    load = 0
  until i > #pending

  return lines
end

function M.append(dir, lines)
  if #lines == 0 then
    return true
  end
  vim.fn.mkdir(dir, "p")
  local fd, err = vim.uv.fs_open(M.path(dir, os.time()), "a", 420)
  if not fd then
    return false, err
  end
  -- 1行につき1回の fs_write。まとめて書くと追記の分割不可分性が失われる
  for _, line in ipairs(lines) do
    vim.uv.fs_write(fd, line .. "\n")
  end
  vim.uv.fs_close(fd)
  return true
end

function M.read_all(dir)
  local out = {}
  for _, file in ipairs(vim.fn.glob(dir .. "/*.jsonl", false, true)) do
    for _, line in ipairs(vim.fn.readfile(file)) do
      if line ~= "" then
        local ok, rec = pcall(vim.json.decode, line)
        if ok and type(rec) == "table" and rec.p then
          out[#out + 1] = rec
        end
      end
    end
  end
  return out
end

return M
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `make test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
make fmt-check
git add lua/tally/store.lua tests/store_spec.lua
git commit -m "feat: add JSONL store with atomic append and record splitting"
```

---

### Task 5: `attrib.lua` — lazy spec の解析とパスからの帰属

**Files:**
- Create: `lua/tally/attrib.lua`
- Test: `tests/attrib_spec.lua`

**Interfaces:**
- Consumes: なし
- Produces:
  - `attrib.rhs_kind(rhs: any) -> "function"|"excmd"|"plug"|"other"`
  - `attrib.parse_keys(keys: any) -> table[]` — 各要素 `{ lhs = string, mode = string, rhs_kind = string }`
  - `attrib.parse_cmd(cmd: any) -> string[]`
  - `attrib.build(plugins: table[]|nil) -> table` — `plugins` 省略時は `require("lazy").plugins()`。戻り値は `{ by_key = { [mode] = { [lhs] = plugin } }, by_cmd = { [name] = plugin }, dirs = { { dir, name } }, kinds = { [plugin] = { [rhs_kind] = count } } }`
  - `attrib.index() -> table|nil` — 構築済みインデックス。未構築なら構築を試みる
  - `attrib.plugin_of_path(path: string, dirs: table[]) -> string|nil`
  - `attrib.resolve(level: number) -> string|nil` — 呼び出しスタックを遡ってプラグイン名を返す

`dirs` は長いパスが先に来るようソート済みであること（`/lazy/a` より `/lazy/ab` を優先させるため）。

- [ ] **Step 1: 失敗テストを書く**

`tests/attrib_spec.lua`:

```lua
local attrib = require("tally.attrib")

describe("attrib.rhs_kind", function()
  it("classifies functions", function()
    assert.equals("function", attrib.rhs_kind(function() end))
  end)

  it("classifies ex commands", function()
    assert.equals("excmd", attrib.rhs_kind(":Telescope find_files <cr>"))
    assert.equals("excmd", attrib.rhs_kind("<cmd>Trouble diagnostics toggle<cr>"))
    assert.equals("excmd", attrib.rhs_kind("<Cmd>Oil<CR>"))
  end)

  it("classifies plug mappings", function()
    assert.equals("plug", attrib.rhs_kind("<Plug>(YankyYank)"))
    assert.equals("plug", attrib.rhs_kind("<plug>(nvim-surround-normal)"))
  end)

  it("classifies anything else as other", function()
    assert.equals("other", attrib.rhs_kind("gg"))
    assert.equals("other", attrib.rhs_kind(nil))
  end)
end)

describe("attrib.parse_keys", function()
  it("handles a bare string entry as normal mode", function()
    local got = attrib.parse_keys({ "gs" })
    assert.equals(1, #got)
    assert.equals("gs", got[1].lhs)
    assert.equals("n", got[1].mode)
  end)

  it("handles a table entry with rhs and mode", function()
    local got = attrib.parse_keys({ { "gs", function() end, mode = "x" } })
    assert.equals("gs", got[1].lhs)
    assert.equals("x", got[1].mode)
    assert.equals("function", got[1].rhs_kind)
  end)

  it("expands a mode list into one entry per mode", function()
    local got = attrib.parse_keys({ { ",s", "<Plug>(nvim-surround-normal)", mode = { "n", "v" } } })
    assert.equals(2, #got)
    assert.equals("n", got[1].mode)
    assert.equals("v", got[2].mode)
    assert.equals("plug", got[1].rhs_kind)
  end)

  it("defaults mode to n when absent", function()
    local got = attrib.parse_keys({ { ";f", ":Telescope find_files <cr>" } })
    assert.equals("n", got[1].mode)
    assert.equals("excmd", got[1].rhs_kind)
  end)

  it("returns empty for non-table input", function()
    assert.same({}, attrib.parse_keys(nil))
    assert.same({}, attrib.parse_keys("gs"))
  end)
end)

describe("attrib.parse_cmd", function()
  it("wraps a single string", function()
    assert.same({ "Trouble" }, attrib.parse_cmd("Trouble"))
  end)

  it("passes through a list", function()
    assert.same({ "Oil", "OilOpen" }, attrib.parse_cmd({ "Oil", "OilOpen" }))
  end)

  it("returns empty for nil", function()
    assert.same({}, attrib.parse_cmd(nil))
  end)
end)

describe("attrib.build", function()
  local plugins = {
    {
      name = "telescope.nvim",
      dir = "/data/lazy/telescope.nvim",
      keys = { { ";f", ":Telescope find_files <cr>" } },
    },
    {
      name = "trouble.nvim",
      dir = "/data/lazy/trouble.nvim",
      cmd = "Trouble",
      keys = { { "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>" } },
    },
    { name = "flash.nvim", dir = "/data/lazy/flash.nvim", keys = { { "gs", function() end } } },
    { name = "nvim-cmp", dir = "/data/lazy/nvim-cmp" },
  }

  it("indexes keys by mode and lhs", function()
    local idx = attrib.build(plugins)
    assert.equals("telescope.nvim", idx.by_key["n"][";f"])
    assert.equals("flash.nvim", idx.by_key["n"]["gs"])
  end)

  it("indexes commands", function()
    local idx = attrib.build(plugins)
    assert.equals("trouble.nvim", idx.by_cmd["Trouble"])
  end)

  it("records rhs kind counts per plugin", function()
    local idx = attrib.build(plugins)
    assert.equals(1, idx.kinds["telescope.nvim"]["excmd"])
    assert.equals(1, idx.kinds["flash.nvim"]["function"])
  end)

  it("sorts dirs longest first", function()
    local idx = attrib.build({
      { name = "a", dir = "/data/lazy/a" },
      { name = "ab", dir = "/data/lazy/ab" },
    })
    assert.equals("/data/lazy/ab", idx.dirs[1].dir)
  end)
end)

describe("attrib.plugin_of_path", function()
  local dirs = {
    { dir = "/data/lazy/telescope.nvim", name = "telescope.nvim" },
    { dir = "/data/lazy/a", name = "a" },
  }

  it("resolves a path inside a plugin dir", function()
    assert.equals(
      "telescope.nvim",
      attrib.plugin_of_path("/data/lazy/telescope.nvim/lua/telescope/init.lua", dirs)
    )
  end)

  it("strips a leading at-sign from lua sources", function()
    assert.equals("a", attrib.plugin_of_path("@/data/lazy/a/lua/a.lua", dirs))
  end)

  it("does not match a prefix of a longer dir name", function()
    assert.is_nil(attrib.plugin_of_path("/data/lazy/abc/lua/x.lua", dirs))
  end)

  it("returns nil outside any plugin dir", function()
    assert.is_nil(attrib.plugin_of_path("/home/me/.config/nvim/init.lua", dirs))
  end)
end)
```

- [ ] **Step 2: 失敗を確認する**

Run: `make test`
Expected: FAIL。`module 'tally.attrib' not found`

- [ ] **Step 3: 実装する**

`lua/tally/attrib.lua`:

```lua
local M = {}

-- UI 部品を提供するだけのプラグインは呼び出し元として扱わない
local UTILITY = {
  ["plenary.nvim"] = true,
  ["nui.nvim"] = true,
  ["nvim-notify"] = true,
  ["dressing.nvim"] = true,
  ["popup.nvim"] = true,
  ["lazy.nvim"] = true,
  ["tally.nvim"] = true,
}

M._index = nil

function M.rhs_kind(rhs)
  if type(rhs) == "function" then
    return "function"
  end
  if type(rhs) ~= "string" then
    return "other"
  end
  local lower = rhs:lower()
  if lower:match("^%s*:") or lower:match("^<cmd>") then
    return "excmd"
  end
  if lower:match("^<plug>") then
    return "plug"
  end
  return "other"
end

function M.parse_keys(keys)
  local out = {}
  if type(keys) ~= "table" then
    return out
  end
  for _, k in ipairs(keys) do
    local lhs, rhs, mode
    if type(k) == "string" then
      lhs, rhs, mode = k, nil, "n"
    elseif type(k) == "table" then
      lhs, rhs, mode = k[1], k[2], k.mode or "n"
    end
    if type(lhs) == "string" then
      local modes = type(mode) == "table" and mode or { mode }
      for _, m in ipairs(modes) do
        out[#out + 1] = { lhs = lhs, mode = m, rhs_kind = M.rhs_kind(rhs) }
      end
    end
  end
  return out
end

function M.parse_cmd(cmd)
  if type(cmd) == "string" then
    return { cmd }
  end
  local out = {}
  if type(cmd) == "table" then
    for _, c in ipairs(cmd) do
      if type(c) == "string" then
        out[#out + 1] = c
      end
    end
  end
  return out
end

function M.build(plugins)
  if not plugins then
    local ok, lazy = pcall(require, "lazy")
    if not ok then
      return nil
    end
    plugins = lazy.plugins()
  end
  if type(plugins) ~= "table" then
    return nil
  end

  local idx = { by_key = {}, by_cmd = {}, dirs = {}, kinds = {} }
  for _, p in ipairs(plugins) do
    if p.name then
      if p.dir then
        idx.dirs[#idx.dirs + 1] = { dir = p.dir, name = p.name }
      end
      for _, k in ipairs(M.parse_keys(p.keys)) do
        idx.by_key[k.mode] = idx.by_key[k.mode] or {}
        idx.by_key[k.mode][k.lhs] = p.name
        idx.kinds[p.name] = idx.kinds[p.name] or {}
        idx.kinds[p.name][k.rhs_kind] = (idx.kinds[p.name][k.rhs_kind] or 0) + 1
      end
      for _, c in ipairs(M.parse_cmd(p.cmd)) do
        idx.by_cmd[c] = p.name
      end
    end
  end
  -- 長いパスを先に見て、短い名前の前方一致による誤判定を防ぐ
  table.sort(idx.dirs, function(a, b)
    return #a.dir > #b.dir
  end)

  M._index = idx
  return idx
end

function M.index()
  return M._index or M.build()
end

function M.plugin_of_path(path, dirs)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path:sub(1, 1) == "@" then
    path = path:sub(2)
  end
  for _, d in ipairs(dirs or {}) do
    if path:sub(1, #d.dir + 1) == d.dir .. "/" then
      return d.name
    end
  end
  return nil
end

function M.resolve(level)
  local idx = M.index()
  if not idx then
    return nil
  end
  local fallback = nil
  for i = level or 2, 30 do
    local info = debug.getinfo(i, "S")
    if not info then
      break
    end
    local name = M.plugin_of_path(info.source, idx.dirs)
    if name then
      if not UTILITY[name] then
        return name
      end
      fallback = fallback or name
    end
  end
  return fallback
end

return M
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `make test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
make fmt-check
git add lua/tally/attrib.lua tests/attrib_spec.lua
git commit -m "feat: add attribution from lazy specs and source paths"
```

---

### Task 6: `track.lua` — コマンド名の抽出とフックのラップ判定

このタスクでは純粋関数だけを実装する。副作用のあるフック設置は Task 7。

**Files:**
- Create: `lua/tally/track.lua`
- Test: `tests/track_spec.lua`

**Interfaces:**
- Consumes: `attrib`, `counter`
- Produces:
  - `track.extract_cmd_name(line: string|nil) -> string|nil`
  - `track.should_wrap_keymap(entry: table) -> boolean` — `entry` は `nvim_get_keymap` の1要素
  - `track.wrapped_cmds: table` — `{ [cmd_name] = true }`。Task 7 のコマンドフックが記録し、`CmdlineLeave` の二重計上防止に使う

- [ ] **Step 1: 失敗テストを書く**

`tests/track_spec.lua`:

```lua
local track = require("tally.track")

describe("track.extract_cmd_name", function()
  it("extracts a plain command", function()
    assert.equals("Telescope", track.extract_cmd_name("Telescope find_files"))
  end)

  it("strips a leading colon", function()
    assert.equals("Telescope", track.extract_cmd_name(":Telescope find_files"))
  end)

  it("strips leading whitespace", function()
    assert.equals("Oil", track.extract_cmd_name("  Oil"))
  end)

  it("skips a numeric range prefix", function()
    assert.equals("Foo", track.extract_cmd_name("1,5Foo"))
  end)

  it("skips a percent range prefix", function()
    assert.equals("s", track.extract_cmd_name("%s/a/b/"))
  end)

  it("skips a visual mark range prefix", function()
    assert.equals("Trouble", track.extract_cmd_name("'<,'>Trouble"))
  end)

  it("returns nil for an empty or non-command line", function()
    assert.is_nil(track.extract_cmd_name(""))
    assert.is_nil(track.extract_cmd_name(nil))
    assert.is_nil(track.extract_cmd_name("123"))
  end)
end)

describe("track.should_wrap_keymap", function()
  it("accepts a lua callback", function()
    assert.is_true(track.should_wrap_keymap({ callback = function() end, expr = 0 }))
  end)

  it("rejects a string rhs", function()
    assert.is_false(track.should_wrap_keymap({ rhs = ":Telescope<cr>", expr = 0 }))
  end)

  it("rejects an expr mapping", function()
    assert.is_false(track.should_wrap_keymap({ callback = function() end, expr = 1 }))
  end)
end)
```

- [ ] **Step 2: 失敗を確認する**

Run: `make test`
Expected: FAIL。`module 'tally.track' not found`

- [ ] **Step 3: 実装する**

`lua/tally/track.lua`:

```lua
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

return M
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `make test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
make fmt-check
git add lua/tally/track.lua tests/track_spec.lua
git commit -m "feat: add command name extraction and keymap wrap predicate"
```

---

### Task 7: `track.lua` — フックの設置と LazyLoad 差分

**Files:**
- Modify: `lua/tally/track.lua`
- Test: `tests/track_hook_spec.lua`

**Interfaces:**
- Consumes: `attrib`, `counter`, Task 6 の `track.wrapped_cmds` / `should_wrap_keymap` / `extract_cmd_name`
- Produces:
  - `track.hook(opts: table)` — `vim.keymap.set` と `vim.api.nvim_create_user_command` を差し替える。冪等
  - `track.orig_keymap_set` — 差し替え前の `vim.keymap.set`。内部での再登録に使う（フック済みの関数を呼ぶと二重ラップになる）
  - `track.snapshot() -> table` — `{ cmds = { [name] = true }, keys = { [mode] = { [lhs] = true } } }`
  - `track.diff_and_wrap(plugin: string, prev: table) -> table` — 新スナップショットを返す。差分の新規グローバル keymap をラップし、新規コマンドを `attrib` の `by_cmd` に登録する
  - `track.attach(opts: table)` — `User LazyLoad` と `CmdlineLeave` の autocmd を登録し、初期スナップショットを取る

`opts` は `config.options`。

- [ ] **Step 1: 失敗テストを書く**

`tests/track_hook_spec.lua`:

```lua
local track = require("tally.track")
local counter = require("tally.counter")
local attrib = require("tally.attrib")

local function fake_index()
  attrib._index = {
    by_key = {},
    by_cmd = {},
    kinds = {},
    dirs = { { dir = "/data/lazy/fake.nvim", name = "fake.nvim" } },
  }
end

describe("track.hook", function()
  local saved_set, saved_cmd

  before_each(function()
    counter.drain()
    fake_index()
    saved_set = vim.keymap.set
    saved_cmd = vim.api.nvim_create_user_command
    track._hooked = false
  end)

  after_each(function()
    vim.keymap.set = saved_set
    vim.api.nvim_create_user_command = saved_cmd
    track._hooked = false
    attrib._index = nil
  end)

  it("is idempotent", function()
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = true } })
    local after_first = vim.keymap.set
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = true } })
    assert.equals(after_first, vim.keymap.set)
  end)

  it("keeps the original function available", function()
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = true } })
    assert.equals(saved_set, track.orig_keymap_set)
  end)

  it("passes string rhs through untouched", function()
    local seen
    vim.keymap.set = function(_, _, rhs)
      seen = rhs
    end
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = true } })
    vim.keymap.set("n", "gx", ":Foo<cr>")
    assert.equals(":Foo<cr>", seen)
  end)

  it("passes expr mappings through untouched", function()
    local original = function() end
    local seen
    vim.keymap.set = function(_, _, rhs)
      seen = rhs
    end
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = true } })
    vim.keymap.set("n", "j", original, { expr = true })
    assert.equals(original, seen)
  end)

  it("does not wrap when the caller is not a plugin", function()
    local original = function() end
    local seen
    vim.keymap.set = function(_, _, rhs)
      seen = rhs
    end
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = true } })
    vim.keymap.set("n", "gy", original)
    assert.equals(original, seen)
  end)

  it("records wrapped command names for dedup", function()
    vim.api.nvim_create_user_command = function() end
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = true } })
    -- 呼び出し元がプラグインでないためラップされず、記録もされない
    vim.api.nvim_create_user_command("Nope", function() end, {})
    assert.is_nil(track.wrapped_cmds["Nope"])
  end)

  it("passes string command definitions through untouched", function()
    local seen
    vim.api.nvim_create_user_command = function(_, command)
      seen = command
    end
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = true } })
    vim.api.nvim_create_user_command("Legacy", "echo 1", {})
    assert.equals("echo 1", seen)
  end)
end)

describe("track.snapshot and diff_and_wrap", function()
  before_each(function()
    counter.drain()
    fake_index()
  end)

  after_each(function()
    pcall(vim.keymap.del, "n", "<Plug>TallyTestA")
    pcall(vim.api.nvim_del_user_command, "TallyTestCmd")
    attrib._index = nil
  end)

  it("captures existing commands and keymaps", function()
    local snap = track.snapshot()
    assert.is_table(snap.cmds)
    assert.is_table(snap.keys["n"])
  end)

  it("attributes newly created commands to the loading plugin", function()
    local prev = track.snapshot()
    vim.api.nvim_create_user_command("TallyTestCmd", function() end, {})
    track.diff_and_wrap("fake.nvim", prev)
    assert.equals("fake.nvim", attrib.index().by_cmd["TallyTestCmd"])
  end)

  it("counts a press of a newly wrapped keymap", function()
    local prev = track.snapshot()
    local hits = 0
    vim.keymap.set("n", "<Plug>TallyTestA", function()
      hits = hits + 1
    end)
    track.diff_and_wrap("fake.nvim", prev)

    local entry
    for _, e in ipairs(vim.api.nvim_get_keymap("n")) do
      if e.lhs == "<Plug>TallyTestA" then
        entry = e
      end
    end
    assert.is_table(entry)
    entry.callback()

    assert.equals(1, hits)
    assert.equals(1, counter.peek()["fake.nvim"].key["<Plug>TallyTestA"])
  end)
end)
```

- [ ] **Step 2: 失敗を確認する**

Run: `make test`
Expected: FAIL。`track.hook` が nil

- [ ] **Step 3: `track.lua` にフックと差分処理を追加する**

`lua/tally/track.lua` の `return M` の直前に追記:

```lua
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
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `make test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
make fmt-check
git add lua/tally/track.lua tests/track_hook_spec.lua
git commit -m "feat: hook keymap.set and create_user_command, diff on LazyLoad"
```

---

### Task 8: `init.lua` — 起動シーケンスと flush

**Files:**
- Modify: `lua/tally/init.lua`
- Test: `tests/init_spec.lua`

**Interfaces:**
- Consumes: `config`, `counter`, `store`, `track`
- Produces:
  - `tally.early()` — フックのみ設置。`config.setup` 前でも動くよう既定値を使う
  - `tally.setup(opts: table|nil)` — 設定マージ、`track.attach`、タイマー、`VimLeavePre` / `VimEnter` の autocmd 登録
  - `tally.flush()` — `counter.drain()` の内容を `store` に書き出す

- [ ] **Step 1: 失敗テストを書く**

`tests/init_spec.lua`:

```lua
local tally = require("tally")
local counter = require("tally.counter")
local config = require("tally.config")
local store = require("tally.store")

describe("tally.flush", function()
  local dir

  before_each(function()
    counter.drain()
    dir = vim.fn.tempname()
    config.setup({ store_dir = dir })
  end)

  it("writes drained counts to the store", function()
    counter.add("flash.nvim", "load")
    counter.add("flash.nvim", "key", "gs")
    counter.add("flash.nvim", "key", "gs")
    tally.flush()

    local records = store.read_all(dir)
    assert.equals(1, #records)
    assert.equals("flash.nvim", records[1].p)
    assert.equals(1, records[1].load)
    assert.equals(2, records[1].key.gs)
  end)

  it("empties the counter so the next flush is a delta", function()
    counter.add("oil.nvim", "load")
    tally.flush()
    tally.flush()
    assert.equals(1, #store.read_all(dir))
  end)

  it("writes nothing when there is no activity", function()
    tally.flush()
    assert.same({}, store.read_all(dir))
  end)

  it("writes one record per plugin", function()
    counter.add("a.nvim", "load")
    counter.add("b.nvim", "load")
    tally.flush()
    assert.equals(2, #store.read_all(dir))
  end)
end)
```

- [ ] **Step 2: 失敗を確認する**

Run: `make test`
Expected: FAIL。`tally.flush` が nil

- [ ] **Step 3: 実装する**

`lua/tally/init.lua` を全面的に書き換える:

```lua
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
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `make test`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
make fmt-check
git add lua/tally/init.lua tests/init_spec.lua
git commit -m "feat: wire setup, early hook installation, and periodic flush"
```

---

### Task 9: `report.lua` — 集計・区分・描画

**Files:**
- Create: `lua/tally/report.lua`
- Create: `plugin/tally.lua`
- Test: `tests/report_spec.lua`

**Interfaces:**
- Consumes: `config`, `store`, `attrib`
- Produces:
  - `report.aggregate(records: table[]) -> table` — `{ sessions = n, plugins = { [name] = { sessions, key = {}, cmd = {}, key_total, cmd_total, first, last } } }`。`$session` はロスターに含めず `sessions` に集約する
  - `report.session_only(plugin: string, idx: table) -> boolean` — 押下回数を計測できない構成か
  - `report.classify(agg: table, roster: string[], idx: table) -> table` — `{ unloaded = {}, low = {}, high = {}, passive = {}, session_only = {} }`。各要素は `{ name, sessions, key_total, cmd_total, last }`
  - `report.render(agg: table, groups: table) -> string[]`
  - `report.show()` — スクラッチバッファに描画する

- [ ] **Step 1: 失敗テストを書く**

`tests/report_spec.lua`:

```lua
local report = require("tally.report")
local config = require("tally.config")

describe("report.aggregate", function()
  local records = {
    { t = 100, p = "$session", load = 1 },
    { t = 200, p = "$session", load = 1 },
    { t = 100, p = "flash.nvim", load = 1, key = { gs = 3 } },
    { t = 200, p = "flash.nvim", load = 1, key = { gs = 2, gS = 1 } },
    { t = 150, p = "telescope.nvim", load = 1, cmd = { Telescope = 4 } },
  }

  it("counts total sessions from the $session entries", function()
    assert.equals(2, report.aggregate(records).sessions)
  end)

  it("excludes $session from the plugin table", function()
    assert.is_nil(report.aggregate(records).plugins["$session"])
  end)

  it("sums counts across records", function()
    local p = report.aggregate(records).plugins["flash.nvim"]
    assert.equals(2, p.sessions)
    assert.equals(5, p.key.gs)
    assert.equals(6, p.key_total)
  end)

  it("tracks first and last timestamps", function()
    local p = report.aggregate(records).plugins["flash.nvim"]
    assert.equals(100, p.first)
    assert.equals(200, p.last)
  end)

  it("sums command counts", function()
    assert.equals(4, report.aggregate(records).plugins["telescope.nvim"].cmd_total)
  end)
end)

describe("report.session_only", function()
  local idx = {
    by_cmd = { Trouble = "trouble.nvim" },
    kinds = {
      ["yanky.nvim"] = { plug = 7 },
      ["flash.nvim"] = { ["function"] = 2 },
      ["telescope.nvim"] = { excmd = 6 },
      ["trouble.nvim"] = { excmd = 2 },
    },
  }

  it("is true when every key is a plug mapping and there is no command", function()
    assert.is_true(report.session_only("yanky.nvim", idx))
  end)

  it("is false when a key is a lua function", function()
    assert.is_false(report.session_only("flash.nvim", idx))
  end)

  it("is false when keys invoke ex commands", function()
    assert.is_false(report.session_only("telescope.nvim", idx))
  end)

  it("is false for a plugin with no keys at all", function()
    assert.is_false(report.session_only("nvim-cmp", idx))
  end)
end)

describe("report.classify", function()
  local idx = { by_cmd = {}, kinds = { ["yanky.nvim"] = { plug = 3 } } }
  local agg = {
    sessions = 100,
    plugins = {
      ["telescope.nvim"] = { sessions = 98, key_total = 500, cmd_total = 10, last = 900 },
      ["diffview.nvim"] = { sessions = 5, key_total = 2, cmd_total = 1, last = 500 },
      ["yanky.nvim"] = { sessions = 90, key_total = 0, cmd_total = 0, last = 900 },
      ["hlchunk.nvim"] = { sessions = 100, key_total = 0, cmd_total = 0, last = 900 },
    },
  }
  local roster = { "telescope.nvim", "diffview.nvim", "yanky.nvim", "hlchunk.nvim", "vim-mql5" }

  before_each(function()
    config.setup({ passive = { "hlchunk" } })
  end)

  local function names(list)
    return vim.tbl_map(function(x)
      return x.name
    end, list)
  end

  it("puts never-loaded plugins in unloaded even if absent from records", function()
    assert.same({ "vim-mql5" }, names(report.classify(agg, roster, idx).unloaded))
  end)

  it("puts plugins under 10 percent of sessions in low", function()
    assert.same({ "diffview.nvim" }, names(report.classify(agg, roster, idx).low))
  end)

  it("puts frequently used plugins in high", function()
    assert.same({ "telescope.nvim" }, names(report.classify(agg, roster, idx).high))
  end)

  it("separates session-only plugins from high", function()
    assert.same({ "yanky.nvim" }, names(report.classify(agg, roster, idx).session_only))
  end)

  it("excludes passive plugins from every usage group", function()
    local groups = report.classify(agg, roster, idx)
    assert.same({ "hlchunk.nvim" }, names(groups.passive))
    assert.is_false(vim.tbl_contains(names(groups.high), "hlchunk.nvim"))
  end)
end)

describe("report.render", function()
  it("produces lines including a header and every group heading", function()
    local agg = { sessions = 10, plugins = {} }
    local groups = { unloaded = {}, low = {}, high = {}, passive = {}, session_only = {} }
    local lines = report.render(agg, groups)
    assert.is_true(#lines > 0)
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("tally"))
    assert.is_truthy(text:find("10 sessions"))
  end)
end)
```

- [ ] **Step 2: 失敗を確認する**

Run: `make test`
Expected: FAIL。`module 'tally.report' not found`

- [ ] **Step 3: 実装する**

`lua/tally/report.lua`:

```lua
local attrib = require("tally.attrib")
local config = require("tally.config")
local store = require("tally.store")

local M = {}

local SESSION_KEY = "$session"
local LOW_RATIO = 0.1

function M.aggregate(records)
  local agg = { sessions = 0, plugins = {} }
  for _, rec in ipairs(records) do
    if rec.p == SESSION_KEY then
      agg.sessions = agg.sessions + (rec.load or 0)
    else
      local p = agg.plugins[rec.p]
      if not p then
        p = { sessions = 0, key = {}, cmd = {}, key_total = 0, cmd_total = 0 }
        agg.plugins[rec.p] = p
      end
      p.sessions = p.sessions + (rec.load or 0)
      for name, n in pairs(rec.key or {}) do
        p.key[name] = (p.key[name] or 0) + n
        p.key_total = p.key_total + n
      end
      for name, n in pairs(rec.cmd or {}) do
        p.cmd[name] = (p.cmd[name] or 0) + n
        p.cmd_total = p.cmd_total + n
      end
      if rec.t then
        p.first = math.min(p.first or rec.t, rec.t)
        p.last = math.max(p.last or rec.t, rec.t)
      end
    end
  end
  return agg
end

-- 押下回数を計測できない構成か。keys が <Plug> のみで、コマンドも持たない場合
function M.session_only(plugin, idx)
  local kinds = idx.kinds and idx.kinds[plugin]
  if not kinds then
    return false
  end
  if (kinds["function"] or 0) > 0 or (kinds.excmd or 0) > 0 then
    return false
  end
  if (kinds.plug or 0) == 0 then
    return false
  end
  for _, owner in pairs(idx.by_cmd or {}) do
    if owner == plugin then
      return false
    end
  end
  return true
end

function M.classify(agg, roster, idx)
  local groups = { unloaded = {}, low = {}, high = {}, passive = {}, session_only = {} }
  local threshold = math.max(1, math.floor(agg.sessions * LOW_RATIO))

  for _, name in ipairs(roster) do
    local p = agg.plugins[name] or { sessions = 0, key_total = 0, cmd_total = 0 }
    local row = {
      name = name,
      sessions = p.sessions,
      key_total = p.key_total,
      cmd_total = p.cmd_total,
      last = p.last,
    }
    if config.is_passive(name) then
      table.insert(groups.passive, row)
    elseif p.sessions == 0 then
      table.insert(groups.unloaded, row)
    elseif p.sessions < threshold then
      table.insert(groups.low, row)
    elseif M.session_only(name, idx) then
      table.insert(groups.session_only, row)
    else
      table.insert(groups.high, row)
    end
  end

  for _, list in pairs(groups) do
    table.sort(list, function(a, b)
      if a.sessions ~= b.sessions then
        return a.sessions < b.sessions
      end
      return a.name < b.name
    end)
  end
  return groups
end

local function fmt_date(t)
  return t and os.date("%Y-%m-%d", t) or "-"
end

local function append_group(lines, title, rows, note)
  if #rows == 0 then
    return
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "■ " .. title .. (note and ("  " .. note) or "")
  for _, r in ipairs(rows) do
    lines[#lines + 1] = ("  %-28s %5d sess  key %-6d cmd %-6d last %s"):format(
      r.name,
      r.sessions,
      r.key_total,
      r.cmd_total,
      fmt_date(r.last)
    )
  end
end

function M.render(agg, groups)
  local lines = { ("tally   %d sessions"):format(agg.sessions) }
  append_group(lines, "未ロード", groups.unloaded, "削除候補")
  append_group(lines, "低頻度", groups.low)
  append_group(lines, "セッション粒度のみ", groups.session_only, "<Plug> のため押下回数なし")
  append_group(lines, "常用", groups.high)
  append_group(lines, "passive", groups.passive, "判定対象外")
  return lines
end

function M.show()
  local idx = attrib.index() or { by_cmd = {}, kinds = {}, dirs = {} }
  local roster = {}
  local ok, lazy = pcall(require, "lazy")
  if ok then
    for _, p in ipairs(lazy.plugins()) do
      if p.name then
        roster[#roster + 1] = p.name
      end
    end
  end

  local agg = M.aggregate(store.read_all(config.options.store_dir))
  local lines = M.render(agg, M.classify(agg, roster, idx))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "tally"
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd.tabnew()
  vim.api.nvim_win_set_buf(0, buf)
end

return M
```

- [ ] **Step 4: `plugin/tally.lua` でコマンドを登録する**

```lua
if vim.g.loaded_tally then
  return
end
vim.g.loaded_tally = true

vim.api.nvim_create_user_command("Tally", function()
  require("tally.report").show()
end, { desc = "Show plugin usage report" })
```

- [ ] **Step 5: テストが通ることを確認する**

Run: `make test`
Expected: PASS

- [ ] **Step 6: コミット**

```bash
make fmt-check
git add lua/tally/report.lua plugin/tally.lua tests/report_spec.lua
git commit -m "feat: add usage report aggregation, classification, and :Tally"
```

---

### Task 10: ドキュメント

**Files:**
- Create: `README.md`
- Create: `doc/tally.txt`

**Interfaces:**
- Consumes: Task 2 の `config.defaults`、Task 8 の `early` / `setup`
- Produces: なし

- [ ] **Step 1: `README.md` を書く**

```markdown
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

## What gets recorded

Only plugin names, command names, and keymap left-hand sides. No file paths, no
buffer contents, no command arguments. Everything stays under `store_dir`;
nothing is sent anywhere.

## Limitations

- Keymaps whose right-hand side is `<Plug>(...)` are counted per session, not per
  press. Wrapping them would change operator-pending semantics.
- Commands defined as Vimscript strings fall back to counting typed invocations.
- Direct Lua API calls are not counted.
- lazy.nvim only.

## License

MIT
```

- [ ] **Step 2: `doc/tally.txt` を書く**

```
*tally.txt*  Record which Neovim plugins you actually use

==============================================================================
CONTENTS                                                       *tally-contents*

  1. Introduction ......................... |tally-introduction|
  2. Requirements ......................... |tally-requirements|
  3. Setup ................................ |tally-setup|
  4. Commands ............................. |tally-commands|
  5. Configuration ........................ |tally-configuration|
  6. Privacy .............................. |tally-privacy|
  7. Limitations .......................... |tally-limitations|

==============================================================================
1. INTRODUCTION                                            *tally-introduction*

tally.nvim counts plugin loads, command invocations and keymap presses across
sessions and persists them, so that pruning your plugin list can be based on
measurement rather than memory.

==============================================================================
2. REQUIREMENTS                                            *tally-requirements*

  - Neovim >= 0.10
  - lazy.nvim

==============================================================================
3. SETUP                                                          *tally-setup*

>lua
    {
      "shabaraba/tally.nvim",
      lazy = false,
      priority = 1000,
      init = function() require("tally").early() end,
      opts = {},
    }
<
                                                                *tally.early()*
tally.early()
    Installs the |vim.keymap.set| and |nvim_create_user_command()| hooks. Call
    from the lazy spec's `init` so the hooks are in place before other plugins
    load. Optional; without it, command tracking degrades to typed commands.

                                                                *tally.setup()*
tally.setup({opts})
    Merges configuration, registers autocommands and starts the flush timer.

==============================================================================
4. COMMANDS                                                    *tally-commands*

                                                                      *:Tally*
:Tally                  Open the usage report in a new tab.

==============================================================================
5. CONFIGURATION                                          *tally-configuration*

store_dir       string  Where the JSONL records live.
                        Default: stdpath("state") .. "/tally"
flush_interval  number  Seconds between flushes. Default: 300
passive         table   Lua patterns matched as substrings against plugin
                        names. Matching plugins are excluded from the usage
                        verdict. Default: {}
hook_keymap_set boolean Hook |vim.keymap.set| to catch buffer-local keymaps.
                        Default: true
track           table   { load = true, cmd = true, key = true }

==============================================================================
6. PRIVACY                                                      *tally-privacy*

Only plugin names, command names and keymap left-hand sides are written. File
paths, buffer contents and command arguments are never recorded, and nothing
leaves the machine.

==============================================================================
7. LIMITATIONS                                              *tally-limitations*

  - <Plug> keymaps are counted per session, not per press.
  - Vimscript-defined commands fall back to typed invocations only.
  - Direct Lua API calls are not counted.
  - lazy.nvim only.

vim:tw=78:ts=8:ft=help:norl:
```

- [ ] **Step 3: ヘルプタグが生成できることを確認する**

Run: `nvim --headless -c "helptags doc" -c "qa!"`
Expected: エラーなし。`doc/tags` が生成される

- [ ] **Step 4: コミット**

```bash
echo "doc/tags" >> .gitignore
git add README.md doc/tally.txt .gitignore
git commit -m "docs: add README and vim help"
```

---

### Task 11: GitHub public リポジトリの作成

**Files:**
- Create: `.github/workflows/release-please.yml`（`gh:repo-init` が生成）
- Create: `release-please-config.json`（同上）
- Create: `.release-please-manifest.json`（同上）

**Interfaces:**
- Consumes: Task 1〜10 の全成果物
- Produces: `https://github.com/shabaraba/tally.nvim`

- [ ] **Step 1: 全テストと整形を確認する**

```bash
make test && make fmt-check
```

Expected: 両方 PASS。失敗したら先に直す

- [ ] **Step 2: ユーザーに public 公開の確認を取る**

リポジトリを public で作成してよいか、この時点で明示的に確認する。公開は取り消しづらい操作であり、`docs/design/` と `docs/plan/` も一緒に公開されることを伝える。

- [ ] **Step 3: リポジトリを作成して push**

```bash
cd ~/workspace/nvim-plugins/tally.nvim
gh repo create shabaraba/tally.nvim --public \
  --description "Record which Neovim plugins you actually use" \
  --source . --remote origin --push
```

- [ ] **Step 4: release-please とブランチ保護をセットアップ**

```bash
cd ~/workspace/nvim-plugins/tally.nvim
mise run gh:repo-init -v 0.1.0 -t simple
```

`gh:repo-init` は main への直 commit を止める pre-commit hook を入れる。以降の変更はブランチを切って PR にする

- [ ] **Step 5: CI が通ることを確認する**

```bash
gh run list --limit 3
gh run watch
```

Expected: `test` と `format` の両ジョブが success

---

### Task 12: dotfiles への組み込みと実機確認

**Files:**
- Create: `/Users/shaba/dotfiles/nvim/lua/plugins/core/tally.lua`

**Interfaces:**
- Consumes: `tally.early()`, `tally.setup()`
- Produces: なし

dotfiles の `lazy.setup` には `dev = { path = "~/workspace/nvim-plugins", patterns = { "shabaraba" }, fallback = true }` があるため、`shabaraba/tally.nvim` と書けばローカルの作業ツリーが使われる。

- [ ] **Step 1: lazy spec を追加する**

`/Users/shaba/dotfiles/nvim/lua/plugins/core/tally.lua`:

```lua
return {
  "shabaraba/tally.nvim",
  lazy = false,
  priority = 1000,
  init = function()
    require("tally").early()
  end,
  opts = {
    passive = {
      "solarized%-osaka",
      "yozakura",
      "lush",
      "hlchunk",
      "nvim%-colorizer",
      "render%-markdown",
      "nvim%-web%-devicons",
      "mini%.icons",
      "lspkind",
      "plenary",
      "nui",
      "sqlite",
      "nvim%-treesitter",
      "diagflow",
      "nvim%-navic",
    },
  },
}
```

`passive` には colorscheme、表示専用、依存ライブラリのみを入れる。判定したいプラグインを入れてしまうと棚卸しができなくなる

- [ ] **Step 2: 起動してエラーが出ないことを確認する**

```bash
nvim --headless -c "lua print(vim.inspect(require('tally.config').options.flush_interval))" -c "qa!"
```

Expected: `300` が出力され、エラーが出ない

- [ ] **Step 3: 起動時間への影響を測る**

```bash
nvim --headless -c "qa!" --startuptime /tmp/tally-startup.txt && tail -3 /tmp/tally-startup.txt
```

追加前の値と比較する。10ms を超える増加があれば `early()` と `attrib.build` の遅延構築を見直す

- [ ] **Step 4: 実際の nvim で手動確認する**

通常の `nvim` を起動し、以下を順に行う。

1. `;f`（telescope find_files）を実行する → コマンド経由の計測
2. `gs`（flash jump）を押して Esc で抜ける → function keymap の計測
3. `:Tally` を実行する

Expected: レポートが開き、`$session` を除く全プラグインが列挙される。`telescope.nvim` に `cmd` のカウントが、`flash.nvim` に `key` のカウントが入っている。未ロードのプラグインが「未ロード」区分に出る

- [ ] **Step 5: 記録が永続化されていることを確認する**

```bash
cat ~/.local/state/nvim/tally/$(date +%Y-%m).jsonl
```

Expected: `$session` の行と、操作したプラグインの行が存在する。ファイルパスやバッファ内容が含まれていないことを目視で確認する

- [ ] **Step 6: 二重計上が起きていないことを確認する**

`:Telescope find_files` を cmdline から手打ちし、`:Tally` のカウントが 1 だけ増えることを確認する（コマンドフックと `CmdlineLeave` の両方で数えられていないこと）

- [ ] **Step 7: dotfiles にコミット**

```bash
cd /Users/shaba/dotfiles
git add nvim/lua/plugins/core/tally.lua
git commit -m "feat(nvim): add tally.nvim for plugin usage tracking"
```

---

## Self-Review

**1. Spec coverage**

| 設計の節 | 実装タスク |
|---|---|
| 6.1 lazy spec インデックス | Task 5 `attrib.build` |
| 6.2 LazyLoad 差分 | Task 7 `snapshot` / `diff_and_wrap` |
| 6.3 ソースパス解決 | Task 5 `plugin_of_path` / `resolve` |
| 6.4 帰属不能は破棄 | Task 3 `counter.add` が nil plugin を無視 |
| 7.1 `load` | Task 7 `attach` の `User LazyLoad` |
| 7.2 (a) コマンドフック | Task 7 `hook_user_command` |
| 7.2 (b) `CmdlineLeave` | Task 6 `extract_cmd_name` + Task 7 `attach` |
| 7.3 rhs 3分類 | Task 5 `rhs_kind` |
| 7.3 (a) 差分 keymap のラップ | Task 7 `wrap_existing` |
| 7.3 (b) `vim.keymap.set` フック | Task 7 `hook_keymap_set` |
| 8 保存 | Task 4 `store` |
| 9 レポート | Task 9 `report` |
| 10 設定 | Task 2 `config` |
| 11 起動シーケンス | Task 8 `init` |
| 12 パフォーマンス | Task 12 Step 3 で計測 |
| 13 プライバシー | Task 12 Step 5 で目視確認 |
| 15 テスト戦略 | Task 1 のハーネス + 各タスクのテスト |
| 16 リポジトリ | Task 1, 10, 11 |

**2. Placeholder scan**

「後で実装」「適切なエラー処理」といった記述なし。全コードステップに実コードを記載済み。

**3. Type consistency**

- `counter.drain()` の戻り値 `{ [plugin] = { load, cmd, key } }` は Task 8 の `store.encode(t, plugin, counts)` の `counts` と一致
- `store.read_all()` の戻り値レコード `{ t, p, load, cmd, key }` は Task 9 の `report.aggregate` の入力と一致
- `attrib.build()` の `kinds` / `by_cmd` / `dirs` は Task 7 の `diff_and_wrap` と Task 9 の `session_only` / `show` で同名参照
- `track.orig_keymap_set` は Task 7 内で定義・使用が閉じている
- `report.classify` の行オブジェクト `{ name, sessions, key_total, cmd_total, last }` は `render` の `append_group` と一致
