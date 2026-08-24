local M = {}

M.wrapped_cmds = {}

function M.extract_cmd_name(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end
  local s = line:gsub("^[%s:]+", "")
  -- range 接頭辞を読み飛ばす
  s = s:gsub("^'[<>%a],?'?[<>%a]?", "")
  s = s:gsub("^[%%%d,%.%$%+%-]+", "")
  s = s:gsub("^[%s:]+", "")
  return s:match("^(%a[%w_]*)")
end

function M.should_wrap_keymap(entry)
  if type(entry.callback) ~= "function" then
    return false
  end
  if entry.expr == 1 then
    return false
  end
  return true
end

return M
