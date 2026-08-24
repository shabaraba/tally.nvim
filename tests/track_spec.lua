local track = require("tally.track")

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

describe("track.should_wrap_keymap", function()
  it("accepts a lua callback", function()
    assert.is_true(track.should_wrap_keymap({ callback = function() end, expr = 0 }))
  end)

  it("rejects a string rhs", function()
    assert.is_false(track.should_wrap_keymap({ rhs = ":Telescope<cr>", expr = 0 }))
  end)

  it("rejects an expr mapping", function()
    assert.is_false(track.should_wrap_keymap({ callback = function() end, expr = 1 }))
  end)
end)
