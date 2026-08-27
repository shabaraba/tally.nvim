local attrib = require("tally.attrib")

-- source が runtime 配下になる関数を作る。実在の runtime 関数に頼ると、
-- Neovim 側の実装が Lua から C へ移っただけでテストが壊れる
local function runtime_fn()
  return load("return function() end", "@" .. vim.env.VIMRUNTIME .. "/lua/vim/_defaults.lua")()
end

describe("attrib.runtime_path", function()
  it("recognizes a path under VIMRUNTIME", function()
    assert.is_true(attrib.runtime_path("@" .. vim.env.VIMRUNTIME .. "/lua/vim/_defaults.lua"))
  end)

  it("recognizes an embedded runtime chunk name", function()
    -- ランタイムが埋め込まれたビルドでは source が絶対パスにならない
    assert.is_true(attrib.runtime_path("@vim/_core/defaults"))
  end)

  it("rejects a plugin path and a non-path", function()
    assert.is_false(attrib.runtime_path("/data/lazy/oil.nvim/lua/oil.lua"))
    assert.is_false(attrib.runtime_path("/data/lazy/vim/lua/x.lua"))
    assert.is_false(attrib.runtime_path(""))
    assert.is_false(attrib.runtime_path(nil))
  end)
end)

describe("attrib.runtime_fn", function()
  it("detects a function defined under VIMRUNTIME", function()
    assert.is_true(attrib.runtime_fn(runtime_fn()))
  end)

  it("rejects a function defined elsewhere and a non-function", function()
    assert.is_false(attrib.runtime_fn(function() end))
    assert.is_false(attrib.runtime_fn("yy"))
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
  end)

  it("expands a mode list into one entry per mode", function()
    local got = attrib.parse_keys({ { ",s", "<Plug>(nvim-surround-normal)", mode = { "n", "v" } } })
    assert.equals(2, #got)
    assert.equals("n", got[1].mode)
    assert.equals("v", got[2].mode)
  end)

  it("defaults mode to n when absent", function()
    local got = attrib.parse_keys({ { ";f", ":Telescope find_files <cr>" } })
    assert.equals("n", got[1].mode)
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

describe("attrib.user_path", function()
  it("recognises a file under the config dir", function()
    local cfg = vim.fn.stdpath("config")
    assert.is_true(attrib.user_path("@" .. cfg .. "/lua/keymaps.lua"))
    assert.is_true(attrib.user_path(cfg .. "/init.lua"))
  end)

  it("rejects anything outside it", function()
    assert.is_false(attrib.user_path("@/data/lazy/telescope.nvim/lua/x.lua"))
    assert.is_false(attrib.user_path('@[string "luaeval"]'))
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

  it("deliberately prefers a UTILITY-table plugin over $user, in either frame order", function()
    attrib._index = {
      by_key = {},
      by_cmd = {},
      by_plug = {},
      kinds = {},
      dirs = { { dir = "/data/lazy/plenary.nvim", name = "plenary.nvim" } },
    }
    local cfg = vim.fn.stdpath("config")
    local user_frame = "@" .. cfg .. "/lua/keymaps.lua"
    local utility_frame = "@/data/lazy/plenary.nvim/lua/x.lua"

    assert.equals("plenary.nvim", attrib.resolve_from({ utility_frame, user_frame }))
    assert.equals("plenary.nvim", attrib.resolve_from({ user_frame, utility_frame }))
  end)
end)
