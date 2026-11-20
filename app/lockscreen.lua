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
local WALLPAPER_SETTING = "wallpaper.txt"
local SCREEN_WIDTH, SCREEN_HEIGHT = 480, 800
local MAX_WALLPAPER_BYTES = 512 * 1024

local function is_wallpaper(name)
  return type(name) == "string" and not name:find("[/%s\\]") and
    (name:lower():match("%.jpe?g$") ~= nil)
end

local function selected_wallpaper(c)
  local ok, name = pcall(function() return c.storage:read(WALLPAPER_SETTING) end)
  if ok and is_wallpaper(name) then return name end
end

-- Read the frame dimensions before asking the device to allocate a decoded image.
local function jpeg_fits(bytes)
  if bytes:sub(1, 3) ~= "\255\216\255" then return false end
  local pos = 3
  while bytes:byte(pos) == 255 do
    repeat pos = pos + 1 until bytes:byte(pos) ~= 255
    local marker, high, low = bytes:byte(pos, pos + 2)
    if not low or marker == 0xDA or marker == 0xD9 then return false end
    local length = high * 256 + low
    if length < 2 or pos + length > #bytes then return false end
    if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
      if length < 8 then return false end
      local h1, h2, w1, w2 = bytes:byte(pos + 4, pos + 7)
      local width, height = w1 * 256 + w2, h1 * 256 + h2
      return width > 0 and width <= SCREEN_WIDTH and height > 0 and height <= SCREEN_HEIGHT
    end
    pos = pos + length + 1
  end
  return false
end

local function load_wallpaper(c, name)
  if not is_wallpaper(name) then return nil end
  local ok, image = pcall(function()
    local size = c.storage:size(name)
    if type(size) ~= "number" or size < 3 or size > MAX_WALLPAPER_BYTES then return nil end
    local bytes = c.storage:read(name)
    if type(bytes) ~= "string" or #bytes > MAX_WALLPAPER_BYTES or not jpeg_fits(bytes) then return nil end
    return c.image:decode(bytes, {max_w = SCREEN_WIDTH, max_h = SCREEN_HEIGHT})
  end)
  if not ok or not image then return nil end
  if image.width < 1 or image.width > SCREEN_WIDTH or image.height < 1 or image.height > SCREEN_HEIGHT then
    pcall(function() image:release() end)
    return nil
  end
  return image
end

local function save_wallpaper(c, name)
  local ok, saved = pcall(function()
    c.storage:write(WALLPAPER_SETTING, name or "default")
    return selected_wallpaper(c) == name
  end)
  return ok and saved
end

local wallpaper

function on_load(c)
  sync()
  wallpaper = load_wallpaper(c, selected_wallpaper(c))
end

function on_draw(c, g)
  g:clear(0)
  local drawn = false
  if wallpaper then
    local x = (SCREEN_WIDTH - wallpaper.width) // 2
    local y = (SCREEN_HEIGHT - wallpaper.height) // 2
    local ok, result, err = pcall(function() return g:image(wallpaper, x, y) end)
    drawn = ok and result ~= false and not (result == nil and err ~= nil)
  end
  if not drawn then
    draw_text(c, g, 300, "StoryGraph Sync")
    draw_text(c, g, 352, status)
  end
  if not pending then c.lock:done() end
end

function on_input() return false end
