-- SmartThings Edge driver: Slide curtain motor over the Slide Local API (LAN, no cloud).
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local cosock = require "cosock"
local slide = require "slide_api"

local windowShade = capabilities.windowShade
local windowShadeLevel = capabilities.windowShadeLevel

local MOVE_POLL_SECS = 2      -- poll rate while the curtain is moving
local MOVE_POLL_MAX = 45      -- give up tracking a move after this many seconds
local STATE_NAMES = {
  open = windowShade.windowShade.open,
  closed = windowShade.windowShade.closed,
  opening = windowShade.windowShade.opening,
  closing = windowShade.windowShade.closing,
  partial = windowShade.windowShade.partially_open,
  unknown = windowShade.windowShade.unknown,
}

local state = {} -- device.id -> { last_pos, target, move_timer, moving, moved_at }
local discovered = {} -- device_network_id -> { ip, info }  (filled by discovery scan)

local function cfg(device)
  local p = device.preferences or {}
  local code = p.deviceCode
  if code == nil or code == "" then code = nil end
  local ip = p.ipAddress
  if ip == nil or ip == "" or ip == "auto" then ip = device:get_field("ip") end
  return {
    ip = ip,
    code = code,
    interval = tonumber(p.pollInterval) or 60,
    invert = p.invertPosition == true,
  }
end

-- Slide: 0 = open, 1 = closed.  SmartThings shadeLevel: 100 = open, 0 = closed.
local function pos_to_level(pos, invert)
  local level = math.floor((1 - pos) * 100 + 0.5)
  if invert then level = 100 - level end
  if level < 0 then level = 0 elseif level > 100 then level = 100 end
  return level
end

local function level_to_pos(level, invert)
  if invert then level = 100 - level end
  return 1 - (level / 100)
end

local function emit_position(device, pos, moving)
  local c = cfg(device)
  local level = pos_to_level(pos, c.invert)
  device:emit_event(windowShadeLevel.shadeLevel(level))
  local s
  if moving then
    s = moving
  elseif level >= 95 then
    s = "open"
  elseif level <= 5 then
    s = "closed"
  else
    s = "partial"
  end
  device:emit_event(STATE_NAMES[s]())
end

local function read_position(device)
  local c = cfg(device)
  local info, err = slide.get_info(c.ip, c.code)
  if not info then
    log.warn(string.format("[%s] GetInfo failed: %s", device.label, tostring(err)))
    device:offline()
    return nil
  end
  device:online()
  local pos = tonumber(info.pos)
  if not pos then
    log.warn(string.format("[%s] GetInfo without pos: %s", device.label, tostring(info)))
    return nil
  end
  return pos, info
end

local function refresh(device, moving)
  local pos = read_position(device)
  if pos then
    local st = state[device.id]
    st.last_pos = pos
    emit_position(device, pos, moving)
  end
  return pos
end

local function stop_move_tracking(device)
  local st = state[device.id]
  if st.move_timer then
    device.thread:cancel_timer(st.move_timer)
    st.move_timer = nil
  end
  st.moving = nil
end

-- Poll quickly while moving; stop when position settles or target is reached.
local function track_move(device, direction, target)
  local st = state[device.id]
  stop_move_tracking(device)
  st.moving = direction
  st.target = target
  st.moved_at = os.time()
  local prev = st.last_pos
  local stable = 0
  local function tick()
    local pos = read_position(device)
    if pos then
      st.last_pos = pos
      local done = (target and math.abs(pos - target) < 0.03)
      if prev and math.abs(pos - prev) < 0.005 then stable = stable + 1 else stable = 0 end
      prev = pos
      if done or stable >= 2 or (os.time() - st.moved_at) > MOVE_POLL_MAX then
        st.moving = nil
        st.move_timer = nil
        emit_position(device, pos, nil)
        return
      end
      emit_position(device, pos, direction)
    end
    st.move_timer = device.thread:call_with_delay(MOVE_POLL_SECS, tick)
  end
  st.move_timer = device.thread:call_with_delay(MOVE_POLL_SECS, tick)
