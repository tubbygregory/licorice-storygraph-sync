
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
