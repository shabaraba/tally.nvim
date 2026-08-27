local M = {}

local data = {}

-- ロードはセッションごとに一度だけ数える。:Lazy reload などで LazyLoad が
-- 再発火してもプラグインのロード回数がセッション数の母数を超えないようにする
local loaded = {}

local function entry(plugin)
  local e = data[plugin]
  if not e then
    e = { load = 0, cmd = {}, key = {} }
    data[plugin] = e
  end
  return e
end

function M.add(plugin, kind, name)
  if not plugin then
    return
  end
  if kind == "load" then
    if loaded[plugin] then
      return
    end
    loaded[plugin] = true
    entry(plugin).load = 1
  elseif name then
    local e = entry(plugin)
    e[kind][name] = (e[kind][name] or 0) + 1
  end
end

function M.drain()
  local out = data
  data = {}
  return out
end

function M.peek()
  return data
end

-- drain はセッション途中の定期 flush でも呼ばれるため、ロード済みの記憶は消せない。
-- セッションをまたいだ状態を作り直したいときだけこちらを使う
function M.reset()
  data = {}
  loaded = {}
end

return M
