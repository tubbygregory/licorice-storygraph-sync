
function on_load()
  sync()
end

function on_draw(c, g)
  g:clear(0)
  draw_text(c, g, 300, "StoryGraph Sync")
  draw_text(c, g, 352, status)
  if not pending then c.lock:done() end
end

function on_input() return false end
