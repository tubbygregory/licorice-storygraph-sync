local pending = false
local status = "Ready"

local function snapshot()
  local progress = {}
  for _, book in ipairs(ctx.reader:books() or {}) do
    local percent = tonumber(book.percent)
    if book.id and percent and percent > 0 and percent <= 100 then
      progress[tostring(book.id)] = math.floor(percent)
    end
  end
  for _, book in ipairs(ctx.reader:all_books() or {}) do
    if book.id and book.finished == true then progress[tostring(book.id)] = 100 end
  end
  return progress
end

local function read_bridge(c)
  local ok, config = pcall(function() return c.storage:read("bridge.txt") end)
  if ok and type(config) == "string" then
    return config:match("^%s*(https?://[^%s]+)%s+([%w_-]+)%s*$")
  end
end

local function sync()
  if pending then return end
  local ok, started = pcall(function()
    local url, token = read_bridge(ctx)
    if not url or #token < 32 then
      status = "Connect your StoryGraph bridge"
      return false
    end
    if not ctx.net or not ctx.reader then
      status = "Reader or Wi-Fi unavailable"
      return false
    end
    local progress = snapshot()
    if next(progress) == nil then
      status = "No saved progress"
      return false
    end
    pending = true
    status = "Syncing..."
    local job = ctx.net:request({
      url = url:gsub("/+$", "") .. "/sync",
      method = "POST",
      timeout_ms = 30000,
      headers = {["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. token},
      body = ctx.json:encode(progress)
    }, function(c, reply)
      pending = false
      local code = reply and tonumber(reply.status or reply.code)
      if code == 200 then
        status = "Sync checked"
      elseif code == 401 then
        status = "Check bridge token"
      elseif code == 502 then
        status = "Check StoryGraph bridge log"
      else
        status = "Bridge unavailable"
      end
      c:invalidate()
    end)
    return job ~= nil
  end)
  if not ok or (not started and pending) then
    pending = false
    status = "Could not start sync"
  end
end

local function draw_text(c, g, y, value)
  g:text(20, y, value, {font = c.fonts.medium})
end

function on_tick() end
