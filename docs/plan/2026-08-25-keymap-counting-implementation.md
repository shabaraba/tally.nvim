# キーマップ計測の拡張 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** rhs の書き方に左右されずキーマップの押下回数を数えられるようにし、lhs 単位の内訳と利用者自身のマッピングを `:TallyKeys` で提示する。

**Architecture:** 計測点のラップを「関数 rhs はコールバックを包む / 文字列 rhs は expr 化して元の文字列を返す」の2系統に整理する。ラップ済み関数を弱参照テーブルで記録して二重計上を防ぎ、`<Plug>` を lhs とするマッピングは包まず、`<Plug>` を rhs に持つマッピングは提供元プラグインへ押下時に帰属させる。`setup()` でフック以前から存在するマッピングを一掃してラップし直す。集計とストアの形式は変更しない。

**Tech Stack:** Lua / Neovim 0.10+ / lazy.nvim / plenary.busted / stylua

**Spec:** `docs/design/2026-08-25-keymap-counting-design.md`

**Branch:** `feat/keymap-counting`

## Global Constraints

- Neovim >= 0.10（`vim.uv`、`vim.json` を使う）
- lazy.nvim 必須。他のプラグインマネージャは対応しない
- コードコメントは日本語・必要最小限。README と `doc/tally.txt` は英語
- 記録してよいのはプラグイン名・コマンド名・keymap の lhs のみ。ファイルパス、cwd、バッファ内容、コマンド引数は記録しない
- 外部送信は一切行わない
- フックは「ラップできる条件を満たすときだけラップし、それ以外は引数に一切手を触れず素通しする」を厳守する
- 文字列 rhs を expr 化する際は `replace_keycodes = true` が必須。`false` では `<SNR>` を含む Vimscript の rhs が壊れる
- 整形は `stylua`。インデント2スペース
- コミットは Semantic Commit Messages（英語）
- テストは `make test`。単一ファイルを回す場合は下記

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/track_hook_spec.lua"
```

---

### Task 1: 二重ラップの防止と `<Plug>` lhs の除外

現行コードの不具合を先に潰す。プラグインがロード中に `vim.keymap.set` を呼ぶと、フックが包んだうえに `User LazyLoad` の `diff_and_wrap` が同じマッピングをもう一度包み、1回の押下が2カウントされる。これを直さないと以降のタスクのカウント検証が信用できない。

あわせて `<Plug>(...)` を lhs とするマッピングを計測対象から外す。Task 2 で文字列 rhs を包むようになると、`y` → `<Plug>(YankyYank)` の両方が包まれて二重計上になるため。

**Files:**
- Modify: `lua/tally/track.lua`
- Test: `tests/track_hook_spec.lua`

**Interfaces:**
- Produces: `track._wrapped`（弱参照テーブル。ラップ済み関数の集合）、`track.is_plug_lhs(lhs) -> boolean`、`track.mark_wrapped(fn) -> fn`

- [ ] **Step 1: 二重ラップの回帰テストを書く**

`tests/track_hook_spec.lua` の末尾に追記する。

```lua
describe("track double wrapping", function()
  local saved_set

  before_each(function()
    counter.drain()
    saved_set = vim.keymap.set
    track._hooked = false
    attrib._index = {
      by_key = { n = { ["gzd"] = "fake.nvim" } },
      by_cmd = {},
      kinds = {},
      dirs = {},
    }
  end)

  after_each(function()
    vim.keymap.set = saved_set
    track._hooked = false
    pcall(vim.keymap.del, "n", "gzd")
    attrib._index = nil
  end)

  it("counts a single press once when hook and diff both see the keymap", function()
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = false } })
    local prev = track.snapshot()
    vim.keymap.set("n", "gzd", function() end)
    track.diff_and_wrap("fake.nvim", prev)

    local entry
    for _, e in ipairs(vim.api.nvim_get_keymap("n")) do
      if e.lhs == "gzd" then
        entry = e
      end
    end
    assert.is_table(entry)
    entry.callback()

    assert.equals(1, counter.peek()["fake.nvim"].key["gzd"])
  end)
end)

describe("track.is_plug_lhs", function()
  it("detects <Plug> in any case", function()
    assert.is_true(track.is_plug_lhs("<Plug>(YankyYank)"))
    assert.is_true(track.is_plug_lhs("<plug>TallyTestA"))
  end)

  it("rejects ordinary lhs", function()
    assert.is_false(track.is_plug_lhs("gd"))
    assert.is_false(track.is_plug_lhs("<leader>ff"))
    assert.is_false(track.is_plug_lhs(nil))
  end)
end)
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/track_hook_spec.lua"`

Expected: FAIL。二重ラップのテストは `expected 1, got 2`。`is_plug_lhs` は `attempt to call a nil value`。

- [ ] **Step 3: `_wrapped` と `is_plug_lhs` を実装する**

`lua/tally/track.lua` の `M.wrapped_cmds = {}` の直後に追加する。

```lua
-- ラップ済みのコールバック。関数の同一性で判定するので lhs の衝突に強い
M._wrapped = setmetatable({}, { __mode = "k" })

function M.mark_wrapped(fn)
  M._wrapped[fn] = true
  return fn
end

function M.is_plug_lhs(lhs)
  return type(lhs) == "string" and lhs:lower():match("^<plug>") ~= nil
end
```

- [ ] **Step 4: `should_wrap_keymap` に2つの除外を足す**

`lua/tally/track.lua` の `M.should_wrap_keymap` を置き換える。

```lua
function M.should_wrap_keymap(entry)
  if type(entry.callback) ~= "function" then
    return false
  end
  if entry.expr == 1 then
    return false
  end
  if M.is_plug_lhs(entry.lhs) then
    return false
  end
  if M._wrapped[entry.callback] then
    return false
  end
  return true
end
```

- [ ] **Step 5: フックが張るラッパを記録し、`<Plug>` lhs を素通しする**

`lua/tally/track.lua` の `hook_keymap_set` を置き換える。

```lua
local function hook_keymap_set()
  local orig = vim.keymap.set
  M.orig_keymap_set = orig
  vim.keymap.set = function(mode, lhs, rhs, opts)
    local key = type(lhs) == "table" and lhs[1] or lhs
    if type(rhs) == "function" and not (opts and opts.expr) and not M.is_plug_lhs(key) then
      local plugin = M.spec_owner(mode, key) or attrib.resolve(3)
      if attrib.attributable(plugin) then
        local inner = rhs
        rhs = M.mark_wrapped(function(...)
          counter.add(plugin, "key", key)
          return inner(...)
        end)
      end
    end
    return orig(mode, lhs, rhs, opts)
  end
end
```

