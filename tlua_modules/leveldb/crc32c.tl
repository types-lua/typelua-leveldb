--- CRC32C (Castagnoli, reflected polynomial 0x82F63B78).
---
--- LevelDB stamps every log record and table block with this checksum, so
--- files from the reference implementation and ours agree byte for byte.
--- A 256-entry table plus 32-bit modulo arithmetic keeps it portable to
--- LuaJIT in 5.1-compatible mode (no bitwise operators).

local util = require("leveldb.util")

local POLY: number = 0x82F63B78
local TABLE: number[] = {}

for i: number = 0, 255 do
  local c: number = i
  for _: number = 1, 8 do
    if c % 2 == 1 then
      c = util.xor32(math.floor(c / 2), POLY)
    else
      c = math.floor(c / 2)
    end
  end
  TABLE[i + 1] = c
end

--- Extends a running CRC with the bytes of `s`.
--- Pass `crc` = 0 for a fresh checksum; chain calls for streaming.
--- The pre/post inversions match LevelDB's crc32c port, so values agree
--- with the reference implementation (standard CRC-32C check vector:
--- crc32c("123456789") = 0xe3069283).
local function extend(crc: number, s: string): number
  local c: number = util.not32(crc)
  local n: number = #s
  for i: number = 1, n do
    local byte: number = string.byte(s, i)
    -- reflected CRC: index = (c XOR byte) & 0xFF, then c = (c >> 8) XOR table[idx]
    local idx: number = util.xor32(c, byte) % 256
    c = util.xor32(math.floor(c / 256), TABLE[idx + 1])
  end
  return util.not32(c)
end

local function value(s: string): number
  return extend(0, s)
end

--- LevelDB stores masked CRCs so an all-zero payload is never valid:
--- ((crc >> 15) | (crc << 17)) + 0xa282ead8.
local function mask(crc: number): number
  local rotated: number = util.shiftRight(crc, 15) + util.shiftLeft(crc, 17)
  return util.mod32(rotated + 0xa282ead8)
end

local function unmask(masked: number): number
  local rot: number = util.mod32(masked - 0xa282ead8)
  return util.shiftRight(rot, 17) + util.shiftLeft(rot, 15)
end

return {
  extend = extend,
  value = value,
  mask = mask,
  unmask = unmask,
}
