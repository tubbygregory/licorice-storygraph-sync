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

local PICTURES_PER_PAGE = 8
local pictures, page

local function open_pictures(c)
  pictures, page = {}, 1
  local ok, names = pcall(function() return c.storage:list() end)
  if not ok or type(names) ~= "table" then return end
  for _, name in ipairs(names) do
    if is_wallpaper(name) then pictures[#pictures + 1] = name end
  end
  table.sort(pictures)
end

local function draw_pictures(c, g)
  draw_text(c, g, 24, "Lock screen picture")
  draw_text(c, g, 72, "Copy JPEGs to the app SD folder")
  if #pictures == 0 then draw_text(c, g, 140, "No JPEGs found") end
  local selected = selected_wallpaper(c)
  for row = 1, PICTURES_PER_PAGE do
    local name = pictures[(page - 1) * PICTURES_PER_PAGE + row]
    if not name then break end
    local label = name:sub(1, 34)
    if #name > 34 then label = label .. "..." end
    draw_text(c, g, 130 + (row - 1) * 52, (name == selected and "* " or "") .. label)
  end
  if #pictures > PICTURES_PER_PAGE then draw_text(c, g, 560, "Next page") end
  draw_text(c, g, 625, "Use default screen")
  draw_text(c, g, 690, "Back")
end

local function pick_picture(c, y)
  if y >= 120 and y < 120 + PICTURES_PER_PAGE * 52 then
    local row = (y - 120) // 52 + 1
    local name = pictures[(page - 1) * PICTURES_PER_PAGE + row]
    if not name then return end
    local image = load_wallpaper(c, name)
    if image then
      pcall(function() image:release() end)
      status = save_wallpaper(c, name) and "Lock screen picture saved" or "Could not save picture"
    else
      status = "Use a JPEG up to 480 x 800"
    end
    pictures = nil
  elseif y >= 550 and y < 610 and #pictures > PICTURES_PER_PAGE then
    page = page % math.ceil(#pictures / PICTURES_PER_PAGE) + 1
  elseif y >= 615 and y < 675 then
    status = save_wallpaper(c) and "Default lock screen selected" or "Could not save choice"
    pictures = nil
  elseif y >= 680 and y < 745 then
    pictures = nil
  end
end

function on_load() end

function on_draw(c, g)
  g:clear(0)
  if pictures then return draw_pictures(c, g) end
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
  draw_text(c, g, 562, "Choose lock screen picture")
end

function on_input(c, event)
  if event.type ~= "pointer" or event.phase ~= "up" then return false end
  local y = event.y or 0
  if pictures then
    pick_picture(c, y)
  elseif y >= 240 and y < 320 then
    sync()
  elseif y >= 340 and y < 420 then
    local ok, result = pcall(function() return c.lockscreen:set_default() end)
    status = ok and result ~= false and "Lock screen requested" or "Could not enable sync"
  elseif y >= 440 and y < 520 then
    local ok, result = pcall(function()
      if c.lockscreen:is_default() then return c.lockscreen:clear_default() end
    end)
    status = ok and result ~= false and "Automatic sync disabled" or "Could not disable sync"
  elseif y >= 540 and y < 620 then
    open_pictures(c)
  else
    return false
  end
  c:invalidate()
  return true
end
