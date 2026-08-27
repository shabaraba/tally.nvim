local M = {}

-- 閾値を出さないと、何回で「常用」に入るのかが読み手に分からない
function M.head(title, sessions, threshold, unit)
  return ("%s   %d sessions   低頻度 < %d %s"):format(title, sessions, threshold, unit)
end

-- 空のグループは見出しごと出さない
function M.append(lines, title, rows, note, format)
  if #rows == 0 then
    return
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "■ " .. title .. (note and ("  " .. note) or "")
  for _, row in ipairs(rows) do
    lines[#lines + 1] = format(row)
  end
end

function M.open(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "tally"
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd.tabnew()
  vim.api.nvim_win_set_buf(0, buf)
end

return M