end

local function go_to(device, pos)
  local c = cfg(device)
  local st = state[device.id]
  local current = st.last_pos or refresh(device)
  local direction = "opening"
  if current and pos > current then direction = "closing" end
  local ok, err = slide.set_pos(c.ip, c.code, pos)
  if not ok then
    log.error(string.format("[%s] SetPos failed: %s", device.label, tostring(err)))
    device:offline()
    return
  end
  device:online()
  emit_position(device, current or pos, direction)
  track_move(device, direction, pos)
end

-- capability handlers ------------------------------------------------------

local function handle_open(driver, device, cmd)
  go_to(device, cfg(device).invert and 1 or 0)
end

local function handle_close(driver, device, cmd)
  go_to(device, cfg(device).invert and 0 or 1)
end

local function handle_pause(driver, device, cmd)
  local c = cfg(device)
  local ok, err = slide.stop(c.ip, c.code)
  if not ok then
    log.error(string.format("[%s] Stop failed: %s", device.label, tostring(err)))
  end
  stop_move_tracking(device)
  device.thread:call_with_delay(1, function() refresh(device) end)
end

local function handle_set_level(driver, device, cmd)
  local level = tonumber(cmd.args.shadeLevel) or 0
  go_to(device, level_to_pos(level, cfg(device).invert))
end

local function handle_refresh(driver, device, cmd)
  refresh(device)
end

-- lifecycle ----------------------------------------------------------------

local function schedule_poll(device)
  local st = state[device.id]
  if st.poll_timer then
    device.thread:cancel_timer(st.poll_timer)
    st.poll_timer = nil
  end
  local interval = cfg(device).interval
  st.poll_timer = device.thread:call_on_schedule(interval, function()
    if not st.moving then refresh(device) end
  end, "slide-poll")
end

local function device_init(driver, device)
  state[device.id] = state[device.id] or {}
  device:emit_event(windowShade.supportedWindowShadeCommands({ "open", "close", "pause" }, { visibility = { displayed = false } }))
  schedule_poll(device)
  device.thread:call_with_delay(1, function() refresh(device) end)
end

local function device_added(driver, device)
  state[device.id] = state[device.id] or {}
  local d = discovered[device.device_network_id]
  if d then
    device:set_field("ip", d.ip, { persist = true })
    log.info(string.format("[slide] %s uses discovered IP %s", device.label, d.ip))
  end
  device:emit_event(windowShade.supportedWindowShadeCommands({ "open", "close", "pause" }, { visibility = { displayed = false } }))
  device:emit_event(STATE_NAMES.unknown())
  device:emit_event(windowShadeLevel.shadeLevel(0))
end

local function info_changed(driver, device, event, args)
  local old = args and args.old_st_store and args.old_st_store.preferences or {}
  local new = device.preferences or {}
  if old.ipAddress ~= new.ipAddress or old.deviceCode ~= new.deviceCode
      or old.pollInterval ~= new.pollInterval or old.invertPosition ~= new.invertPosition then
    stop_move_tracking(device)
    state[device.id].last_pos = nil
    schedule_poll(device)
    device.thread:call_with_delay(1, function() refresh(device) end)
  end
end

local function device_removed(driver, device)
  local st = state[device.id]
  if st then
    if st.poll_timer then device.thread:cancel_timer(st.poll_timer) end
    if st.move_timer then device.thread:cancel_timer(st.move_timer) end
    state[device.id] = nil
  end
end

-- discovery: Slide has no mDNS/SSDP, so we probe every host in the hub's /24
-- with POST /rpc/Slide.GetInfo (2 s timeout, 16 probes in parallel, ~35 s worst case).
-- Each Slide found becomes one device, keyed by its MAC; its IP is stored on the device.
local SCAN_CONCURRENCY = 16

local function existing_device(driver, dni)
  for _, dev in ipairs(driver:get_devices()) do
    if dev.device_network_id == dni or dev:get_field("slide_dni") == dni then return dev end
  end
end

