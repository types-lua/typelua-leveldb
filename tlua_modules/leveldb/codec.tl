--- Wire encoding primitives: LEB128 varints, length-prefixed slices and
--- LevelDB's internal-key layout.
---
--- Formats follow the reference implementation byte for byte:
---   varint32/64 : LEB128, 7 bits per byte, high bit = continuation
---   internal key: user_key || fixed64((sequence << 8) | value_type)
--- so sequence numbers sort descending inside one user key.

local util = require("leveldb.util")

local TYPE_DELETION: number = 0
local TYPE_VALUE: number = 1

--- Appends the LEB128 encoding of a non-negative integer to `out`.
local function putVarint(out: string[], value: number): void
  local v: number = value
  while v >= 128 do
    local b: number = v % 128
    out[#out + 1] = string.char(b + 128)
    v = math.floor(v / 128)
  end
  out[#out + 1] = string.char(v)
end

local function varint(value: number): string
  local out: string[] = {}
  putVarint(out, value)
  return table.concat(out)
end

--- Decodes a varint from `s` starting at 1-based `pos`.
--- Returns (value, nextPos). Raises a plain string error on truncation;
--- callers translate that into a corruption diagnostic.
local function getVarint(s: string, pos: number): (number, number)
  local result: number = 0
  local shift: number = 1
  local i: number = pos
  while true do
    local raw: number | nil = string.byte(s, i)
    if raw == nil then
      error("truncated varint")
    end
    local byte: number = raw!
    result = result + (byte % 128) * shift
    if byte < 128 then
      return result, i + 1
    end
    shift = shift * 128
    i = i + 1
    if i - pos > 9 then
      error("varint too long")
    end
  end
end

--- Encodes `s` with a varint length prefix (LevelDB slice format).
local function putLengthPrefixed(out: string[], s: string): void
  putVarint(out, #s)
  out[#out + 1] = s
end

local function lengthPrefixed(s: string): string
  local out: string[] = {}
  putLengthPrefixed(out, s)
  return table.concat(out)
end

--- Decodes a length-prefixed slice at `pos`. Returns (slice, nextPos).
local function getLengthPrefixed(s: string, pos: number): (string, number)
  local n, p = getVarint(s, pos)
  local last: number = p + n - 1
  if last > #s then
    error("truncated length-prefixed slice")
  end
  return string.sub(s, p, last), last + 1
end

type VarintResult = {
  value: number,
  pos: number,
  ok: boolean,
}

--- Non-throwing varint reader for parsers that must report corruption
--- instead of raising.
local function readVarint(s: string, pos: number): VarintResult
  local result: number = 0
  local shift: number = 1
  local i: number = pos
  while i - pos <= 9 do
    local byte: number | nil = string.byte(s, i)
    if byte == nil then
      return { value = 0, pos = pos, ok = false }
    end
    result = result + (byte % 128) * shift
    if byte < 128 then
      return { value = result, pos = i + 1, ok = true }
    end
    shift = shift * 128
    i = i + 1
  end
  return { value = 0, pos = pos, ok = false }
end

type SliceResult = {
  value: string,
  pos: number,
  ok: boolean,
}

--- Non-throwing length-prefixed reader.
local function readLengthPrefixed(s: string, pos: number): SliceResult
  local vr: VarintResult = readVarint(s, pos)
  if not vr.ok then
    return { value = "", pos = pos, ok = false }
  end
  local last: number = vr.pos + vr.value - 1
  if last > #s then
    return { value = "", pos = pos, ok = false }
  end
  return { value = string.sub(s, vr.pos, last), pos = last + 1, ok = true }
end

--- Packs an internal key. `sequence` must fit in 56 bits.
local function internalKey(userKey: string, sequence: number, valueType: number): string
  local tag: number = sequence * 256 + valueType
  return userKey .. util.putFixed64(tag)
end

type ParsedKey = {
  userKey: string,
  sequence: number,
  valueType: number,
}

--- Splits an internal key. Returns a record: cross-module calls carry one
--- value, which keeps multi-return typing out of every boundary.
local function parseInternalKey(ikey: string): ParsedKey
  if #ikey < 8 then
    error("internal key shorter than 8 bytes")
  end
  local userKey: string = string.sub(ikey, 1, #ikey - 8)
  local tag: number = util.decodeFixed64(ikey, #ikey - 7)
  return {
    userKey = userKey,
    sequence = math.floor(tag / 256),
    valueType = tag % 256,
  }
end

--- Comparator for internal keys: user key ascending, newer sequence first.
local function compareInternal(a: string, b: string): number
  local aUser: string = string.sub(a, 1, #a - 8)
  local bUser: string = string.sub(b, 1, #b - 8)
  if aUser < bUser then return -1 end
  if aUser > bUser then return 1 end
  local aTag: number = util.decodeFixed64(a, #a - 7)
  local bTag: number = util.decodeFixed64(b, #b - 7)
  if aTag > bTag then return -1 end
  if aTag < bTag then return 1 end
  return 0
end

--- True when `ikey` is a deletion marker for its user key.
local function isDeletion(ikey: string): boolean
  local tag: number = util.decodeFixed64(ikey, #ikey - 7)
  return tag % 256 == TYPE_DELETION
end

local function tagSequence(tag: number): number
  return math.floor(tag / 256)
end

local function tagType(tag: number): number
  return tag % 256
end

return {
  TYPE_DELETION = TYPE_DELETION,
  TYPE_VALUE = TYPE_VALUE,
  putVarint = putVarint,
  varint = varint,
  getVarint = getVarint,
  putLengthPrefixed = putLengthPrefixed,
  lengthPrefixed = lengthPrefixed,
  getLengthPrefixed = getLengthPrefixed,
  readVarint = readVarint,
  readLengthPrefixed = readLengthPrefixed,
  internalKey = internalKey,
  parseInternalKey = parseInternalKey,
  compareInternal = compareInternal,
  isDeletion = isDeletion,
  tagSequence = tagSequence,
  tagType = tagType,
}
