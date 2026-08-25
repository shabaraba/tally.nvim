local track = require("tally.track")
local counter = require("tally.counter")
local attrib = require("tally.attrib")

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
