local lhs = require("tally.lhs")

describe("lhs.canonical", function()
  local mapleader, maplocalleader

  before_each(function()
    mapleader, maplocalleader = vim.g.mapleader, vim.g.maplocalleader
    vim.g.mapleader = " "
    vim.g.maplocalleader = ","
  end)

  after_each(function()
    vim.g.mapleader, vim.g.maplocalleader = mapleader, maplocalleader
  end)

  it("folds the case of special key names", function()
    assert.equals(lhs.canonical("<C-W>h"), lhs.canonical("<C-w>h"))
  end)

  it("expands <leader> the way keymap.set does", function()
    assert.equals(lhs.canonical("  "), lhs.canonical("<leader><leader>"))
    assert.equals(lhs.canonical(",x"), lhs.canonical("<localleader>x"))
  end)

  it("spells raw spaces out so they are visible in the report", function()
    assert.equals("<Space><Space>", lhs.canonical("<leader><leader>"))
  end)

  it("is idempotent", function()
    for _, s in ipairs({ "<C-w>h", "<leader>ff", "jj", "<Esc><Esc>", "<C-B>" }) do
      assert.equals(lhs.canonical(s), lhs.canonical(lhs.canonical(s)))
    end
  end)

  it("leaves a mapleader containing % alone", function()
    vim.g.mapleader = "%"
    assert.equals("%f", lhs.canonical("<leader>f"))
  end)

  it("passes through values it cannot normalize", function()
    assert.equals("", lhs.canonical(""))
    assert.is_nil(lhs.canonical(nil))
  end)
end)