- [ ] **Step 6: `<Plug>` を前提にした既存テストを書き換える**

`tests/track_hook_spec.lua` の `describe("track.diff_and_wrap", ...)` 内、`it("counts a press of a newly wrapped keymap", ...)` を置き換える。`<Plug>TallyTestA` は包まれなくなったため、通常の lhs に変える。

```lua
  it("counts a press of a newly wrapped keymap", function()
    local prev = track.snapshot()
    local hits = 0
    vim.keymap.set("n", "gzt", function()
      hits = hits + 1
    end)
    track.diff_and_wrap("fake.nvim", prev)

    local entry
    for _, e in ipairs(vim.api.nvim_get_keymap("n")) do
      if e.lhs == "gzt" then
        entry = e
      end
    end
    assert.is_table(entry)
    entry.callback()

    assert.equals(1, hits)
    assert.equals(1, counter.peek()["fake.nvim"].key["gzt"])
  end)

  it("does not wrap <Plug> as an lhs", function()
    local prev = track.snapshot()
    vim.keymap.set("n", "<Plug>TallyTestA", function() end)
    track.diff_and_wrap("fake.nvim", prev)

    local entry
    for _, e in ipairs(vim.api.nvim_get_keymap("n")) do
      if e.lhs == "<Plug>TallyTestA" then
        entry = e
      end
    end
    assert.is_table(entry)
    entry.callback()

    assert.is_nil(counter.peek()["fake.nvim"])
  end)
```

同じ `describe` の `after_each` に `pcall(vim.keymap.del, "n", "gzt")` を追加する。

- [ ] **Step 7: テストを実行して通ることを確認する**

Run: `make test`
Expected: PASS。全 spec が緑。

- [ ] **Step 8: 整形してコミットする**

```bash
make fmt
git add lua/tally/track.lua tests/track_hook_spec.lua
git commit -m "fix: count a keymap press once when hook and LazyLoad diff overlap

The hook wraps a callback at set time and diff_and_wrap wraps it again
when User LazyLoad fires, so a single press was counted twice. Track
wrapped callbacks in a weak table and skip them.

Also stop wrapping <Plug> as an lhs. It is plugin-internal and counting
it alongside the user-facing lhs would double the plugin's key total."
```

---

### Task 2: 文字列 rhs と expr マッピングのラップ

`<Plug>`・`:cmd<CR>`・`y$` のような文字列 rhs を expr 化して包む。元から `expr = true` の関数マッピングも対象にする。

rhs が文字列でかつ `expr = true` のものは触らない。その rhs は「評価される Vimscript の式」であってキー列ではないため、そのまま返すと式のテキストが打鍵される。

**Files:**
- Modify: `lua/tally/track.lua`
- Test: `tests/track_hook_spec.lua`

**Interfaces:**
- Consumes: `track.mark_wrapped`、`track.is_plug_lhs`（Task 1）
- Produces: `track.make_wrapper(plugin, lhs, rhs) -> function`。`rhs` が関数ならコールバックを包んだ関数、文字列なら `rhs` をそのまま返す関数

- [ ] **Step 1: 失敗するテストを書く**

`tests/track_hook_spec.lua` の末尾に追記する。実際の押下は `nvim_feedkeys` の `"x"` フラグで同期実行する。

```lua
describe("track string rhs wrapping", function()
  local saved_set

  before_each(function()
    counter.drain()
    saved_set = vim.keymap.set
    track._hooked = false
    attrib._index = { by_key = {}, by_cmd = {}, kinds = {}, dirs = {} }
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello world" })
  end)

  after_each(function()
    vim.keymap.set = saved_set
    track._hooked = false
    for _, lhs in ipairs({ "gzy", "gzc", "gzn", "$" }) do
      pcall(vim.keymap.del, "n", lhs)
    end
    pcall(vim.keymap.del, "n", "<Plug>(TallyProbe)")
    attrib._index = nil
  end)

  it("counts a press of a <Plug> mapping and still runs it", function()
    attrib._index.by_key = { n = { gzy = "fake.nvim" } }
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = false } })

    track.orig_keymap_set("n", "<Plug>(TallyProbe)", "yy", { noremap = true })
    vim.keymap.set("n", "gzy", "<Plug>(TallyProbe)", { remap = true })

    vim.fn.setreg("z", "")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode('"zgzy'), "x", false)

    assert.equals(1, counter.peek()["fake.nvim"].key["gzy"])
    assert.equals("hello world\n", vim.fn.getreg("z"))
  end)

  it("preserves noremap for a plain string rhs", function()
    attrib._index.by_key = { n = { gzn = "fake.nvim" } }
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = false } })

    track.orig_keymap_set("n", "$", "0", { remap = false })
    vim.keymap.set("n", "gzn", "y$", { noremap = true })

    vim.fn.setreg('"', "")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("gzn"), "x", false)

    assert.equals(1, counter.peek()["fake.nvim"].key["gzn"])
    -- $ が 0 にリマップされていれば空になる。noremap が保たれていれば行末まで入る
    assert.equals("hello world", vim.fn.getreg('"'))
  end)

  it("counts a press of an expr callback mapping", function()
    attrib._index.by_key = { n = { gzc = "fake.nvim" } }
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = false } })

    vim.keymap.set("n", "gzc", function()
      return "yy"
    end, { expr = true })

    vim.fn.setreg('"', "")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("gzc"), "x", false)

    assert.equals(1, counter.peek()["fake.nvim"].key["gzc"])
    assert.equals("hello world\n", vim.fn.getreg('"'))
  end)

  it("passes string rhs with expr through untouched", function()
    local seen
    vim.keymap.set = function(_, _, rhs)
      seen = rhs
    end
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = false } })
    vim.keymap.set("n", "gzc", "line('.') > 1 ? 'k' : 'j'", { expr = true })
    assert.equals("line('.') > 1 ? 'k' : 'j'", seen)
  end)
end)
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/track_hook_spec.lua"`
Expected: FAIL。文字列 rhs はまだ包まれないので `counter.peek()["fake.nvim"]` が nil。

