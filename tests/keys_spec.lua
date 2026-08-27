local config = require("tally.config")
local keys = require("tally.keys")

-- collect が受け取る agg は report.aggregate が正規化済みの key を入れて返す
describe("keys.collect", function()
  it("flattens per-plugin key counts into lhs rows", function()
    local agg = {
      sessions = 100,
      plugins = {
        ["telescope.nvim"] = { key = { ["<Space>ff"] = 12 } },
        ["$user"] = { key = { ["jj"] = 300, ["<Space>ff"] = 3 } },
      },
    }
    local rows = keys.collect(agg)
    assert.equals(300, rows["jj"].count)
    assert.equals("$user", rows["jj"].owner)
    -- 同じ lhs が両方に記録されていたら回数の多い側を持ち主とする
    assert.equals(15, rows["<Space>ff"].count)
    assert.equals("telescope.nvim", rows["<Space>ff"].owner)
  end)

  it("counts a press attributed to lazy.nvim but never names it as the owner", function()
    local rows = keys.collect({
      sessions = 10,
      plugins = { ["lazy.nvim"] = { key = { gs = 1 } } },
    })
    assert.equals(1, rows["gs"].count)
    assert.equals("-", rows["gs"].owner)
  end)

  it("returns an empty table for an empty aggregate", function()
    assert.same({}, keys.collect({ sessions = 0, plugins = {} }))
  end)

  it("uses better_owner so a tie in collect favors the lexically smaller name", function()
    -- 実際の走査順に依存しないことは keys.better_owner の直接呼び出しテストが保証する。
    -- ここでは collect がそのルールを実際に使っていることだけを確認する
    local agg = {
      sessions = 10,
      plugins = {
        ["zzz.nvim"] = { key = { ["<Space>tt"] = 7 } },
        ["aaa.nvim"] = { key = { ["<Space>tt"] = 7 } },
      },
    }
    local rows = keys.collect(agg)
    assert.equals("aaa.nvim", rows["<Space>tt"].owner)
  end)
end)

describe("keys.better_owner", function()
  -- pairs() の走査順に依存させないため、rows/collect を経由せず直接呼び出す。
  -- 2 つの it に分けているのは、片方の assert が先に落ちてもう片方が
  -- 実行されずに済んでしまう（=見かけ上パスする）事態を避けるため
  it("picks the lexically smaller plugin name on a tie, owner-arg larger", function()
    local owner, top = keys.better_owner("zzz.nvim", 7, "aaa.nvim", 7)
    assert.equals("aaa.nvim", owner)
    assert.equals(7, top)
  end)

  it("picks the lexically smaller plugin name on a tie, plugin-arg larger", function()
    local owner, top = keys.better_owner("aaa.nvim", 7, "zzz.nvim", 7)
    assert.equals("aaa.nvim", owner)
    assert.equals(7, top)
  end)

  it("still prefers the higher count over the name when they differ", function()
    local owner, top = keys.better_owner("aaa.nvim", 3, "zzz.nvim", 9)
    assert.equals("zzz.nvim", owner)
    assert.equals(9, top)
  end)
end)

