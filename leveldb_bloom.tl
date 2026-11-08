--- Bloom filter policy compatible with LevelDB's `BloomFilterPolicy`.
---
--- Layout (the filter block stores these back to back): bit array bytes,
--- then one byte holding the probe count `k`. Hash is LevelDB's
--- `util::Hash` (MurmurHash2 variant) with seed 0xbc9f1d34, so filters are
--- interchangeable with the reference implementation.
---
--- XOR comes from `leveldb.util` (nibble table, no bitwise operators), so
--- the module also runs on 5.1-compatible targets.

import util from "./leveldb_util"

local function rotl32(x: number, bits: number): number
  local v: number = util.mod32(x)
  return util.mod32(util.shiftLeft(v, bits) + util.shiftRight(v, 32 - bits))
end

--- LevelDB `util::Hash` (MurmurHash2 variant, seed 0xbc9f1d34).
local function hash(s: string): number
  local seed: number = 0xbc9f1d34
  local m: number = 0xc6a4a793
  local h: number = util.xor32(seed, util.mul32(#s, m))
  local n: number = #s
  local i: number = 1
  while n - i + 1 >= 4 do
    local w: number = util.decodeFixed32(s, i)
    h = util.mod32(h + w)
    h = util.mul32(h, m)
    h = util.xor32(h, util.shiftRight(h, 16))
    i = i + 4
  end
  local rest: number = n - i + 1
  if rest > 0 then
    if rest == 3 then
      h = util.mod32(h + string.byte(s, i + 2) * 65536)
    end
    if rest >= 2 then
      h = util.mod32(h + string.byte(s, i + 1) * 256)
    end
    h = util.mod32(h + string.byte(s, i))
    h = util.mul32(h, m)
    h = util.xor32(h, util.shiftRight(h, 24))
  end
  return h
end

--- Number of probes for a bits-per-key budget (0.69 = ln 2).
local function probesFor(bitsPerKey: number): number
  local k: number = math.floor(bitsPerKey * 0.69)
  if k < 1 then k = 1 end
  if k > 30 then k = 30 end
  return k
end

--- Builds a filter over `keys`. Returns "" for an empty list (LevelDB reads
--- a missing filter as "may match", never as "absent").
local function create(keys: string[], bitsPerKey: number): string
  local n: number = #keys
  if n == 0 then return "" end
  local k: number = probesFor(bitsPerKey)
  local bits: number = n * bitsPerKey
  if bits < 64 then bits = 64 end
  local bytes: number = util.idiv(bits + 7, 8)
  -- Round up to a byte boundary exactly like LevelDB: the reader derives
  -- `bits` from the stored byte count, so an un-rounded value here would
  -- shift every probe and produce false negatives.
  bits = bytes * 8
  local arr: number[] = {}
  for i: number = 1, bytes do arr[i] = 0 end

  for ki: number = 1, n do
    local h: number = hash(keys[ki])
    local delta: number = rotl32(h, 17)
    for _: number = 1, k do
      local bitpos: number = h % bits
      local idx: number = util.idiv(bitpos, 8) + 1
      local mask: number = 2 ^ (bitpos % 8)
      -- OR, not add: two probes may hit the same bit.
      if math.floor(arr[idx] / mask) % 2 == 0 then
        arr[idx] = arr[idx] + mask
      end
      h = util.mod32(h + delta)
    end
  end

  local chars: string[] = {}
  for i: number = 1, bytes do
    chars[i] = string.char(arr[i])
  end
  chars[#chars + 1] = string.char(k)
  return table.concat(chars)
end

--- False only when the key is definitely absent. True may be a false
--- positive (that is what a bloom filter trades for memory).
local function mayMatch(key: string, filter: string): boolean
  local len: number = #filter
  if len < 2 then return true end -- no filter recorded: be conservative
  local k: number = string.byte(filter, len)
  if k > 30 then return true end
  local bits: number = (len - 1) * 8
  local h: number = hash(key)
  local delta: number = rotl32(h, 17)
  for _: number = 1, k do
    local bitpos: number = h % bits
    local bytePos: number = util.idiv(bitpos, 8) + 1
    local bit: number = bitpos % 8
    local byte: number = string.byte(filter, bytePos)
    local mask: number = 2 ^ bit
    if math.floor(byte / mask) % 2 == 0 then
      return false
    end
    h = util.mod32(h + delta)
  end
  return true
end

return {
  hash = hash,
  probesFor = probesFor,
  create = create,
  mayMatch = mayMatch,
}