- [ ] **Step 3: `make_wrapper` を実装する**

`lua/tally/track.lua` の `M.is_plug_lhs` の直後に追加する。

```lua
-- 押下を数えるラッパ。文字列 rhs は expr 化して元の文字列をそのまま返す
function M.make_wrapper(plugin, lhs, rhs)
  if type(rhs) == "function" then
    return M.mark_wrapped(function(...)
      counter.add(plugin, "key", lhs)
      return rhs(...)
    end)
  end
  return M.mark_wrapped(function()
    counter.add(plugin, "key", lhs)
    return rhs
  end)
end
```

- [ ] **Step 4: フックを文字列 rhs に対応させる**

`lua/tally/track.lua` の `hook_keymap_set` を置き換える。

```lua
local function hook_keymap_set()
  local orig = vim.keymap.set
  M.orig_keymap_set = orig
  vim.keymap.set = function(mode, lhs, rhs, opts)
    local key = type(lhs) == "table" and lhs[1] or lhs
    local is_expr = opts and opts.expr
    local wrappable = (type(rhs) == "function")
      or (type(rhs) == "string" and rhs ~= "" and not is_expr)

    if wrappable and not M.is_plug_lhs(key) then
      local plugin = M.spec_owner(mode, key) or attrib.resolve(3)
      if attrib.attributable(plugin) then
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
```

文字列 rhs を expr 化するとき `remap` / `noremap` には触らない。`vim.keymap.set` の既定は noremap であり、呼び出し側が `remap = true` を渡していればそれがそのまま残るため、`<Plug>` は展開され `y$` は展開されない。

- [ ] **Step 5: `wrap_existing` を文字列 rhs に対応させる**

`lua/tally/track.lua` の `wrap_existing` を置き換える。

```lua
local function wrap_existing(mode, entry, plugin)
  if M.is_plug_lhs(entry.lhs) then
    return
  end
  if entry.callback and M._wrapped[entry.callback] then
    return
  end

  local lhs = entry.lhs
  local rhs, expr
  if type(entry.callback) == "function" then
    rhs, expr = entry.callback, entry.expr == 1
  elseif type(entry.rhs) == "string" and entry.rhs ~= "" and entry.expr ~= 1 then
    rhs, expr = entry.rhs, true
  else
    return
  end

  plugin = M.spec_owner(mode, lhs) or plugin
  if not attrib.attributable(plugin) then
    return
  end

  -- フック済みの vim.keymap.set を呼ぶと二重ラップになるため元の関数を使う
  local set = M.orig_keymap_set or vim.keymap.set
  set(mode, lhs, M.make_wrapper(plugin, lhs, rhs), {
    expr = expr,
    replace_keycodes = type(rhs) == "string" or nil,
    remap = entry.noremap ~= 1,
    silent = entry.silent == 1,
    nowait = entry.nowait == 1,
    desc = entry.desc,
  })
end
```

`M.should_wrap_keymap` はこの関数の内側に取り込まれた。関数は公開 API としてテストから参照されているので残す。

- [ ] **Step 6: テストを実行して通ることを確認する**

Run: `make test`
Expected: PASS。

- [ ] **Step 7: 整形してコミットする**

```bash
make fmt
git add lua/tally/track.lua tests/track_hook_spec.lua
git commit -m "feat: count presses of string-rhs and expr keymaps

Wrap a string rhs as an expr mapping that returns the original string,
so <Plug>, :cmd<CR> and plain key sequences all become countable. The
caller's remap flag is left untouched, which keeps <Plug> expanding and
noremap mappings unexpanded.

String rhs with expr set is left alone: it is an expression to evaluate,
not a key sequence."
```

---

### Task 3: `<Plug>` を rhs に持つマッピングの帰属

`y` → `<Plug>(YankyYank)` を利用者が自分の設定で書いた場合、スタック解決は `$user` を返す。押下は yanky.nvim に帰属させたい。`<Plug>` の提供元を索引に持ち、押下時に引く。

**Files:**
- Modify: `lua/tally/attrib.lua`
- Modify: `lua/tally/track.lua`
- Test: `tests/attrib_spec.lua`
- Test: `tests/track_hook_spec.lua`

**Interfaces:**
- Consumes: `track.make_wrapper`（Task 2）
- Produces: `attrib.index().by_plug`（`"<Plug>(X)" -> plugin name`）、`attrib.plug_owner(rhs) -> string|nil`

- [ ] **Step 1: 失敗するテストを書く**

`tests/attrib_spec.lua` の末尾に追記する。

```lua
describe("attrib.plug_owner", function()
  after_each(function()
    attrib._index = nil
  end)

  it("resolves a <Plug> rhs declared in a lazy spec", function()
    local idx = attrib.build({
      {
        name = "yanky.nvim",
        dir = "/data/lazy/yanky.nvim",
        keys = { { "y", "<Plug>(YankyYank)", mode = { "n", "x" } } },
      },
    })
    assert.equals("yanky.nvim", idx.by_plug["<Plug>(YankyYank)"])
    assert.equals("yanky.nvim", attrib.plug_owner("<Plug>(YankyYank)"))
  end)

  it("returns nil for an unknown <Plug>", function()
    attrib.build({})
    assert.is_nil(attrib.plug_owner("<Plug>(Unknown)"))
  end)

  it("returns nil when no index exists", function()
    attrib._index = nil
    assert.is_nil(attrib.plug_owner("<Plug>(Whatever)"))
  end)
end)
```

`tests/track_hook_spec.lua` の末尾に追記する。

```lua
describe("track <Plug> attribution", function()
  local saved_set

  before_each(function()
    counter.drain()
    saved_set = vim.keymap.set
    track._hooked = false
    attrib._index = { by_key = {}, by_cmd = {}, by_plug = {}, kinds = {}, dirs = {} }
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello world" })
  end)

  after_each(function()
    vim.keymap.set = saved_set
    track._hooked = false
    pcall(vim.keymap.del, "n", "gzp")
    pcall(vim.keymap.del, "n", "<Plug>(TallyLate)")
    attrib._index = nil
  end)

  it("credits the plugin that provides the <Plug>, not the caller", function()
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = false } })
    track.orig_keymap_set("n", "<Plug>(TallyLate)", "yy", { noremap = true })
    vim.keymap.set("n", "gzp", "<Plug>(TallyLate)", { remap = true })

    -- 索引はマッピングを張ったあとに埋まる。遅延ロードを模す
    attrib._index.by_plug["<Plug>(TallyLate)"] = "late.nvim"

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("gzp"), "x", false)

    assert.equals(1, counter.peek()["late.nvim"].key["gzp"])
  end)
end)
```

