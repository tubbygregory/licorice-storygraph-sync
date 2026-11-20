local pending = false
local status = "Ready"

local MAX_SYNC_BYTES = 60000

local function book_text(value)
  if type(value) ~= "string" or not utf8.len(value) then return nil end
  value = value:match("^%s*(.-)%s*$")
  if value == "" or #value > 256 then return nil end
  return value
end

local function snapshot()
  local progress, books, order = {}, {}, {}
  local function record(book, percent)
    if type(book) ~= "table" or not book.id then return end
    local id = tostring(book.id)
    local number = tonumber(percent)
    if number and number > 0 and number <= 100 then
      progress[id] = math.max(progress[id] or 0, math.floor(number))
    end
    local metadata = books[id] or {}
    metadata.title = metadata.title or book_text(book.title)
    metadata.author = metadata.author or book_text(book.author)
    metadata.isbn = metadata.isbn or book_text(book.isbn)
    if next(metadata) and not books[id] then
      books[id] = metadata
      order[#order + 1] = id
    end
  end

  local ok, current = pcall(function() return ctx.reader:current() end)
  if ok and type(current) == "table" then record(current, current.percent) end
  for _, book in ipairs(ctx.reader:books() or {}) do
    if type(book) == "table" then record(book, book.percent) end
  end
  for _, book in ipairs(ctx.reader:all_books() or {}) do
    if type(book) == "table" and book.id and (book.finished == true or progress[tostring(book.id)]) then
      record(book, book.finished == true and 100 or nil)
    end
  end
  local ids = {}
  for _, id in ipairs(order) do
    if progress[id] then ids[#ids + 1] = id else books[id] = nil end
  end
  local current_id = type(current) == "table" and current.id and tostring(current.id) or nil
  return progress, books, ids, current_id
end

local function sync_body(progress, books, ids, current)
  local encoded = ctx.json:encode({progress = progress, books = books, current = current})
  if #encoded <= MAX_SYNC_BYTES then return encoded end

  local smallest = ctx.json:encode({progress = progress})
  if #smallest > MAX_SYNC_BYTES then return nil end
  local first, last = 1, #ids - 1
  while first <= last do
    local count = (first + last) // 2
    local subset = {}
    for i = 1, count do subset[ids[i]] = books[ids[i]] end
    local candidate = ctx.json:encode({progress = progress, books = subset, current = current})
    if #candidate <= MAX_SYNC_BYTES then
      smallest, first = candidate, count + 1
    else
      last = count - 1
    end
  end
  return smallest
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
    local progress, books, ids, current = snapshot()
    if next(progress) == nil then
      status = "No saved progress"
      return false
    end
    local body = sync_body(progress, books, ids, current)
    if not body then
      status = "Reading history exceeds sync limit"
      return false
    end
    pending = true
    status = "Syncing..."
    local job = ctx.net:request({
      url = url:gsub("/+$", "") .. "/sync",
      method = "POST",
      timeout_ms = 30000,
      headers = {["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. token},
      body = body
    }, function(c, reply)
      pending = false
      local code = reply and tonumber(reply.status or reply.code)
      if code == 200 then
        status = "Sync checked"
        if type(reply.body) == "string" then
          local decoded, result = pcall(function() return c.json:decode(reply.body) end)
          if decoded and type(result) == "table" and (tonumber(result.unmatched) or 0) > 0 and result.checked == 0 then
            status = "No syncable StoryGraph match"
          end
        end
      elseif code == 400 then
        status = "Check bridge version"
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
