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

local function connect_bridge(c)
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
      url = bridge_url:gsub("/+$", "") .. "/pair",
      method = "POST",
      timeout_ms = 15000,
      headers = {["Authorization"] = "Bearer " .. bridge_token, ["Content-Type"] = "application/json"},
      body = "{}",
    }, function(context, reply)
      pending = false
      local code = reply and tonumber(reply.status or reply.code)
      if code == 200 then
        local ok, saved = pcall(function()
          context.storage:write("bridge.txt", bridge_url .. "\n" .. bridge_token .. "\n")
          local url, token = read_bridge(context)
          return url == bridge_url and token == bridge_token
        end)
        status = ok and saved and "Bridge connected" or "Could not save settings"
      elseif code == 401 then
        status = "Bridge token rejected"
      elseif code == 502 then
        status = "Check StoryGraph sign-in"
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
  draw_button(c, g, 450, "Back")
end

local function setup_input(c, y)
  if pending then return end
  if y >= 130 and y < 220 then
    edit_field(c, "http://192.168.1.20:8765", bridge_url, 128, function(_, value) bridge_url = value end)
  elseif y >= 230 and y < 310 then
    edit_field(c, "Bridge token", "", 128, function(_, value) bridge_token = value end)
  elseif y >= 330 and y < 410 then
    connect_bridge(c)
  elseif y >= 430 and y < 510 then
    setup_open = false
    status = "Ready"
  end
end
