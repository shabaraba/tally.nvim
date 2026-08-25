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

    assert.same(
      { "jj" },
      vim.tbl_map(function(r)
        return r.lhs
      end, groups.high)
    )
    assert.same(
      { "<leader>gs" },
      vim.tbl_map(function(r)
        return r.lhs
      end, groups.low)
    )
    assert.same(
      { "<leader>xx" },
      vim.tbl_map(function(r)
        return r.lhs
      end, groups.unused)
    )
  end)

  it("pins the low/high boundary at sessions = 20 (threshold = floor(20 * 0.1) = 2)", function()
    local rows = {
      ["below"] = { lhs = "below", count = 1, owner = "x" },
      ["at"] = { lhs = "at", count = 2, owner = "x" },
    }
    local existing = { below = true, at = true }
    local groups = keys.classify(rows, existing, 20)

    assert.same(
      { "below" },
      vim.tbl_map(function(r)
        return r.lhs
      end, groups.low)
    )
    assert.same(
      { "at" },
      vim.tbl_map(function(r)
        return r.lhs
      end, groups.high)
    )
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
    assert.same(
      { "c", "a", "b" },
      vim.tbl_map(function(r)
        return r.lhs
      end, groups.high)
    )
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