`tests/track_hook_spec.lua` 冒頭の `fake_index()` に `by_plug = {}` を足す。

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `make test`
Expected: FAIL。`attrib.plug_owner` が nil、`by_plug` が未定義。

- [ ] **Step 3: `parse_keys` に rhs を持たせ、`by_plug` を作る**

`lua/tally/attrib.lua` の `M.parse_keys` のループ末尾を置き換える。

```lua
      local modes = type(mode) == "table" and mode or { mode }
      for _, m in ipairs(modes) do
        out[#out + 1] = { lhs = lhs, mode = m, rhs = rhs, rhs_kind = M.rhs_kind(rhs) }
      end
```

`M.build` の索引初期化と `keys` のループを置き換える。

```lua
  local idx = { by_key = {}, by_cmd = {}, by_plug = {}, dirs = {}, kinds = {} }
```

```lua
      for _, k in ipairs(M.parse_keys(p.keys)) do
        idx.by_key[k.mode] = idx.by_key[k.mode] or {}
        idx.by_key[k.mode][k.lhs] = p.name
        if type(k.rhs) == "string" and k.rhs:lower():match("^<plug>") then
          idx.by_plug[k.rhs] = p.name
        end
        idx.kinds[p.name] = idx.kinds[p.name] or {}
        idx.kinds[p.name][k.rhs_kind] = (idx.kinds[p.name][k.rhs_kind] or 0) + 1
      end
```

`M.index()` の直後に追加する。

```lua
function M.plug_owner(rhs)
  local idx = M._index
  if not idx or not idx.by_plug or type(rhs) ~= "string" then
    return nil
  end
  return idx.by_plug[rhs]
end
```

- [ ] **Step 4: `diff_and_wrap` が `<Plug>` の提供元を記録する**

`lua/tally/track.lua` の `M.diff_and_wrap` のモードループを置き換える。

```lua
  for _, mode in ipairs(MODES) do
    for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
      if not prev.keys[mode][entry.lhs] then
        if M.is_plug_lhs(entry.lhs) then
          idx = idx or {}
          idx.by_plug = idx.by_plug or {}
          if not idx.by_plug[entry.lhs] then
            idx.by_plug[entry.lhs] = plugin
          end
        else
          wrap_existing(mode, entry, plugin)
        end
      end
    end
  end
```

- [ ] **Step 5: ラッパが押下時に提供元を引く**

`lua/tally/track.lua` の `M.make_wrapper` を置き換える。

```lua
-- 押下を数えるラッパ。文字列 rhs は expr 化して元の文字列をそのまま返す
function M.make_wrapper(plugin, lhs, rhs)
  if type(rhs) == "function" then
    return M.mark_wrapped(function(...)
      counter.add(plugin, "key", lhs)
      return rhs(...)
    end)
  end
  -- <Plug> の提供元は遅延ロードで後から判明するので押下時に引く
  local plug = rhs:lower():match("^<plug>") and rhs or nil
  return M.mark_wrapped(function()
    local owner = plug and attrib.plug_owner(plug) or nil
    counter.add(attrib.attributable(owner) and owner or plugin, "key", lhs)
    return rhs
  end)
end
```

- [ ] **Step 6: テストを実行して通ることを確認する**

Run: `make test`
Expected: PASS。

- [ ] **Step 7: 整形してコミットする**

```bash
make fmt
git add lua/tally/attrib.lua lua/tally/track.lua tests/attrib_spec.lua tests/track_hook_spec.lua
git commit -m "feat: credit <Plug> presses to the plugin that provides them

A <Plug> mapping written in the user's own config resolved to the caller,
so the plugin behind it stayed at zero presses. Index <Plug> providers
from lazy specs and the LazyLoad diff, and resolve the owner at press
time since a lazily loaded provider is not known when the mapping is set."
```

---

### Task 4: 起動時の一掃ラップ

`tally.early()` より前に張られたマッピング（Neovim 標準の `grn` `gra` `grr` など）は包まれず、押しても数が増えない。`:TallyKeys` で「未使用」と誤表示されるので、`setup()` で一度に包み直す。

**Files:**
- Modify: `lua/tally/track.lua`
- Modify: `lua/tally/init.lua`
- Test: `tests/track_spec.lua`

**Interfaces:**
- Consumes: `wrap_existing`（Task 2）
- Produces: `track.sweep(opts)`。全モードの現存マッピングをラップし直す。帰属が解決できないものは `"$user"` に寄せる

- [ ] **Step 1: 失敗するテストを書く**

`tests/track_spec.lua` の末尾に追記する。冒頭の require に `counter` と `attrib` が無ければ足す。

```lua
describe("track.sweep", function()
  before_each(function()
    require("tally.counter").drain()
    require("tally.attrib")._index =
      { by_key = { n = { gzs = "fake.nvim" } }, by_cmd = {}, by_plug = {}, kinds = {}, dirs = {} }
    track.orig_keymap_set = nil
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "sweep me" })
  end)

  after_each(function()
    pcall(vim.keymap.del, "n", "gzs")
    pcall(vim.keymap.del, "n", "<Plug>(TallySweep)")
    require("tally.attrib")._index = nil
  end)

  it("wraps a keymap that existed before the hook", function()
    vim.keymap.set("n", "gzs", "yy", { noremap = true })
    track.sweep({ track = { key = true } })

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("gzs"), "x", false)

    assert.equals(1, require("tally.counter").peek()["fake.nvim"].key["gzs"])
  end)

  it("leaves <Plug> lhs alone", function()
    vim.keymap.set("n", "<Plug>(TallySweep)", "yy", { noremap = true })
    track.sweep({ track = { key = true } })

    local entry
    for _, e in ipairs(vim.api.nvim_get_keymap("n")) do
      if e.lhs == "<Plug>(TallySweep)" then
        entry = e
      end
    end
    assert.is_table(entry)
    assert.is_nil(entry.callback)
  end)

  it("does nothing when key tracking is off", function()
    vim.keymap.set("n", "gzs", "yy", { noremap = true })
    track.sweep({ track = { key = false } })

    local entry
    for _, e in ipairs(vim.api.nvim_get_keymap("n")) do
      if e.lhs == "gzs" then
        entry = e
      end
    end
    assert.is_nil(entry.callback)
  end)
end)
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/track_spec.lua"`
Expected: FAIL。`attempt to call a nil value (field 'sweep')`。

