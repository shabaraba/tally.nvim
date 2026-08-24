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
    vim.keymap.set("n", "<Plug>TallyTestA", function()
      hits = hits + 1
    end)
    track.diff_and_wrap("fake.nvim", prev)

    local entry
    for _, e in ipairs(vim.api.nvim_get_keymap("n")) do
      if e.lhs == "<Plug>TallyTestA" then
        entry = e
      end
    end
    assert.is_table(entry)
    entry.callback()

    assert.equals(1, hits)
    assert.equals(1, counter.peek()["fake.nvim"].key["<Plug>TallyTestA"])
  end)
end)
