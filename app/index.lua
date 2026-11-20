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
local setup_open, editing = false, false
local bridge_url, bridge_token

local function trim(value)
  return value:match("^%s*(.-)%s*$")
end

local function edit_field(c, label, value, limit, accept)
  editing = true
  local ok, editor = pcall(function()
    return c.input:edit({
      rect = {x = 20, y = 175, w = 440, h = 48},
      text = value or "",
      placeholder = label,
      max_chars = limit,
      multiline = false,
      on_end = function(context, text, reason)
        editing = false
        if (reason == "enter" or reason == nil) and type(text) == "string" then accept(context, trim(text)) end
        context:invalidate()
      end,
    })
  end)
  if not ok or not editor then
    editing = false
    status = "Could not open keyboard"
  end
end

local function current_book(c)
  local ok, book = pcall(function() return c.reader:current() end)
  if ok and type(book) == "table" and book.id then return book end
end

local function connect_request(c, path, payload, finished)
  if pending then return end
  if not bridge_url or not bridge_url:match("^https?://[^%s/@?#]+/*$") then
    status = "Enter the bridge base URL"
    return
  end
  if not bridge_token or #bridge_token < 32 or not bridge_token:match("^[%w_-]+$") then
    status = "Enter a valid bridge token"
    return
  end
  pending = true
  status = "Connecting..."
  local ok, job = pcall(function()
    return c.net:request({
      url = bridge_url:gsub("/+$", "") .. path,
      method = "POST",
      timeout_ms = 15000,
      headers = {["Authorization"] = "Bearer " .. bridge_token, ["Content-Type"] = "application/json"},
      body = c.json:encode(payload),
    }, function(context, reply)
      pending = false
      local code = reply and tonumber(reply.status or reply.code)
      if code == 200 then
        finished(context)
      elseif code == 401 then
        status = "Bridge token rejected"
      elseif code == 409 then
        status = "Edition is already linked"
      elseif code == 502 then
        status = "Check sign-in and Currently Reading"
      elseif code == 404 then
        status = "Update the bridge on your computer"
      else
        status = "Bridge request failed"
      end
      context:invalidate()
    end)
  end)
  if not ok or not job then
    pending = false
    status = "Could not contact bridge"
  end
end

local function open_setup(c)
  bridge_url, bridge_token = read_bridge(c)
  setup_open = true
  status = bridge_url and "Bridge settings saved" or "Start the bridge on your computer"
end

local function draw_button(c, g, y, label)
  g:rect(12, y - 10, 456, 44)
  draw_text(c, g, y, label)
end

local function draw_setup(c, g)
  draw_text(c, g, 24, "StoryGraph setup")
  draw_text(c, g, 72, status)
  if editing then return end
  draw_button(c, g, 150, "Bridge address")
  if bridge_url then draw_text(c, g, 196, bridge_url:sub(1, 36)) end
  draw_button(c, g, 250, bridge_token and "Change bridge token" or "Enter bridge token")
  draw_button(c, g, 350, "Connect and save")
  draw_button(c, g, 450, "Link current book")
  draw_button(c, g, 550, "Back")
end

local function setup_input(c, y)
  if pending then return end
  if y >= 130 and y < 220 then
    edit_field(c, "http://192.168.1.20:8765", bridge_url, 128, function(_, value) bridge_url = value end)
  elseif y >= 230 and y < 310 then
    edit_field(c, "Bridge token", "", 128, function(_, value) bridge_token = value end)
  elseif y >= 330 and y < 410 then
    connect_request(c, "/pair", {}, function(context)
      local ok, saved = pcall(function()
        context.storage:write("bridge.txt", bridge_url .. "\n" .. bridge_token .. "\n")
        local url, token = read_bridge(context)
        return url == bridge_url and token == bridge_token
      end)
      status = ok and saved and "Bridge connected" or "Could not save settings"
    end)
  elseif y >= 430 and y < 510 then
    local book = current_book(c)
    local url, token = read_bridge(c)
    if not book then
      status = "Open a book on the reader first"
    elseif not url or url ~= bridge_url or token ~= bridge_token then
      status = "Connect and save the bridge first"
    else
      edit_field(c, "StoryGraph edition URL or ID", "", 160, function(context, value)
        local edition = value:match("/books/([%x%-]+)") or value
        if #edition ~= 36 or not edition:match("^[%x%-]+$") then
          status = "Enter a StoryGraph edition ID"
        else
          connect_request(context, "/link", {reader_id = tostring(book.id), edition = edition},
            function() status = "Book linked to StoryGraph" end)
        end
      end)
    end
  elseif y >= 530 and y < 610 then
    setup_open = false
    status = "Ready"
  end