- [ ] **Step 3: `sweep` を実装する**

`lua/tally/track.lua` の `M.diff_and_wrap` の直後に追加する。

```lua
-- early() より前から存在するマッピングを包み直す。
-- Neovim 標準のマッピングや、フック設置前に読まれた設定が対象
function M.sweep(opts)
  if not opts.track.key then
    return
  end
  for _, mode in ipairs(MODES) do
    for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
      wrap_existing(mode, entry, "$user")
    end
  end
end
```

- [ ] **Step 4: `setup` から呼ぶ**

`lua/tally/init.lua` の `M.setup` 内、`track.attach(cfg)` の直後に1行足す。

```lua
  track.hook(cfg)
  track.attach(cfg)
  track.sweep(cfg)
```

- [ ] **Step 5: テストを実行して通ることを確認する**

Run: `make test`
Expected: PASS。

- [ ] **Step 6: 起動コストを実測する**

Run:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua local t=require('tally.track') require('tally.attrib')._index={by_key={},by_cmd={},by_plug={},kinds={},dirs={}} for i=1,300 do vim.keymap.set('n','<leader>z'..i,':echo '..i..'<CR>') end local n=0 for _,m in ipairs({'n','v','x','s','o','i','c','t'}) do n=n+#vim.api.nvim_get_keymap(m) end local s=vim.uv.hrtime() t.sweep({track={key=true}}) print(string.format('%d mappings, %.2f ms',n,(vim.uv.hrtime()-s)/1e6))" \
  -c "qa!"
```

Expected: 3桁ms に達しないこと。設計時の実測は609件で6.60ms。100ms を超える場合は `M.sweep` の呼び出しを `vim.schedule(function() track.sweep(cfg) end)` に変え、遅延中の押下を取りこぼす旨を `doc/tally.txt` の Limitations に追記する。

- [ ] **Step 7: 整形してコミットする**

```bash
make fmt
git add lua/tally/track.lua lua/tally/init.lua tests/track_spec.lua
git commit -m "feat: wrap keymaps that predate the hook

Neovim's own mappings and anything set before tally.early() were never
wrapped, so they stayed at zero presses and would show up as unused.
Sweep every mode once at setup and wrap what is left."
```

---

### Task 5: `$user` 帰属

利用者自身が定義したキーマップを `$user` として帰属させる。

**Files:**
- Modify: `lua/tally/attrib.lua`
- Test: `tests/attrib_spec.lua`

**Interfaces:**
- Produces: `attrib.resolve` が、プラグインに該当せず `stdpath("config")` 配下から呼ばれた場合に `"$user"` を返す

- [ ] **Step 1: 失敗するテストを書く**

`tests/attrib_spec.lua` の末尾に追記する。`debug.getinfo` を差し替えられないので、パス判定の関数を切り出して直接テストする。

```lua
describe("attrib.user_path", function()
  it("recognises a file under the config dir", function()
    local cfg = vim.fn.stdpath("config")
    assert.is_true(attrib.user_path("@" .. cfg .. "/lua/keymaps.lua"))
    assert.is_true(attrib.user_path(cfg .. "/init.lua"))
  end)

  it("rejects anything outside it", function()
    assert.is_false(attrib.user_path("@/data/lazy/telescope.nvim/lua/x.lua"))
    assert.is_false(attrib.user_path("@[string \"luaeval\"]"))
    assert.is_false(attrib.user_path(nil))
  end)
end)

describe("attrib.resolve with user config", function()
  after_each(function()
    attrib._index = nil
  end)

  it("falls back to $user for a caller in the config dir", function()
    attrib._index = { by_key = {}, by_cmd = {}, by_plug = {}, kinds = {}, dirs = {} }
    local cfg = vim.fn.stdpath("config")
    assert.equals("$user", attrib.resolve_from({ "@" .. cfg .. "/lua/keymaps.lua" }))
  end)

  it("prefers a plugin over $user", function()
    attrib._index = {
      by_key = {},
      by_cmd = {},
      by_plug = {},
      kinds = {},
      dirs = { { dir = "/data/lazy/flash.nvim", name = "flash.nvim" } },
    }
    local cfg = vim.fn.stdpath("config")
    assert.equals(
      "flash.nvim",
      attrib.resolve_from({ "@" .. cfg .. "/lua/keymaps.lua", "@/data/lazy/flash.nvim/lua/x.lua" })
    )
  end)

  it("returns nil when nothing matches", function()
    attrib._index = { by_key = {}, by_cmd = {}, by_plug = {}, kinds = {}, dirs = {} }
    assert.is_nil(attrib.resolve_from({ "@/tmp/somewhere.lua" }))
  end)
end)
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/attrib_spec.lua"`
Expected: FAIL。`attrib.user_path` と `attrib.resolve_from` が nil。

- [ ] **Step 3: `user_path` と `resolve_from` を実装する**

`lua/tally/attrib.lua` の `M.plugin_of_path` の直後に追加する。

```lua
local USER = "$user"

function M.user_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  if path:sub(1, 1) == "@" then
    path = path:sub(2)
  end
  local cfg = vim.fn.stdpath("config")
  return path:sub(1, #cfg + 1) == cfg .. "/"
end

-- 呼び出し元パスの列から帰属先を決める。resolve から切り出してテスト可能にした
function M.resolve_from(paths)
  local idx = M.index()
  if not idx then
    return nil
  end
  local fallback, user = nil, nil
  for _, path in ipairs(paths) do
    local name = M.plugin_of_path(path, idx.dirs)
    if M.attributable(name) then
      if not UTILITY[name] then
        return name
      end
      fallback = fallback or name
    elseif not user and M.user_path(path) then
      user = USER
    end
  end
  return fallback or user
end
```

- [ ] **Step 4: `resolve` を `resolve_from` の薄い皮にする**

`lua/tally/attrib.lua` の `M.resolve` を置き換える。

```lua
function M.resolve(level)
  local paths = {}
  for i = level or 2, 30 do
    local info = debug.getinfo(i, "S")
    if not info then
      break
    end
    paths[#paths + 1] = info.source
  end
  return M.resolve_from(paths)
end
```

