--- SSTable data blocks: prefix-compressed entries with restart points.
---
--- Layout (same bytes as LevelDB):
---   entry*      : varint shared, varint nonShared, varint valueLen,
---                 keyDelta[nonShared], value[valueLen]
---   restarts    : fixed32 offset* (entry positions with shared=0)
---   restartCount: fixed32
---
--- Keys inside one restart interval share a prefix with the previous key.
--- Restart points reset the prefix so binary search can start mid-block.

local codec = require("leveldb_codec")
local util = require("leveldb_util")

local DEFAULT_RESTART_INTERVAL: number = 16

type VarintResult = {
  value: number,
  pos: number,
  ok: boolean,
}

--- Comparator contract shared by every block reader: negative/zero/positive.
type Compare = (a: string, b: string) -> number

type Entry = {
  shared: number,
  nonShared: number,
  valueLen: number,
  keyDeltaPos: number,
  valuePos: number,
  nextPos: number,
}

local function decodeEntry(data: string, pos: number): Entry
  local a: VarintResult = codec.readVarint(data, pos)
  if not a.ok then error("block: truncated shared length") end
  local b: VarintResult = codec.readVarint(data, a.pos)
  if not b.ok then error("block: truncated key length") end
  local c: VarintResult = codec.readVarint(data, b.pos)
  if not c.ok then error("block: truncated value length") end
  local keyStart: number = c.pos
  local keyEnd: number = keyStart + b.value - 1
  local valueStart: number = keyEnd + 1
  local valueEnd: number = valueStart + c.value - 1
  if valueEnd > #data then error("block: truncated entry body") end
  return {
    shared = a.value,
    nonShared = b.value,
    valueLen = c.value,
    keyDeltaPos = keyStart,
    valuePos = valueStart,
    nextPos = valueEnd + 1,
  }
end