end

local PICTURES_PER_PAGE = 7
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
  draw_text(c, g, 72, status)
  if editing then return end
  if #pictures == 0 then draw_text(c, g, 140, "No JPEGs found") end
  local selected = selected_wallpaper(c)
  for row = 1, PICTURES_PER_PAGE do
    local name = pictures[(page - 1) * PICTURES_PER_PAGE + row]
    if not name then break end
    local label = name:sub(1, 34)
    if #name > 34 then label = label .. "..." end
    draw_text(c, g, 130 + (row - 1) * 52, (name == selected and "* " or "") .. label)
  end
  if #pictures > PICTURES_PER_PAGE then draw_button(c, g, 510, "Next page") end
  draw_button(c, g, 560, "Import JPEG from URL")
  draw_button(c, g, 625, "Use default screen")
  draw_button(c, g, 690, "Back")
end

local function import_picture(c, url)
  if not url:match("^https://[^%s/@?#]+/[^%s]+$") then
    status = "Enter a direct HTTPS JPEG URL"
    return
  end
  local name = selected_wallpaper(c) == "downloaded.jpg" and "downloaded-alt.jpg" or "downloaded.jpg"
  pending, status = true, "Downloading picture..."
  local ok, job = pcall(function()
    return c.net:request({
      url = url,
      timeout_ms = 20000,
      save = {to = "files", name = name},
    }, function(context, reply)
      pending = false
      local code = reply and tonumber(reply.status or reply.code)
      local image = code == 200 and reply.saved and load_wallpaper(context, name)
      if image then
        pcall(function() image:release() end)
        status = save_wallpaper(context, name) and "Lock screen picture saved" or "Could not save picture"
        pictures = nil
      else
        pcall(function() context.storage:remove(name) end)
        status = "Use a direct JPEG up to 480 x 800"
        open_pictures(context)
      end
      context:invalidate()
    end)
  end)
  if not ok or not job then
    pending, status = false, "Could not start download"
  end
end

local function pick_picture(c, y)
  if pending then return end
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
  elseif y >= 495 and y < 545 and #pictures > PICTURES_PER_PAGE then
    page = page % math.ceil(#pictures / PICTURES_PER_PAGE) + 1
  elseif y >= 550 and y < 610 then
    edit_field(c, "Direct HTTPS JPEG URL", "", 512, import_picture)
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
  if setup_open then return draw_setup(c, g) end
  draw_text(c, g, 24, "StoryGraph Sync")
  draw_text(c, g, 73, status)
  local book = current_book(c)
  if book then
    draw_text(c, g, 130, "Reader book ID")
    draw_text(c, g, 167, tostring(book.id))
  else
    draw_text(c, g, 130, "Open a book to see its ID")
  end
  draw_button(c, g, 262, "Sync now")
  draw_button(c, g, 362, "Enable automatic sync")
  draw_button(c, g, 462, "Disable automatic sync")
  draw_button(c, g, 562, "Choose lock screen picture")
  draw_button(c, g, 662, "StoryGraph setup")
end

function on_input(c, event)
  if editing then return false end
  if event.type ~= "pointer" or event.phase ~= "up" then return false end
  local y = event.y or 0
  if setup_open then
    setup_input(c, y)
  elseif pictures then
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
    status = "Choose a JPEG or import by URL"
    open_pictures(c)
  elseif y >= 640 and y < 720 and not pending then
    open_setup(c)
  else
    return false
  end
  c:invalidate()
  return true
end