- [ ] **Step 5: テストを実行して通ることを確認する**

Run: `make test`
Expected: PASS。

- [ ] **Step 6: 整形してコミットする**

```bash
make fmt
git add lua/tally/attrib.lua tests/attrib_spec.lua
git commit -m "feat: attribute keymaps from the user's config to \$user

Split the stack walk from the attribution decision so the path rules can
be tested directly, and fall back to \$user when the caller lives under
stdpath('config')."
```

---

### Task 6: 「セッション粒度のみ」と `rhs_kind` の削除

`<Plug>` が押下単位で数えられるようになったので、この分類は条件を満たすプラグインが原理上いなくなる。`rhs_kind` と `idx.kinds` は `session_only` からしか使われていない。

**Files:**
- Modify: `lua/tally/report.lua`
- Modify: `lua/tally/attrib.lua`
- Test: `tests/report_spec.lua`
- Test: `tests/attrib_spec.lua`

**Interfaces:**
- Produces: `report.classify(agg, roster, idx)` のシグネチャは変えない。返す `groups` から `session_only` が消える

- [ ] **Step 1: テストを先に削る**

`tests/report_spec.lua` から次を削除する。

- `describe("report.session_only", ...)` ブロック全体
- `assert.same({ "yanky.nvim" }, names(report.classify(agg, roster, idx).session_only))` を含む `it`
- `local groups = { unloaded = {}, low = {}, high = {}, passive = {}, session_only = {} }` の `session_only = {}` を削り、その `it` が `session_only` に触れていれば該当行も削る

`tests/attrib_spec.lua` から次を削除する。

- `describe("attrib.rhs_kind", ...)` ブロック全体
- `assert.equals("function", got[1].rhs_kind)` / `assert.equals("plug", got[1].rhs_kind)` / `assert.equals("excmd", got[1].rhs_kind)` の各行
- `assert.equals(1, idx.kinds["telescope.nvim"]["excmd"])` と `assert.equals(1, idx.kinds["flash.nvim"]["function"])` の2行

- [ ] **Step 2: テストを実行して緑であることを確認する**

Run: `make test`
Expected: PASS。削除しただけなので実装はまだ残っている。

- [ ] **Step 3: `report.lua` から削除する**

`lua/tally/report.lua` から次を削除する。

- `-- 押下回数を計測できない構成か。...` のコメントと `function M.session_only(plugin, idx) ... end` 全体
- `M.classify` の `local groups = ...` から `session_only = {}` を削る
- `M.classify` の `elseif M.session_only(name, idx) then` と `table.insert(groups.session_only, row)` の2行を削る（直後の `else` はそのまま残す）
- `M.render` の `append_group(lines, "セッション粒度のみ", groups.session_only, "<Plug> のため押下回数なし")` の呼び出し全体

- [ ] **Step 4: `attrib.lua` から削除する**

`lua/tally/attrib.lua` から次を削除する。

- `function M.rhs_kind(rhs) ... end` 全体
- `M.parse_keys` が返すテーブルの `rhs_kind = M.rhs_kind(rhs)` フィールド（`rhs = rhs` は Task 3 で追加したので残す）
- `M.build` の `idx` 初期化から `kinds = {}` を削る
- `M.build` の `idx.kinds[p.name] = idx.kinds[p.name] or {}` と `idx.kinds[p.name][k.rhs_kind] = ...` の2行

テストのフェイク索引が `kinds = {}` を渡していても害はないので、そのままでよい。

- [ ] **Step 5: テストを実行して通ることを確認する**

Run: `make test`
Expected: PASS。

- [ ] **Step 6: 整形してコミットする**

```bash
make fmt
git add lua/tally/report.lua lua/tally/attrib.lua tests/report_spec.lua tests/attrib_spec.lua
git commit -m "refactor: drop the session-only classification

<Plug> mappings are counted per press now, so no plugin can land in this
group. Its only consumers were rhs_kind and idx.kinds, which go with it."
```

---

### Task 7: `:TallyKeys`

lhs 単位の使用頻度を出す。未使用マッピングを含める。

**Files:**
- Create: `lua/tally/keys.lua`
- Create: `tests/keys_spec.lua`
- Modify: `plugin/tally.lua`

**Interfaces:**
- Consumes: `report.aggregate(records) -> agg`（既存。`agg.sessions` と `agg.plugins[name].key[lhs]`）
- Produces: `keys.collect(agg) -> table<lhs, {lhs, count, owner}>`、`keys.existing() -> table<lhs, boolean>`、`keys.classify(rows, existing, sessions) -> {unused, low, high}`、`keys.render(sessions, groups) -> string[]`、`keys.show()`

- [ ] **Step 1: 失敗するテストを書く**

`tests/keys_spec.lua` を新規作成する。

