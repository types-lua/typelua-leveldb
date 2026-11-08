--- In-memory sorted table (LevelDB's MemTable) backed by a skip list.
---
--- Keys are internal keys (user key + sequence/type tag), so one user key
--- can coexist at many sequence numbers while iterating newest-first.
--- The skip list uses a deterministic xorshift PRNG: runs are reproducible,
--- which matters for tests and for byte-identical compactions.
---
--- Values live as Lua strings; `bytesUsed` approximates memory so the DB can
--- rotate tables at `writeBufferSize`, like the reference implementation.

local codec = require("leveldb.codec")
local util = require("leveldb.util")

type Node = {
  key: string,
  value: string,
  next: (Node | nil)[],
}

local DEFAULT_SEED: number = 0x9e3779b9
local BRANCHING: number = 4
local DEFAULT_HEIGHT: number = 12

--- Lookup states: distinguish "absent" from "deleted at this snapshot".
local MISSING: number = 0
local FOUND: number = 1
local DELETED: number = 2

type LookupResult = {
  value: string,
  state: number,
}

type ParsedKey = {
  userKey: string,
  sequence: number,
  valueType: number,
}

class SkipList {
  head: Node,
  height: number,
  rand: number,

  constructor()
    local nexts: (Node | nil)[] = {}
    for i: number = 1, DEFAULT_HEIGHT do nexts[i] = nil end
    self.head = { key = "", value = "", next = nexts }
    self.height = 1
    self.rand = DEFAULT_SEED
  end,

  --- xorshift32; stays in 32 bits so LuaJIT doubles keep exact integers.
  nextRandom(): number
    local x: number = self.rand
    x = util.xor32(x, util.shiftLeft(x, 13))
    x = util.xor32(x, util.shiftRight(x, 17))
    x = util.xor32(x, util.shiftLeft(x, 5))
    self.rand = x
    return x
  end,

  randomHeight(): number
    local h: number = 1
    while h < DEFAULT_HEIGHT and self:nextRandom() % BRANCHING == 0 do
      h = h + 1
    end
    return h
  end,

  add(key: string, value: string): void
    local prev: (Node | nil)[] = {}
    local x: Node = self.head
    local level: number = self.height
    while level >= 1 do
      local nextNode: Node | nil = x.next[level]
      while nextNode ~= nil do
        local probe: Node = nextNode
        if codec.compareInternal(probe.key, key) >= 0 then break end
        x = probe
        nextNode = x.next[level]
      end
      prev[level] = x
      level = level - 1
    end

    local height: number = self:randomHeight()
    if height > self.height then
      local extra: number = self.height + 1
      while extra <= height do
        prev[extra] = self.head
        extra = extra + 1
      end
      self.height = height
    end

    local nexts: (Node | nil)[] = {}
    for i: number = 1, height do nexts[i] = nil end
    local node: Node = { key = key, value = value, next = nexts }
    local i: number = 1
    while i <= height do
      local p: Node | nil = prev[i]
      if p ~= nil then
        node.next[i] = p.next[i]
        p.next[i] = node
      end
      i = i + 1
    end
  end,

  --- First node with key >= target (the read path's lower bound).
  seek(key: string): Node | nil
    local x: Node = self.head
    local level: number = self.height
    while level >= 1 do
      local nextNode: Node | nil = x.next[level]
      while nextNode ~= nil do
        local probe: Node = nextNode
        if codec.compareInternal(probe.key, key) >= 0 then break end
        x = probe
        nextNode = x.next[level]
      end
      level = level - 1
    end
    return x.next[1]
  end,

  first(): Node | nil
    return self.head.next[1]
  end,
}

--- Iterator over a skip list snapshot. The list must not be mutated while
--- the iterator is live (single-writer DB invariant).
class MemIterator {
  list: SkipList,
  node: Node | nil,

  constructor(list: SkipList)
    self.list = list
    self.node = nil
  end,

  valid(): boolean
    return self.node ~= nil
  end,

  seekToFirst(): void
    self.node = self.list:first()
  end,

  seek(target: string): void
    self.node = self.list:seek(target)
  end,

  next(): void
    local current: Node | nil = self.node
    if current == nil then return end
    self.node = current.next[1]
  end,

  key(): string
    local current: Node | nil = self.node
    if current == nil then return "" end
    return current.key
  end,

  value(): string
    local current: Node | nil = self.node
    if current == nil then return "" end
    return current.value
  end,
}

class MemTable {
  list: SkipList,
  bytesUsed: number,
  entryCount: number,

  constructor()
    self.list = SkipList.new()
    self.bytesUsed = 0
    self.entryCount = 0
  end,

  add(sequence: number, valueType: number, userKey: string, value: string): void
    local ikey: string = codec.internalKey(userKey, sequence, valueType)
    self.list:add(ikey, value)
    -- Approximation used only for the rotation threshold.
    self.bytesUsed = self.bytesUsed + #ikey + #value + 32
    self.entryCount = self.entryCount + 1
  end,

  --- Looks up `userKey` at `snapshot` (sequence <= snapshot is visible).
  get(userKey: string, snapshot: number): LookupResult
    local probe: string = codec.internalKey(userKey, snapshot, codec.TYPE_VALUE)
    local node: Node | nil = self.list:seek(probe)
    if node == nil then
      return { value = "", state = MISSING }
    end
    local parsed: ParsedKey = codec.parseInternalKey(node.key)
    if parsed.userKey ~= userKey then
      return { value = "", state = MISSING }
    end
    if parsed.valueType == codec.TYPE_DELETION then
      return { value = "", state = DELETED }
    end
    return { value = node.value, state = FOUND }
  end,

  approximateMemory(): number
    return self.bytesUsed
  end,

  count(): number
    return self.entryCount
  end,

  iterator(): MemIterator
    return MemIterator.new(self.list)
  end,
}

return {
  MemTable = MemTable,
  MemIterator = MemIterator,
  MISSING = MISSING,
  FOUND = FOUND,
  DELETED = DELETED,
  DEFAULT_HEIGHT = DEFAULT_HEIGHT,
}