local function restartCount(data: string): number
  if #data < 8 then return 0 end
  local count: number = util.decodeFixed32(data, #data - 3)
  local entriesEnd: number = #data - 4 - count * 4
  if entriesEnd < 0 then return 0 end
  return count
end

local function restartOffset(data: string, index: number): number
  local count: number = restartCount(data)
  local base: number = #data - 4 - count * 4
  return util.decodeFixed32(data, base + index * 4 + 1)
end

--- Key stored at a restart point (shared == 0, so it is self-contained).
local function keyAtRestart(data: string, index: number): string
  local pos: number = restartOffset(data, index) + 1
  local entry: Entry = decodeEntry(data, pos)
  return string.sub(data, entry.keyDeltaPos, entry.keyDeltaPos + entry.nonShared - 1)
end

class BlockBuilder {
  buffer: string[],
  restarts: number[],
  counter: number,
  lastKey: string,
  restartInterval: number,
  size: number,

  constructor(restartInterval: number)
    self.buffer = {}
    -- LevelDB always records offset 0 as the first restart point; without
    -- it a seek below the first periodic restart loses the whole prefix.
    self.restarts = {0}
    self.counter = 0
    self.lastKey = ""
    self.restartInterval = restartInterval
    self.size = 0
  end,

  reset(): void
    self.buffer = {}
    self.restarts = {0}
    self.counter = 0
    self.lastKey = ""
    self.size = 0
  end,

  isEmpty(): boolean
    return #self.buffer == 0
  end,

  currentSizeEstimate(): number
    return self.size + #self.restarts * 4 + 4
  end,

  add(key: string, value: string): void
    local shared: number = 0
    if self.counter < self.restartInterval then
      local maxShared: number = util.min(#self.lastKey, #key)
      while shared < maxShared do
        if string.byte(self.lastKey, shared + 1) ~= string.byte(key, shared + 1) then
          break
        end
        shared = shared + 1
      end
    else
      table.insert(self.restarts, self.size)
      self.counter = 0
    end

    local nonShared: number = #key - shared
    local head: string = codec.varint(shared) .. codec.varint(nonShared) .. codec.varint(#value)
    local out: string[] = self.buffer
    out[#out + 1] = head
    out[#out + 1] = string.sub(key, shared + 1)
    out[#out + 1] = value
    -- Restart offsets are absolute byte positions: count the real varint
    -- widths instead of assuming one byte each.
    self.size = self.size + #head + nonShared + #value
    self.lastKey = key
    self.counter = self.counter + 1
  end,

  finish(): string
    if #self.restarts == 0 then
      table.insert(self.restarts, 0)
    end
    local out: string[] = self.buffer
    for i: number = 1, #self.restarts do
      out[#out + 1] = util.putFixed32(self.restarts[i])
    end
    out[#out + 1] = util.putFixed32(#self.restarts)
    return table.concat(out)
  end,
}

type GetResult = {
  found: boolean,
  value: string,
}

class BlockIterator {
  data: string,
  restarts: number,
  pos: number,
  alive: boolean,
  keyBuf: string,
  valueBuf: string,
  cmp: Compare,

  constructor(data: string, cmp: Compare)
    self.data = data
    self.restarts = restartCount(data)
    self.pos = 0
    self.alive = false
    self.keyBuf = ""
    self.valueBuf = ""
    self.cmp = cmp
  end,

  --- Decodes the entry at self.pos; caller guarantees bounds.
  loadAt(pos: number): void
    local entry: Entry = decodeEntry(self.data, pos)
    local delta: string = string.sub(self.data, entry.keyDeltaPos, entry.keyDeltaPos + entry.nonShared - 1)
    self.keyBuf = string.sub(self.keyBuf, 1, entry.shared) .. delta
    self.valueBuf = string.sub(self.data, entry.valuePos, entry.valuePos + entry.valueLen - 1)
    self.pos = entry.nextPos
    self.alive = true
  end,

  valid(): boolean
    return self.alive
  end,

  --- Byte count of the entry region (restart array and count excluded).
  entriesLimit(): number
    return #self.data - 4 - self.restarts * 4
  end,

  seekToFirst(): void
    if self.restarts == 0 or self:entriesLimit() <= 0 then
      self.alive = false
      return
    end
    self.keyBuf = ""
    self:loadAt(1)
  end,

  seek(target: string): void
    if self.restarts == 0 then
      self.alive = false
      return
    end
    -- Binary search over restart points for the last one <= target.
    local left: number = 0
    local right: number = self.restarts - 1
    local chosen: number = 0
    while left <= right do
      local mid: number = math.floor((left + right) / 2)
      local midKey: string = keyAtRestart(self.data, mid)
      local order: number = self.cmp(midKey, target)
      if order < 0 then
        chosen = mid
        left = mid + 1
      elseif order > 0 then
        right = mid - 1
      else
        chosen = mid
        break
      end
    end

    if self:entriesLimit() <= 0 then
      self.alive = false
      return
    end
    self.keyBuf = ""
    self:loadAt(restartOffset(self.data, chosen) + 1)
    while self.alive and self.cmp(self.keyBuf, target) < 0 do
      self:next()
    end
  end,

  next(): void
    if not self.alive then return end
    if self.pos > self:entriesLimit() then
      self.alive = false
      return
    end
    self:loadAt(self.pos)
  end,

  key(): string
    return self.keyBuf
  end,

  value(): string
    return self.valueBuf
  end,
}

class Block {
  data: string,
  cmp: Compare,

  constructor(data: string, cmp: Compare)
    self.data = data
    self.cmp = cmp
  end,

  size(): number
    return #self.data
  end,

  iterator(): BlockIterator
    return BlockIterator.new(self.data, self.cmp)
  end,

  --- Point lookup: binary search via restarts, then a short linear scan.
  get(target: string): GetResult
    local it: BlockIterator = BlockIterator.new(self.data, self.cmp)
    it:seek(target)
    if not it:valid() then
      return { found = false, value = "" }
    end
    if self.cmp(it:key(), target) ~= 0 then
      return { found = false, value = "" }
    end
    return { found = true, value = it:value() }
  end,
}

return {
  Block = Block,
  BlockBuilder = BlockBuilder,
  BlockIterator = BlockIterator,
  DEFAULT_RESTART_INTERVAL = DEFAULT_RESTART_INTERVAL,
  decodeEntry = decodeEntry,
  restartCount = restartCount,
}