describe("keys.classify", function()
  local function lhs_of(list)
    return vim.tbl_map(function(r)
      return r.lhs
    end, list)
  end

  after_each(function()
    config.setup({})
  end)

  it("splits by press count against the session threshold", function()
    local rows = {
      ["jj"] = { lhs = "jj", count = 300, owner = "$user" },
      ["<leader>gs"] = { lhs = "<leader>gs", count = 3, owner = "$user" },
    }
    local existing = {
      ["jj"] = { modes = { "n" }, owner = "$user" },
      ["<leader>gs"] = { modes = { "n" }, owner = "$user" },
      ["<leader>xx"] = { modes = { "n" }, owner = "$user" },
    }
    local groups = keys.classify(rows, existing, 100)

    assert.same({ "jj" }, lhs_of(groups.high))
    assert.same({ "<leader>gs" }, lhs_of(groups.low))
    assert.same({ "<leader>xx" }, lhs_of(groups.unused))
  end)

  it("pins the low/high boundary at sessions = 20 (threshold = floor(20 * 0.1) = 2)", function()
    local rows = {
      ["below"] = { lhs = "below", count = 1, owner = "x" },
      ["at"] = { lhs = "at", count = 2, owner = "x" },
    }
    local existing = { below = { modes = { "n" } }, at = { modes = { "n" } } }
    local groups = keys.classify(rows, existing, 20)

    assert.same({ "below" }, lhs_of(groups.low))
    assert.same({ "at" }, lhs_of(groups.high))
    assert.equals(2, groups.threshold)
  end)

  it("keeps a pressed row whose mapping is gone, but drops an unpressed one", function()
    -- バッファローカルな束縛は、そのバッファが閉じていると existing に出てこない。
    -- count > 0 の行は existing になくても low/high に残るべきで、
    -- count == 0 かつ existing にもない行だけが行き場を失ってよい。
    local rows = {
      ["pressed"] = { lhs = "pressed", count = 50, owner = "$user" },
      ["never"] = { lhs = "never", count = 0, owner = "$user" },
    }
    local groups = keys.classify(rows, {}, 100)
    assert.same({ "pressed" }, lhs_of(groups.high))
    assert.equals(0, #groups.low)
    assert.equals(0, #groups.unused)
  end)

  it("hides an unpressed mapping whose owner is unknown, but counts it", function()
    -- 持ち主が分からない行は「見直し候補」として読めない。
    -- 消したことを黙らないよう件数だけは残す
    local groups = keys.classify({}, { ["gzz"] = { modes = { "n" } } }, 100)
    assert.equals(0, #groups.unused)
    assert.same({ unknown = 1, passive = 0 }, groups.hidden)
  end)

  it("hides passive owners from the usage groups too", function()
    config.setup({ passive = { "nui" } })
    local rows = { ["<C-B>"] = { lhs = "<C-B>", count = 245, owner = "nui.nvim" } }
    local existing = { ["<C-B>"] = { modes = { "n" }, owner = "nui.nvim" } }
    local groups = keys.classify(rows, existing, 100)
    assert.equals(0, #groups.high)
    -- 帰属不明と passive は理由が違うので、まとめずに数える
    assert.same({ unknown = 0, passive = 1 }, groups.hidden)
  end)

  it("sorts by count desc then lhs asc", function()
    local rows = {
      ["b"] = { lhs = "b", count = 5, owner = "x" },
      ["a"] = { lhs = "a", count = 5, owner = "x" },
      ["c"] = { lhs = "c", count = 9, owner = "x" },
    }
    local existing = {
      a = { modes = { "n" } },
      b = { modes = { "n" } },
      c = { modes = { "n" } },
    }
    local groups = keys.classify(rows, existing, 10)
    assert.same({ "c", "a", "b" }, lhs_of(groups.high))
  end)
end)

describe("keys.render", function()
  it("prints a header and only non-empty groups", function()
    local groups = {
      unused = { { lhs = "<Space>xx", count = 0, owner = "$user" } },
      low = {},
      high = { { lhs = "jj", count = 300, owner = "$user" } },
      threshold = 14,
      hidden = { unknown = 0, passive = 0 },
    }
    local lines = keys.render(142, groups)
    assert.equals("tally keys   142 sessions   低頻度 < 14 回", lines[1])

    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("未使用", 1, true))
    assert.is_truthy(text:find("<Space>xx", 1, true))
    assert.is_truthy(text:find("jj", 1, true))
    assert.is_nil(text:find("非表示", 1, true))
    -- 見出しとしての「低頻度」はグループが空なので出ない
    assert.is_nil(text:find("■ 低頻度", 1, true))
  end)

  it("states how many rows were hidden and why", function()
    local groups = {
      unused = {},
      low = {},
      high = {},
      threshold = 10,
      hidden = { unknown = 5, passive = 2 },
    }
    local lines = keys.render(100, groups)
    assert.equals("  7 行は非表示（帰属不明 5 / passive 2）", lines[2])
  end)
end)

describe("keys.existing", function()
  local buf

  after_each(function()
    pcall(vim.keymap.del, "n", "gzk")
    pcall(vim.keymap.del, "n", "<Plug>(TallyKeysProbe)")
    if buf then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      buf = nil
    end
  end)

  it("lists real mappings and skips <Plug>", function()
    vim.keymap.set("n", "gzk", "yy")
    vim.keymap.set("n", "<Plug>(TallyKeysProbe)", "yy")
    local existing = keys.existing()
    assert.same({ "n" }, existing["gzk"].modes)
    assert.is_nil(existing["<Plug>(TallyKeysProbe)"])
  end)

  it("includes buffer-local mappings from loaded buffers and skips buffer-local <Plug>", function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.keymap.set("n", "gzb", "yy", { buffer = buf })
    vim.keymap.set("n", "<Plug>(TallyKeysBufProbe)", "yy", { buffer = buf })
    local existing = keys.existing()
    assert.same({ "n" }, existing["gzb"].modes)
    assert.is_nil(existing["<Plug>(TallyKeysBufProbe)"])
  end)

  it("normalizes the lhs it reports", function()
    vim.keymap.set("n", "<C-w>gzk", "yy")
    local existing = keys.existing()
    assert.is_truthy(existing["<C-W>gzk"])
    pcall(vim.keymap.del, "n", "<C-w>gzk")
  end)
end)

describe("keys.unused_owner", function()
  before_each(function()
    require("tally.attrib")._index = {
      by_key = { n = { gr = "refactoring.nvim" } },
      by_cmd = {},
      by_plug = {},
      dirs = {},
    }
  end)

  after_each(function()
    require("tally.attrib")._index = nil
  end)

  it("names the plugin whose lazy spec declares the lhs", function()
    assert.equals("refactoring.nvim", keys.unused_owner("gr", { modes = { "n" } }))
  end)

  it("falls back to the owner recorded when the mapping was wrapped", function()
    assert.equals("$user", keys.unused_owner("gzz", { modes = { "n" }, owner = "$user" }))
  end)

  it("falls back to - when nothing knows the lhs", function()
    assert.equals("-", keys.unused_owner("<leader>xx", { modes = { "n" } }))
  end)

  it("falls back to - when the mode list is missing", function()
    assert.equals("-", keys.unused_owner("gr", true))
  end)
end)

describe("keys unused row owners", function()
  after_each(function()
    pcall(vim.keymap.del, "x", "gzx")
    pcall(vim.keymap.del, "n", "gzz")
    require("tally.attrib")._index = nil
  end)

  local function owner_of(groups, lhs)
    for _, r in ipairs(groups.unused) do
      if r.lhs == lhs then
        return r.owner
      end
    end
  end

  it("names the spec owner of a mapping that exists but was never pressed", function()
    require("tally.attrib")._index = {
      by_key = { x = { gzx = "refactoring.nvim" } },
      by_cmd = {},
      by_plug = {},
      dirs = {},
    }
    vim.keymap.set("x", "gzx", "y")
    vim.keymap.set("n", "gzz", "y")

    local groups = keys.classify({}, keys.existing(), 100)
    assert.equals("refactoring.nvim", owner_of(groups, "gzx"))
    -- 宣言も帰属セルも無いものを推測はしない。候補にも出さない
    assert.is_nil(owner_of(groups, "gzz"))
  end)
end)
