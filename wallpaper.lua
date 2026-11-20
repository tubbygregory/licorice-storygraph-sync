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
