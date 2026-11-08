--- Shared low-level utilities: integer helpers, 32-bit XOR and
--- little-endian packing.
---
--- Everything here is Lua 5.1 safe on purpose (no `//`, no bitwise
--- operators, no `string.pack`), so the library runs on PUC Lua 5.4,
--- LuaJIT and golua unchanged. Values stay below 2^53 where doubles would
--- lose precision; the only 64-bit numbers on disk are sequence numbers,
--- which real workloads keep far below that line.

local MAX_SEQUENCE: number = 9007199254740991 -- 2^53-1
local TWO32: number = 4294967296
local MASK32: number = 4294967295

--- floor(a / b) for non-negative integers (LuaJIT has no `//`).
local function idiv(a: number, b: number): number
  return math.floor(a / b)
end

local function mod32(x: number): number
  return x - math.floor(x / TWO32) * TWO32
end

local function shiftRight(x: number, bits: number): number
  return idiv(x, 2 ^ bits)
end

--- Exact 32-bit multiply: LuaJIT doubles lose precision above 2^53, so the
--- operand is split into 16-bit halves before multiplying.
local function mul32(a: number, b: number): number
  local x: number = mod32(a)
  local y: number = mod32(b)
  local xHi: number = math.floor(x / 65536)
  local xLo: number = x - xHi * 65536
  local lo: number = mod32(xLo * y)
  local hi: number = mod32(xHi * y)
  return mod32(lo + mod32(hi * 65536))
end

local function shiftLeft(x: number, bits: number): number
  return mul32(x, 2 ^ bits)
end

--- 32-bit XOR via eight nibble lookups. No bitwise operators, so this also
--- runs on 5.1-compatible targets. Used by CRC table generation and the
--- bloom hash.
local XOR_NIBBLE: number[] = {}
for a: number = 0, 15 do
  for b: number = 0, 15 do
    local x: number = 0
    local place: number = 1
    local av: number = a
    local bv: number = b
    for _: number = 1, 4 do
      x = x + ((av % 2 + bv % 2) % 2) * place
      av = math.floor(av / 2)
      bv = math.floor(bv / 2)
      place = place * 2
    end
    XOR_NIBBLE[a * 16 + b] = x
  end
end

local function xor32(a: number, b: number): number
  local result: number = 0
  local place: number = 1
  local x: number = mod32(a)
  local y: number = mod32(b)
  for _: number = 1, 8 do
    result = result + XOR_NIBBLE[(x % 16) * 16 + (y % 16)] * place
    x = math.floor(x / 16)
    y = math.floor(y / 16)
    place = place * 16
  end
  return result
end

--- Bitwise complement in 32 bits (a XOR 0xFFFFFFFF).
local function not32(x: number): number
  return MASK32 - mod32(x)
end

--- Little-endian u16 (log record lengths).
local function putFixed16(x: number): string
  local v: number = mod32(x)
  return string.char(v % 256, idiv(v, 256) % 256)
end

local function decodeFixed16(s: string, pos: number): number
  local b1: number = string.byte(s, pos)
  local b2: number = string.byte(s, pos + 1)
  return b1 + b2 * 256
end

--- Little-endian u32. Returns 4 raw bytes.
local function putFixed32(x: number): string
  local v: number = mod32(x)
  local b1: number = v % 256
  local b2: number = idiv(v, 256) % 256
  local b3: number = idiv(v, 65536) % 256
  local b4: number = idiv(v, 16777216) % 256
  return string.char(b1, b2, b3, b4)
end

--- Little-endian u64 for values <= 2^53-1 (enough for sequence numbers).
local function putFixed64(x: number): string
  local lo: number = mod32(x)
  local hi: number = math.floor(x / TWO32) % TWO32
  return putFixed32(lo) .. putFixed32(hi)
end

--- Decodes a little-endian u32 at byte offset `pos` (1-based).
local function decodeFixed32(s: string, pos: number): number
  local b1: number = string.byte(s, pos)
  local b2: number = string.byte(s, pos + 1)
  local b3: number = string.byte(s, pos + 2)
  local b4: number = string.byte(s, pos + 3)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function decodeFixed64(s: string, pos: number): number
  local lo: number = decodeFixed32(s, pos)
  local hi: number = decodeFixed32(s, pos + 4)
  return hi * TWO32 + lo
end

local function min(a: number, b: number): number
  if a < b then return a end
  return b
end

local function max(a: number, b: number): number
  if a > b then return a end
  return b
end

--- Bytewise (unsigned) comparison, exactly LevelDB's default order.
local function compareBytes(a: string, b: string): number
  if a < b then return -1 end
  if a > b then return 1 end
  return 0
end

local function hasPrefix(s: string, prefix: string): boolean
  if #prefix > #s then return false end
  return string.sub(s, 1, #prefix) == prefix
end

return {
  MAX_SEQUENCE = MAX_SEQUENCE,
  TWO32 = TWO32,
  MASK32 = MASK32,
  idiv = idiv,
  mod32 = mod32,
  shiftRight = shiftRight,
  shiftLeft = shiftLeft,
  mul32 = mul32,
  xor32 = xor32,
  not32 = not32,
  putFixed32 = putFixed32,
  putFixed64 = putFixed64,
  putFixed16 = putFixed16,
  decodeFixed32 = decodeFixed32,
  decodeFixed64 = decodeFixed64,
  decodeFixed16 = decodeFixed16,
  min = min,
  max = max,
  compareBytes = compareBytes,
  hasPrefix = hasPrefix,
}
