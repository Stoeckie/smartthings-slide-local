-- Pure Lua 5.3 MD5 (needed for HTTP Digest auth on Slide API v1).
-- Edge hubs run Lua 5.3, which has native bitwise operators and string.pack.
local M = {}

local K = {}
for i = 0, 63 do
  K[i] = math.floor(math.abs(math.sin(i + 1)) * 4294967296) & 0xffffffff
end

local S = {
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local function lrot(x, c)
  x = x & 0xffffffff
  return ((x << c) | (x >> (32 - c))) & 0xffffffff
end

function M.sum(msg)
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) .. string.pack("<I8", len * 8)
  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  for chunk = 1, #msg, 64 do
    local W = { string.unpack("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", msg, chunk) }
    local A, B, C, D = a0, b0, c0, d0
    for i = 0, 63 do
      local F, g
      if i < 16 then
        F = (B & C) | ((~B) & D); g = i
      elseif i < 32 then
        F = (D & B) | ((~D) & C); g = (5 * i + 1) % 16
      elseif i < 48 then
        F = B ~ C ~ D; g = (3 * i + 5) % 16
      else
        F = C ~ (B | (~D)); g = (7 * i) % 16
      end
      F = (F + A + K[i] + W[g + 1]) & 0xffffffff
      A = D; D = C; C = B
      B = (B + lrot(F, S[i + 1])) & 0xffffffff
    end
    a0 = (a0 + A) & 0xffffffff
    b0 = (b0 + B) & 0xffffffff
    c0 = (c0 + C) & 0xffffffff
    d0 = (d0 + D) & 0xffffffff
  end
  return string.pack("<I4I4I4I4", a0, b0, c0, d0)
end

function M.sumhexa(msg)
  return (M.sum(msg):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

return M