```lua
local keys = require("tally.keys")

describe("keys.collect", function()
  it("flattens per-plugin key counts into lhs rows", function()
    local agg = {
      sessions = 100,
      plugins = {
        ["telescope.nvim"] = { key = { ["<leader>ff"] = 12 } },
        ["$user"] = { key = { ["jj"] = 300, ["<leader>ff"] = 3 } },
      },
    }
    local rows = keys.collect(agg)
    assert.equals(300, rows["jj"].count)
    assert.equals("$user", rows["jj"].owner)
    -- 同じ lhs が両方に記録されていたら回数の多い側を持ち主とする
    assert.equals(15, rows["<leader>ff"].count)
    assert.equals("telescope.nvim", rows["<leader>ff"].owner)
  end)

  it("returns an empty table for an empty aggregate", function()
    assert.same({}, keys.collect({ sessions = 0, plugins = {} }))
  end)
end)

describe("keys.classify", function()
  it("splits by press count against the session threshold", function()
    local rows = {
      ["jj"] = { lhs = "jj", count = 300, owner = "$user" },
      ["<leader>gs"] = { lhs = "<leader>gs", count = 3, owner = "$user" },
    }
    local existing = { ["jj"] = true, ["<leader>gs"] = true, ["<leader>xx"] = true }
    local groups = keys.classify(rows, existing, 100)

    assert.same({ "jj" }, vim.tbl_map(function(r)
      return r.lhs
    end, groups.high))
    assert.same({ "<leader>gs" }, vim.tbl_map(function(r)
      return r.lhs
    end, groups.low))
    assert.same({ "<leader>xx" }, vim.tbl_map(function(r)
      return r.lhs
    end, groups.unused))
  end)

  it("uses a threshold of at least 1", function()
    local groups = keys.classify({ ["gd"] = { lhs = "gd", count = 1, owner = "x" } }, { gd = true }, 0)
    assert.equals(1, #groups.high)
  end)

  it("drops rows whose mapping no longer exists", function()
    local rows = { ["gone"] = { lhs = "gone", count = 50, owner = "$user" } }
    local groups = keys.classify(rows, {}, 100)
    assert.equals(0, #groups.high)
    assert.equals(0, #groups.low)
    assert.equals(0, #groups.unused)
  end)

  it("sorts by count desc then lhs asc", function()
    local rows = {
      ["b"] = { lhs = "b", count = 5, owner = "x" },
      ["a"] = { lhs = "a", count = 5, owner = "x" },
      ["c"] = { lhs = "c", count = 9, owner = "x" },
    }
    local groups = keys.classify(rows, { a = true, b = true, c = true }, 10)
    assert.same({ "c", "a", "b" }, vim.tbl_map(function(r)
      return r.lhs
    end, groups.high))
  end)
end)

describe("keys.render", function()
  it("prints a header and only non-empty groups", function()
    local groups = {
      unused = { { lhs = "<leader>xx", count = 0, owner = "$user" } },
      low = {},
      high = { { lhs = "jj", count = 300, owner = "$user" } },
    }
    local lines = keys.render(142, groups)
    assert.equals("tally keys   142 sessions", lines[1])

    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("未使用", 1, true))
    assert.is_truthy(text:find("<leader>xx", 1, true))
    assert.is_truthy(text:find("jj", 1, true))
    assert.is_nil(text:find("低頻度", 1, true))
  end)
end)

describe("keys.existing", function()
  after_each(function()
    pcall(vim.keymap.del, "n", "gzk")
    pcall(vim.keymap.del, "n", "<Plug>(TallyKeysProbe)")
  end)

  it("lists real mappings and skips <Plug>", function()
    vim.keymap.set("n", "gzk", "yy")
    vim.keymap.set("n", "<Plug>(TallyKeysProbe)", "yy")
    local existing = keys.existing()
    assert.is_true(existing["gzk"])
    assert.is_nil(existing["<Plug>(TallyKeysProbe)"])
  end)
end)
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/keys_spec.lua"`
Expected: FAIL。`module 'tally.keys' not found`。

- [ ] **Step 3: `keys.lua` を実装する**

`lua/tally/keys.lua` を新規作成する。

```lua
local config = require("tally.config")
local report = require("tally.report")
local store = require("tally.store")

local M = {}

local LOW_RATIO = 0.1
local MODES = { "n", "v", "x", "s", "o", "i", "c", "t" }

function M.collect(agg)
  local rows = {}
  for plugin, p in pairs(agg.plugins or {}) do
    for lhs, n in pairs(p.key or {}) do
      local row = rows[lhs]
      if not row then
        row = { lhs = lhs, count = 0, owner = plugin, top = 0 }
        rows[lhs] = row
      end
      row.count = row.count + n
      -- 同じ lhs が複数プラグインに帰属した履歴がある場合は回数の多い側を採る
      if n > row.top then
        row.top, row.owner = n, plugin
      end
    end
  end
  for _, row in pairs(rows) do
    row.top = nil
  end
  return rows
end

function M.existing()
  local out = {}
  for _, mode in ipairs(MODES) do
    for _, entry in ipairs(vim.api.nvim_get_keymap(mode)) do
      if not entry.lhs:lower():match("^<plug>") then
        out[entry.lhs] = true
      end
    end
  end
  return out
end

function M.classify(rows, existing, sessions)
  local groups = { unused = {}, low = {}, high = {} }
  local threshold = math.max(1, math.floor(sessions * LOW_RATIO))

  for lhs in pairs(existing) do
    local row = rows[lhs] or { lhs = lhs, count = 0, owner = "-" }
    if row.count == 0 then
      table.insert(groups.unused, row)
    elseif row.count < threshold then
      table.insert(groups.low, row)
    else
      table.insert(groups.high, row)
    end
  end

  for _, list in pairs(groups) do
    table.sort(list, function(a, b)
      if a.count ~= b.count then
        return a.count > b.count
      end
      return a.lhs < b.lhs
    end)
  end
  return groups
end

local function append_group(lines, title, rows, note)
  if #rows == 0 then
    return
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "■ " .. title .. (note and ("  " .. note) or "")
  for _, r in ipairs(rows) do
    lines[#lines + 1] = ("  %6d  %-24s %s"):format(r.count, r.lhs, r.owner)
  end
end

function M.render(sessions, groups)
  local lines = { ("tally keys   %d sessions"):format(sessions) }
  append_group(lines, "未使用", groups.unused, "見直し候補")
  append_group(lines, "低頻度", groups.low)
  append_group(lines, "常用", groups.high)
  return lines
end

function M.show()
  local agg = report.aggregate(store.read_all(config.options.store_dir))
  local groups = M.classify(M.collect(agg), M.existing(), agg.sessions)
  local lines = M.render(agg.sessions, groups)

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

- [ ] **Step 4: テストを実行して通ることを確認する**

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/keys_spec.lua"`
Expected: PASS。

- [ ] **Step 5: `:TallyKeys` を登録する**

`plugin/tally.lua` の末尾に追加する。

```lua
vim.api.nvim_create_user_command("TallyKeys", function()
  require("tally.keys").show()
end, { desc = "Show keymap usage report" })
```

- [ ] **Step 6: 全テストを実行する**

Run: `make test`
Expected: PASS。

- [ ] **Step 7: 整形してコミットする**

```bash
make fmt
git add lua/tally/keys.lua tests/keys_spec.lua plugin/tally.lua
git commit -m "feat: add :TallyKeys for per-lhs usage

Cross the stored per-lhs counts with the mappings that currently exist,
so a mapping you defined and never press shows up as unused. Kept in its
own module since :Tally answers a different question."
```

---

### Task 8: ドキュメント

**Files:**
- Modify: `README.md`
- Modify: `doc/tally.txt`

**Interfaces:**
- Consumes: Task 1〜7 の全挙動

- [ ] **Step 1: README の "Usage" に `:TallyKeys` を足す**

`README.md` の `## Usage` 節、`:Tally` のサンプル出力の直後に追加する。

