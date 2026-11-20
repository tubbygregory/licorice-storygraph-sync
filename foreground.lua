
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
