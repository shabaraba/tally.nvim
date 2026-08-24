local tally = require("tally")
local counter = require("tally.counter")
local config = require("tally.config")
local store = require("tally.store")

describe("tally.flush", function()
  local dir

  before_each(function()
    counter.drain()
    dir = vim.fn.tempname()
    config.setup({ store_dir = dir })
  end)

  it("writes drained counts to the store", function()
    counter.add("flash.nvim", "load")
    counter.add("flash.nvim", "key", "gs")
    counter.add("flash.nvim", "key", "gs")
    tally.flush()

    local records = store.read_all(dir)
    assert.equals(1, #records)
    assert.equals("flash.nvim", records[1].p)
    assert.equals(1, records[1].load)
    assert.equals(2, records[1].key.gs)
  end)

  it("empties the counter so the next flush is a delta", function()
    counter.add("oil.nvim", "load")
    tally.flush()
    tally.flush()
    assert.equals(1, #store.read_all(dir))
  end)

  it("writes nothing when there is no activity", function()
    tally.flush()
    assert.same({}, store.read_all(dir))
  end)

  it("writes one record per plugin", function()
    counter.add("a.nvim", "load")
    counter.add("b.nvim", "load")
    tally.flush()
    assert.equals(2, #store.read_all(dir))
  end)
end)

describe("tally.record_session", function()
  local dir

  before_each(function()
    counter.drain()
    dir = vim.fn.tempname()
    config.setup({ store_dir = dir })
  end)

  it("writes a $session record immediately", function()
    tally.record_session()
    local records = store.read_all(dir)
    assert.equals(1, #records)
    assert.equals("$session", records[1].p)
    assert.equals(1, records[1].load)
  end)

  local function has_session(records)
    for _, rec in ipairs(records) do
      if rec.p == "$session" then
        return true
      end
    end
    return false
  end

  it("is invoked by setup when VimEnter has already fired", function()
    local saved = tally._vim_entered
    tally._vim_entered = function()
      return true
    end
    tally.setup({ store_dir = dir })
    tally._vim_entered = saved

    assert.is_true(has_session(store.read_all(dir)))
  end)

  it("is deferred to VimEnter when startup is still in progress", function()
    local saved = tally._vim_entered
    tally._vim_entered = function()
      return false
    end
    tally.setup({ store_dir = dir })
    tally._vim_entered = saved

    assert.is_false(has_session(store.read_all(dir)))
    local acs = vim.api.nvim_get_autocmds({ group = "Tally", event = "VimEnter" })
    assert.equals(1, #acs)
  end)
end)