```markdown
`:TallyKeys` breaks the same data down per keymap, and crosses it with the
mappings that currently exist so a mapping you defined and never press shows
up as unused.

```
tally keys   142 sessions

■ 未使用  見直し候補
       0  <leader>xx               $user
       0  gr                       refactoring.nvim
■ 低頻度
       3  <leader>gs               $user
■ 常用
    1204  jj                       $user
     892  <leader>ff               telescope.nvim
```
```

- [ ] **Step 2: README の "How it works" の末尾段落を書き換える**

`Counting only ever wraps a Lua callback. String right-hand sides, `expr` mappings, and string command definitions are passed through untouched.` を次に置き換える。

```markdown
Keymaps are counted by wrapping them. A Lua callback is wrapped directly. A
string right-hand side is re-registered as an `expr` mapping that returns the
original string, which keeps counts, registers, operator-pending and
`operatorfunc` intact while making `<Plug>` and `:cmd<CR>` mappings countable.
The original `noremap` flag is preserved, so `<Plug>` still expands and
`nnoremap Y y$` still does not.

Mappings that predate the hook, including Neovim's own, are wrapped in a single
sweep at `setup()`. A `<Plug>` mapping is credited to the plugin that provides
it, even when you wrote the mapping yourself.
```

- [ ] **Step 3: README の "Limitations" を書き換える**

`## Limitations` 節の中身を次に置き換える。

```markdown
- Repeating with `.` is not counted. It does not go through the mapping.
- Mappings whose right-hand side is a string *and* marked `expr` are left
  alone. That string is an expression to evaluate, not a key sequence.
- Buffer-local mappings set before the hook is installed are missed.
- Commands defined as Vimscript strings fall back to counting typed
  invocations.
- Direct Lua API calls are not counted.
- lazy.nvim only.
```

- [ ] **Step 4: `doc/tally.txt` の Commands 節に `:TallyKeys` を足す**

`*:Tally*` の項目の直後に追加する。

```
                                                                  *:TallyKeys*
:TallyKeys              Open the keymap usage report in a new tab. Lists every
                        mapping that currently exists, grouped by how often it
                        has been pressed. Mappings you never press appear
                        under the unused group.
```

- [ ] **Step 5: `doc/tally.txt` の Limitations 節を README と揃える**

`7. Limitations` 節の中身を Step 3 と同じ内容に書き換える（ヘルプの体裁に合わせて78桁で折り返す）。

- [ ] **Step 6: ヘルプタグを再生成する**

Run: `nvim --headless -c "helptags doc" -c "qa!"`
Expected: エラーなし。`doc/tags` が更新される。

- [ ] **Step 7: 全テストと整形チェックを実行する**

Run: `make test && make fmt-check`
Expected: 両方 PASS。

- [ ] **Step 8: コミットする**

```bash
git add README.md doc/tally.txt doc/tags
git commit -m "docs: describe expr wrapping, the startup sweep and :TallyKeys"
```

---

## Self-Review

**1. Spec coverage**

| Spec 節 | 対応タスク |
|---|---|
| §3.1 文字列 rhs の expr 化 | Task 2 |
| §3.2 検証済みの挙動 | Task 2 Step 1（`<Plug>`・レジスタ・noremap 保全）、Task 4 Step 6（コスト実測） |
| §3.3 起動時の一掃ラップ | Task 4 |
| §3.4 二重ラップの防止 | Task 1 |
| §3.5 `<Plug>` lhs を包まない | Task 1 |
| §4.1 `$user` | Task 5 |
| §4.2 `<Plug>` rhs の帰属 | Task 3 |
| §4.3 解決順序 | Task 3・Task 5（既存順序を保つ実装） |
| §5 データモデル変更なし | 全タスクで `counter`/`store` に触れない |
| §6.1 API の分離 | Task 7 |
| §6.2 未使用マッピングの検出 | Task 7（`keys.existing` / `keys.classify`） |
| §6.3 表示と閾値 | Task 7 |
| §6.4 `session_only` と `rhs_kind` の削除 | Task 6 |
| §7 設定を追加しない | 全タスクで `config.defaults` に触れない |
| §8 既知の限界 | Task 8 |
| §9 テスト戦略 | 各タスクの Step 1 |

`operatorfunc` + `g@`、オペレータ待機、挿入モード、`<SNR>` の検証は spec §3.2 で headless 実測済みだが、Task 2 のテストには `<Plug>`・レジスタ・`noremap` 保全の3つだけを入れた。残りは同じ expr ラップ経路を通るため、テストの追加コストに見合わないと判断した。

**2. Placeholder scan**

「TBD」「後で」「適宜」「Task N と同様」は無し。全コードステップに実コードを記載した。Task 6 は削除作業なので削る対象を行単位で列挙した。

**3. Type consistency**

- `track.make_wrapper(plugin, lhs, rhs)` — Task 2 で定義、Task 3 で置き換え、Task 2 Step 5 の `wrap_existing` と Task 4 の `sweep` 経由で使用。引数の並びは一貫している
- `track.is_plug_lhs(lhs)` / `track.mark_wrapped(fn)` — Task 1 で定義、Task 2・3・4 で使用
- `attrib.plug_owner(rhs)` — Task 3 で定義、同 Task の `make_wrapper` で使用
- `attrib.resolve_from(paths)` — Task 5 で定義、同 Task の `resolve` で使用
- `attrib.user_path(path)` — Task 5 で定義、同 Task の `resolve_from` で使用
- `keys.collect` / `keys.existing` / `keys.classify` / `keys.render` / `keys.show` — Task 7 で定義、`show` が他4つを使用
- `idx.by_plug` — Task 3 で `attrib.build` と `track.diff_and_wrap` が書き、`attrib.plug_owner` が読む。Task 4・7 のテストのフェイク索引にも含めた

Task 3 で `parse_keys` に `rhs` を足し、Task 6 で `rhs_kind` を消す。`rhs` は残るので `by_plug` の構築は壊れない。

**4. 順序の依存**

Task 1 → 2 → 3 は順序が必須。Task 1 の `mark_wrapped` を Task 2 の `make_wrapper` が使い、Task 3 が `make_wrapper` を置き換える。Task 4 は Task 2 の `wrap_existing` に依存する。Task 5・6・7 は Task 1〜4 の後なら順不同。Task 8 は最後。
