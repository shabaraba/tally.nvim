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
    pcall(vim.keymap.del, "n", "gzt")
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
end)

describe("track.spec_owner", function()
  before_each(function()
    attrib._index = {
      by_key = { n = { gs = "flash.nvim" }, x = { [",s"] = "nvim-surround" } },
      by_cmd = {},
      kinds = {},
      dirs = {},
    }
  end)

  after_each(function()
    attrib._index = nil
  end)

  it("resolves a lhs declared in a lazy spec", function()
    assert.equals("flash.nvim", track.spec_owner("n", "gs"))
  end)

  it("checks every mode when given a list", function()
    assert.equals("nvim-surround", track.spec_owner({ "n", "x" }, ",s"))
  end)

  it("returns nil for an unknown lhs", function()
    assert.is_nil(track.spec_owner("n", "zz"))
  end)
end)

describe("track.hook attribution", function()
  local saved_set

  before_each(function()
    counter.drain()
    attrib._index = {
      by_key = { n = { gs = "flash.nvim" } },
      by_cmd = {},
      kinds = {},
      dirs = { { dir = "/data/lazy/lazy.nvim", name = "lazy.nvim" } },
    }
    saved_set = vim.keymap.set
    track._hooked = false
  end)

  after_each(function()
    vim.keymap.set = saved_set
    track._hooked = false
    attrib._index = nil
  end)

  it("prefers the lazy spec owner over the calling plugin", function()
    local seen
    vim.keymap.set = function(_, _, rhs)
      seen = rhs
    end
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = false } })

    vim.keymap.set("n", "gs", function() end)
    assert.is_function(seen)
    seen()

    assert.equals(1, counter.peek()["flash.nvim"].key["gs"])
    assert.is_nil(counter.peek()["lazy.nvim"])
  end)

  it("does not count a keymap it can only attribute to lazy.nvim", function()
    local seen
    vim.keymap.set = function(_, _, rhs)
      seen = rhs
    end
    track.hook({ hook_keymap_set = true, track = { key = true, cmd = false } })

    -- spec に無い lhs。呼び出し元も解決できないのでラップされない
    local original = function() end
    vim.keymap.set("n", "zz", original)
    assert.equals(original, seen)
    assert.is_nil(counter.peek()["lazy.nvim"])
  end)
end)

describe("track.attach LazyLoad filtering", function()
  before_each(function()
    counter.drain()
    fake_index()
    track.attach({ track = { load = true, cmd = false, key = false } })
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "TallyTrack")
    attrib._index = nil
  end)

  local function fire(name)
    vim.api.nvim_exec_autocmds("User", { pattern = "LazyLoad", modeline = false, data = name })
  end

  it("counts a normal plugin load", function()
    fire("flash.nvim")
    assert.equals(1, counter.peek()["flash.nvim"].load)
  end)

  it("ignores its own load so it does not always show as heavily used", function()
    fire("tally.nvim")
    assert.is_nil(counter.peek()["tally.nvim"])
  end)

  it("ignores non-string event data", function()
    fire(nil)
    assert.same({}, counter.peek())
  end)
end)

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
