-- Slide Local API client for SmartThings Edge.
-- Endpoints (POST, JSON body):  /rpc/Slide.GetInfo, /rpc/Slide.SetPos {"pos": 0..1},
-- /rpc/Slide.Stop, /rpc/Slide.Calibrate.  pos 0 = fully open, 1 = fully closed.
-- API v2 (firmware from Aug 2023): no authentication.
-- API v1 (older firmware): HTTP Digest, user "user", password = 8-char device code.
local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local json = require "st.json"
local log = require "log"
local md5 = require "md5"

local M = {}
M.TIMEOUT = 5

-- cached Digest challenges per IP (API v1 only)
local challenges = {}

local function parse_challenge(h)
  local t = {}
  for k, v in h:gmatch('([%w%-]+)="([^"]*)"') do t[k:lower()] = v end
  for k, v in h:gmatch('([%w%-]+)=([^",%s]+)') do
    if t[k:lower()] == nil then t[k:lower()] = v end
  end
  return t
end

local function digest_header(ch, code, method, uri)
  local user = "user"
  local nc = "00000001"
  local cnonce = string.format("%08x", math.random(0, 0x7fffffff))
  local ha1 = md5.sumhexa(user .. ":" .. (ch.realm or "") .. ":" .. code)
  local ha2 = md5.sumhexa(method .. ":" .. uri)
  local use_qop = ch.qop and ch.qop:find("auth") ~= nil
  local response
  if use_qop then
    response = md5.sumhexa(ha1 .. ":" .. ch.nonce .. ":" .. nc .. ":" .. cnonce .. ":auth:" .. ha2)
  else
    response = md5.sumhexa(ha1 .. ":" .. ch.nonce .. ":" .. ha2)
  end
  local parts = {
    'username="' .. user .. '"',
    'realm="' .. (ch.realm or "") .. '"',
    'nonce="' .. ch.nonce .. '"',
    'uri="' .. uri .. '"',
    'response="' .. response .. '"',
  }
  if use_qop then
    table.insert(parts, "qop=auth")
    table.insert(parts, "nc=" .. nc)
    table.insert(parts, 'cnonce="' .. cnonce .. '"')
  end
  if ch.opaque then table.insert(parts, 'opaque="' .. ch.opaque .. '"') end
  if ch.algorithm then table.insert(parts, "algorithm=" .. ch.algorithm) end
  return "Digest " .. table.concat(parts, ", ")
end

local function raw_post(ip, path, body, auth, timeout)
  local chunks = {}
  local headers = {
    ["Content-Type"] = "application/json",
    ["Content-Length"] = tostring(#body),
  }
  if auth then headers["Authorization"] = auth end
  http.TIMEOUT = timeout or M.TIMEOUT
  local ok, code, rheaders = http.request({
    url = "http://" .. ip .. path,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(body),
    sink = ltn12.sink.table(chunks),
  })
  if not ok then return nil, tostring(code) end
  return code, table.concat(chunks), rheaders or {}
end

local function header(h, name)
  name = name:lower()
  for k, v in pairs(h) do
    if tostring(k):lower() == name then return v end
  end
end

--- Call an RPC method. Returns decoded table, or nil + error string.
function M.rpc(ip, code, method_name, params)
  if not ip or ip == "" then return nil, "no IP address configured" end
  local path = "/rpc/" .. method_name
  local body = params and json.encode(params) or "{}"
  local auth = nil
  if code and challenges[ip] then
    auth = digest_header(challenges[ip], code, "POST", path)
  end
  local status, text, h = raw_post(ip, path, body, auth)
  if status == 401 then
    if not code then
      return nil, "Slide asks for authentication (API v1): set the device code in Settings"
    end
    local www = header(h, "www-authenticate")
    if not www then return nil, "401 without Digest challenge" end
    challenges[ip] = parse_challenge(www)
    status, text, h = raw_post(ip, path, body, digest_header(challenges[ip], code, "POST", path))
  end
  if not status then return nil, text end
  if status ~= 200 then return nil, "HTTP " .. tostring(status) .. " " .. tostring(text) end
  local ok, data = pcall(json.decode, text)
  if not ok or type(data) ~= "table" then return nil, "unexpected reply: " .. tostring(text) end
  return data
end

function M.get_info(ip, code) return M.rpc(ip, code, "Slide.GetInfo") end

--- Discovery probe: returns the GetInfo table when `ip` is a Slide (API v2),
--- a table { needs_code = true } for an API v1 Slide, or nil for anything else.
function M.probe(ip, timeout)
  local status, text, h = raw_post(ip, "/rpc/Slide.GetInfo", "{}", nil, timeout or 2)
  if status == 200 then
    local ok, data = pcall(json.decode, text)
    if ok and type(data) == "table" and (data.slide_id or data.mac or data.pos) then return data end
  elseif status == 401 then
    local www = header(h, "www-authenticate") or ""
    if www:lower():find("digest") then return { needs_code = true } end
  end
  return nil
end

function M.set_pos(ip, code, pos)
  if pos < 0 then pos = 0 elseif pos > 1 then pos = 1 end
  return M.rpc(ip, code, "Slide.SetPos", { pos = pos })
end

function M.stop(ip, code) return M.rpc(ip, code, "Slide.Stop") end
function M.calibrate(ip, code) return M.rpc(ip, code, "Slide.Calibrate") end

return M
