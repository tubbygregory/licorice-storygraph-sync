
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
