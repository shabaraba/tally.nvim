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

describe("track.sweep mode preservation", function()
  local PROBES = { "<F7>", "<F8>", "<F9>", "<F10>" }

  -- lhs が現れるモードと、その entry.mode の組を並べる。
  -- 「存在するか」ではなく「どのモードに効くか」を比較するために mode まで見る
  local function shape(lhs)
    local out = {}
    for _, m in ipairs({ "n", "v", "x", "s", "o", "i", "c" }) do
      for _, e in ipairs(vim.api.nvim_get_keymap(m)) do
        if e.lhs == lhs then
          out[#out + 1] = m .. "->" .. e.mode
        end
      end
    end
    return out
  end

  local function wrapped(lhs)
    for _, m in ipairs({ "n", "v", "x", "s", "o", "i", "c" }) do
      for _, e in ipairs(vim.api.nvim_get_keymap(m)) do
        if e.lhs == lhs then
          return type(e.callback) == "function"
        end
      end
    end
    return false
  end

  before_each(function()
    require("tally.counter").drain()
    require("tally.attrib")._index =
      { by_key = {}, by_cmd = {}, by_plug = {}, kinds = {}, dirs = {} }
    track.orig_keymap_set = nil
    vim.cmd("xnoremap <F7> yy")
    vim.cmd("snoremap <F8> yy")
    vim.cmd("map <F9> yy")
    vim.cmd("map! <F10> xx")
  end)

  after_each(function()
    pcall(vim.keymap.del, "x", "<F7>")
    pcall(vim.keymap.del, "s", "<F8>")
    pcall(vim.keymap.del, "", "<F9>")
    pcall(vim.keymap.del, "!", "<F10>")
    require("tally.attrib")._index = nil
  end)

  it("does not widen a mapping's modes when wrapping it", function()
    local before = {}
    for _, lhs in ipairs(PROBES) do
      before[lhs] = shape(lhs)
    end

    track.sweep({ hook_keymap_set = true, track = { key = true } })

    for _, lhs in ipairs(PROBES) do
      assert.is_true(wrapped(lhs))
      assert.same(before[lhs], shape(lhs))
    end
  end)

  it("keeps an x-only mapping out of select mode", function()
    track.sweep({ hook_keymap_set = true, track = { key = true } })
    assert.same({ "v->x", "x->x" }, shape("<F7>"))
  end)

  it("keeps an s-only mapping out of visual mode", function()
    track.sweep({ hook_keymap_set = true, track = { key = true } })
    assert.same({ "v->s", "s->s" }, shape("<F8>"))
  end)

  it("keeps :map and :map! mappings on all their original modes", function()
    track.sweep({ hook_keymap_set = true, track = { key = true } })
    assert.same({ "n-> ", "v-> ", "x-> ", "s-> ", "o-> " }, shape("<F9>"))
    assert.same({ "i->!", "c->!" }, shape("<F10>"))
  end)
end)
