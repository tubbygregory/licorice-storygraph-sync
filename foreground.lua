
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
