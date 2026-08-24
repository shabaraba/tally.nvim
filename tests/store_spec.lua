local store = require("tally.store")

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

describe("store", function()
  it("builds a monthly path", function()
    local t = os.time({ year = 2026, month = 3, day = 15, hour = 12 })
    assert.equals("/tmp/x/2026-03.jsonl", store.path("/tmp/x", t))
  end)

  it("encodes a single compact line", function()
    local lines = store.encode(100, "flash.nvim", { load = 1, cmd = {}, key = { gs = 3 } })
    assert.equals(1, #lines)
    local rec = vim.json.decode(lines[1])
    assert.equals("flash.nvim", rec.p)
    assert.equals(100, rec.t)
    assert.equals(1, rec.load)
    assert.equals(3, rec.key.gs)
    assert.is_nil(rec.cmd)
  end)

  it("omits zero load", function()
    local lines = store.encode(100, "oil.nvim", { load = 0, cmd = { Oil = 1 }, key = {} })
    local rec = vim.json.decode(lines[1])
    assert.is_nil(rec.load)
    assert.equals(1, rec.cmd.Oil)
  end)

  it("encodes nothing when there is no activity", function()
    assert.same({}, store.encode(100, "oil.nvim", { load = 0, cmd = {}, key = {} }))
  end)

  it("splits oversized records into multiple lines under 4096 bytes", function()
    local key = {}
    for i = 1, 400 do
      key[("lhs_%03d_%s"):format(i, string.rep("x", 20))] = i
    end
    local lines = store.encode(100, "big.nvim", { load = 1, cmd = {}, key = key })
    assert.is_true(#lines > 1)
    for _, line in ipairs(lines) do
      assert.is_true(#line < 4096, "line too long: " .. #line)
    end
    local total, load_seen = 0, 0
    for _, line in ipairs(lines) do
      local rec = vim.json.decode(line)
      load_seen = load_seen + (rec.load or 0)
      for _, n in pairs(rec.key or {}) do
        total = total + n
      end
    end
    assert.equals(1, load_seen)
    assert.equals(400 * 401 / 2, total)
  end)

  it("round-trips through append and read_all", function()
    local dir = tmpdir()
    store.append(dir, store.encode(100, "flash.nvim", { load = 1, cmd = {}, key = { gs = 2 } }))
    store.append(dir, store.encode(200, "flash.nvim", { load = 1, cmd = {}, key = { gs = 5 } }))
    local records = store.read_all(dir)
    assert.equals(2, #records)
    local sum = 0
    for _, rec in ipairs(records) do
      sum = sum + rec.key.gs
    end
    assert.equals(7, sum)
  end)

  it("creates the directory if missing", function()
    local dir = vim.fn.tempname() .. "/nested"
    assert.is_true(store.append(dir, store.encode(100, "a.nvim", { load = 1 })))
    assert.equals(1, #store.read_all(dir))
  end)

  it("skips malformed lines", function()
    local dir = tmpdir()
    store.append(dir, store.encode(100, "flash.nvim", { load = 1 }))
    local path = store.path(dir, os.time())
    local fd = vim.uv.fs_open(path, "a", 420)
    vim.uv.fs_write(fd, '{"p":"broken"\n')
    vim.uv.fs_close(fd)
    local records = store.read_all(dir)
    assert.equals(1, #records)
    assert.equals("flash.nvim", records[1].p)
  end)

  it("returns an empty list for a missing directory", function()
    assert.same({}, store.read_all(vim.fn.tempname()))
  end)
end)
