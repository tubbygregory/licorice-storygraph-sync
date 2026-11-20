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

local function sync()
  if pending then return end
  local ok, started = pcall(function()
    local config = ctx.storage:read("bridge.txt") or ""
    local url, token = config:match("^%s*(https?://[^%s]+)%s+([%w_-]+)%s*$")
    if not url or #token < 32 then
      status = "Set up bridge.txt"
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

function on_load() end

function on_draw(c, g)
  g:clear(0)
  draw_text(c, g, 24, "StoryGraph Sync")
  draw_text(c, g, 73, status)
  local ok, book = pcall(function() return c.reader:current() end)
  if ok and type(book) == "table" and book.id then
    draw_text(c, g, 130, "Reader book ID")
    draw_text(c, g, 167, tostring(book.id))
  else
    draw_text(c, g, 130, "Open a book to see its ID")
  end
  draw_text(c, g, 262, "Sync now")
  draw_text(c, g, 362, "Enable automatic sync")
  draw_text(c, g, 462, "Disable automatic sync")
end

function on_input(c, event)
  if event.type ~= "pointer" or event.phase ~= "up" then return false end
  local y = event.y or 0
  if y >= 240 and y < 320 then
    sync()
  elseif y >= 340 and y < 420 then
    local ok, result = pcall(function() return c.lockscreen:set_default() end)
    status = ok and result ~= false and "Lock screen requested" or "Could not enable sync"
  elseif y >= 440 and y < 520 then
    local ok, result = pcall(function()
      if c.lockscreen:is_default() then return c.lockscreen:clear_default() end
    end)
    status = ok and result ~= false and "Automatic sync disabled" or "Could not disable sync"
  else
    return false
  end
  c:invalidate()
  return true
end
