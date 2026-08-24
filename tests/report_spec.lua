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
