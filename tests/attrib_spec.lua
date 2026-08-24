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

describe("attrib.attributable", function()
  it("rejects lazy.nvim because it registers keys on behalf of others", function()
    assert.is_false(attrib.attributable("lazy.nvim"))
  end)

  it("rejects tally.nvim itself", function()
    assert.is_false(attrib.attributable("tally.nvim"))
  end)

  it("rejects nil", function()
    assert.is_false(attrib.attributable(nil))
  end)

  it("accepts a normal plugin", function()
    assert.is_true(attrib.attributable("flash.nvim"))
  end)
end)