-- a device created before auto discovery existed (no IP, no Slide identity yet)
local function unclaimed_device(driver)
  for _, dev in ipairs(driver:get_devices()) do
    local p = dev.preferences or {}
    local manual = p.ipAddress and p.ipAddress ~= "" and p.ipAddress ~= "auto"
    if not manual and not dev:get_field("ip") and not dev:get_field("slide_dni") then return dev end
  end
end

local function handle_found(driver, ip, info)
  local mac = (info.mac or ""):lower()
  local dni = mac ~= "" and ("slide-" .. mac) or ("slide-ip-" .. ip)
  discovered[dni] = { ip = ip, info = info }
  local dev = existing_device(driver, dni)
  if dev then
    if dev:get_field("ip") ~= ip then
      dev:set_field("ip", ip, { persist = true })
      log.info(string.format("[slide] %s moved to %s", dev.label, ip))
      state[dev.id] = state[dev.id] or {}
      dev.thread:call_with_delay(1, function() refresh(dev) end)
    end
    return
  end
  dev = unclaimed_device(driver)
  if dev then
    dev:set_field("slide_dni", dni, { persist = true })
    dev:set_field("ip", ip, { persist = true })
    log.info(string.format("[slide] adopting existing device '%s' for Slide %s at %s", dev.label, mac, ip))
    state[dev.id] = state[dev.id] or {}
    dev.thread:call_with_delay(1, function() refresh(dev) end)
    return
  end
  local name = info.zone_name
  if name == nil or name == "" then name = info.device_name end
  if name == nil or name == "" or name == "Slide" then
    name = "Slide " .. (mac ~= "" and mac:sub(-4):upper() or ip)
  end
  log.info(string.format("[slide] found Slide %s at %s, creating device '%s'", mac, ip, name))
  driver:try_create_device({
    type = "LAN",
    device_network_id = dni,
    label = name,
    profile = "slide-curtain",
    manufacturer = "Slide",
    model = "Slide Local API",
    vendor_provided_label = name,
  })
end

local function discovery(driver, opts, should_continue)
  local hub_ip = driver.environment_info and driver.environment_info.hub_ipv4
  if not hub_ip then
    -- environment_info may arrive after the first discovery event; ask the OS instead
    local ok, ip = pcall(function()
      local s = cosock.socket.udp()
      s:setpeername("8.8.8.8", 53)
      local addr = s:getsockname()
      s:close()
      return addr
    end)
    if ok and type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") then hub_ip = ip end
  end
  if not hub_ip then
    log.warn("[slide] hub IP unknown, cannot scan; add the Slide IP manually in Settings")
    return
  end
  local prefix = hub_ip:match("^(%d+%.%d+%.%d+%.)")
  log.info("[slide] scanning " .. prefix .. "0/24 for Slide motors")
  local next_host, pending, found = 1, 0, 0
  local function worker()
    while next_host <= 254 and should_continue() do
      local ip = prefix .. next_host
      next_host = next_host + 1
      local info = slide.probe(ip, 2)
      if info then
        found = found + 1
        local ok, err = pcall(handle_found, driver, ip, info)
        if not ok then log.error("[slide] handle_found: " .. tostring(err)) end
      end
    end
    pending = pending - 1
  end
  for i = 1, SCAN_CONCURRENCY do
    pending = pending + 1
    cosock.spawn(worker, "slide-scan-" .. i)
  end
  while pending > 0 do cosock.socket.sleep(0.5) end
  log.info(string.format("[slide] scan done, %d Slide(s) found", found))
end

local driver = Driver("slide-curtain-local", {
  discovery = discovery,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [windowShade.ID] = {
      [windowShade.commands.open.NAME] = handle_open,
      [windowShade.commands.close.NAME] = handle_close,
      [windowShade.commands.pause.NAME] = handle_pause,
    },
    [windowShadeLevel.ID] = {
      [windowShadeLevel.commands.setShadeLevel.NAME] = handle_set_level,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

log.info("[slide] Slide Curtain (local) driver starting, build 2026-10-26f (auto discovery + adopt)")
driver:run()
