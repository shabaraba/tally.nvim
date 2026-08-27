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

  it("folds key spellings that differ only in notation", function()
    -- <C-w>h と <C-W>h は同じキー。宣言側と nvim_get_keymap 側で表記が割れる
    local agg = report.aggregate({
      { t = 1, p = "smart-splits.nvim", key = { ["<C-w>h"] = 70 } },
      { t = 2, p = "smart-splits.nvim", key = { ["<C-W>h"] = 5 } },
    })
    local p = agg.plugins["smart-splits.nvim"]
    assert.equals(75, p.key["<C-W>h"])
    assert.equals(1, vim.tbl_count(p.key))
  end)
end)

describe("report.classify", function()
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
    assert.same({ "vim-mql5" }, names(report.classify(agg, roster).unloaded))
  end)

  it("puts plugins under 10 percent of sessions in low", function()
    assert.same({ "diffview.nvim" }, names(report.classify(agg, roster).low))
  end)

  it("puts frequently used plugins in high", function()
    assert.same({ "yanky.nvim", "telescope.nvim" }, names(report.classify(agg, roster).high))
  end)

  it("excludes passive plugins from every usage group", function()
    local groups = report.classify(agg, roster)
    assert.same({ "hlchunk.nvim" }, names(groups.passive))
    assert.is_false(vim.tbl_contains(names(groups.high), "hlchunk.nvim"))
  end)
end)

describe("report.render", function()
  it("produces lines including a header and every group heading", function()
    local agg = { sessions = 10, plugins = {} }
    local lines = report.render(agg, report.classify(agg, {}))
    assert.is_true(#lines > 0)
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("tally"))
    assert.is_truthy(text:find("10 sessions"))
    -- 何回ロードされたら「常用」なのかを読み手に示す
    assert.is_truthy(text:find("低頻度 < 1 sess", 1, true))
  end)
end)

describe("report.classify roster filtering", function()
  local agg = { sessions = 10, plugins = { ["flash.nvim"] = { sessions = 9 } } }

  before_each(function()
    config.setup({})
  end)

  it("never lists lazy.nvim as a removal candidate", function()
    local groups = report.classify(agg, { "lazy.nvim", "flash.nvim" })
    for _, row in ipairs(groups.unloaded) do
      assert.not_equals("lazy.nvim", row.name)
    end
  end)

  it("never lists itself as a removal candidate", function()
    local groups = report.classify(agg, { "tally.nvim", "flash.nvim" })
    assert.same({}, groups.unloaded)
  end)
end)
