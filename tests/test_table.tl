--- Block, filter and SSTable tests.
---
--- The table round-trip exercises every byte of the format we emit: block
--- prefixes/restarts, filter block, metaindex, index and footer.

import T from "tlua_test"
local blockmod = require("leveldb.block")
local codec = require("leveldb.codec")
local filtermod = require("leveldb.filter")
local tablemod = require("leveldb.table")

type GetResult = { found: boolean, value: string }
type Lookup = { state: number, value: string }
type Parsed = { userKey: string, sequence: number, valueType: number }

local function makeKey(user: string, seq: number): string
  return codec.internalKey(user, seq, codec.TYPE_VALUE)
end

local function testBlock(): void
  local b = blockmod.BlockBuilder.new(4)
  -- 40 entries force several restarts (interval 4) and prefix sharing.
  for i: number = 1, 40 do
    local user: string = "key" .. string.format("%03d", i)
    b:add(makeKey(user, 1), "value" .. tostring(i))
  end
  local data: string = b:finish()
  local r = blockmod.Block.new(data, codec.compareInternal)

  local probe: GetResult = r:get(makeKey("key001", 1))
  T.eq(probe.found, true, "get first")
  T.eq(probe.value, "value1", "value first")
  local last: GetResult = r:get(makeKey("key040", 1))
  T.eq(last.value, "value40", "get last")
  local missing: GetResult = r:get(makeKey("key099", 1))
  T.eq(missing.found, false, "missing key")
  local between: GetResult = r:get(makeKey("key020a", 1))
  T.eq(between.found, false, "missing between keys")

  local it = r:iterator()
  it:seekToFirst()
  local count: number = 0
  local prev: string = ""
  while it:valid() do
    local parsed: Parsed = codec.parseInternalKey(it:key())
    if count > 0 then
      T.ok(prev < parsed.userKey, "block iteration order")
    end
    prev = parsed.userKey
    count = count + 1
    it:next()
  end
  T.eq(count, 40, "block entry count")

  -- Seeking into the middle must land on the first key >= target.
  it:seek(makeKey("key017", 1))
  T.eq(it:key(), makeKey("key017", 1), "seek exact")
  it:seek(makeKey("key017a", 1))
  local nextParsed: Parsed = codec.parseInternalKey(it:key())
  T.eq(nextParsed.userKey, "key018", "seek lands on next key")

  local empty = blockmod.BlockBuilder.new(4)
  local emptyData: string = empty:finish()
  local emptyBlock = blockmod.Block.new(emptyData, codec.compareInternal)
  local emptyIt = emptyBlock:iterator()
  emptyIt:seekToFirst()
  T.eq(emptyIt:valid(), false, "empty block iterator")
  T.eq(emptyBlock:get(makeKey("x", 1)).found, false, "empty block get")
end

local function testFilter(): void
  local fb = filtermod.FilterBlockBuilder.new(10)
  fb:startBlock(0)
  fb:addKey("alpha")
  fb:addKey("beta")
  -- Jump two slots: the gap must be filled with empty filters.
  fb:startBlock(4096)
  fb:addKey("gamma")
  local contents: string = fb:finish()
  local reader = filtermod.FilterBlock.new(contents)

  T.ok(reader:mayMatch(0, "alpha"), "slot 0 has alpha")
  T.ok(reader:mayMatch(0, "beta"), "slot 0 has beta")
  T.ok(not reader:mayMatch(0, "gamma"), "gamma not in slot 0")
  T.ok(reader:mayMatch(4096, "gamma"), "slot 2 has gamma")
  T.ok(not reader:mayMatch(4096, "alpha"), "alpha not in slot 2")
  T.ok(reader:mayMatch(8192, "anything"), "slot beyond filters may match")

  local empty = filtermod.FilterBlockBuilder.new(10)
  T.eq(empty:finish(), "", "empty builder yields empty block")
  local emptyReader = filtermod.FilterBlock.new("")
  T.ok(emptyReader:mayMatch(0, "x"), "empty filter may match")
end

local function testTable(): void
  local opts = tablemod.defaultTableOptions()
  opts.blockSize = 512
  opts.blockRestartInterval = 4
  local builder = tablemod.TableBuilder.new(opts)

  local expected: string[] = {}
  for i: number = 1, 200 do
    local user: string = string.format("user%04d", i)
    builder:add(makeKey(user, 1), "payload-" .. tostring(i))
    expected[#expected + 1] = user
  end
  local data: string = builder:finish()
  T.ok(#data > 0, "table bytes")
  T.eq(builder:size(), #data, "builder size equals output")

  local reader = tablemod.TableReader.new(data, tablemod.defaultReaderOptions())
  local hit: Lookup = reader:get("user0001", 1)
  T.eq(hit.state, tablemod.FOUND, "table get first state")
  T.eq(hit.value, "payload-1", "table get first value")
  local miss: Lookup = reader:get("user0001a", 1)
  T.eq(miss.state, tablemod.MISSING, "table missing key")

  local it = reader:iterator()
  it:seekToFirst()
  local n: number = 0
  while it:valid() do
    local parsed: Parsed = codec.parseInternalKey(it:key())
    T.eq(parsed.userKey, expected[n + 1], "table iteration entry " .. tostring(n + 1))
    n = n + 1
    it:next()
  end
  T.eq(n, 200, "table entry count")

  it:seek(makeKey("user0100", 1))
  T.eq(codec.parseInternalKey(it:key()).userKey, "user0100", "table seek exact")
  it:seek(makeKey("user0100a", 1))
  T.eq(codec.parseInternalKey(it:key()).userKey, "user0101", "table seek next")

  -- Snapshot semantics: a newer value shadows an older one.
  local b2 = tablemod.TableBuilder.new(opts)
  b2:add(codec.internalKey("k", 7, codec.TYPE_DELETION), "")
  b2:add(codec.internalKey("k", 5, codec.TYPE_VALUE), "new")
  b2:add(codec.internalKey("k", 3, codec.TYPE_VALUE), "old")
  local r2 = tablemod.TableReader.new(b2:finish(), tablemod.defaultReaderOptions())
  T.eq(r2:get("k", 3).value, "old", "snapshot reads older value")
  T.eq(r2:get("k", 5).value, "new", "snapshot reads newer value")
  T.eq(r2:get("k", 7).state, tablemod.DELETED, "deletion visible at seq 7")
  T.eq(r2:get("k", 6).value, "new", "tombstone not yet visible")

  -- Integrity: a flipped byte must be caught by the block checksum.
  local corrupted: string = string.sub(data, 1, 100) .. "Z" .. string.sub(data, 102)
  local okRead: boolean = pcall(function(): void
    local r = tablemod.TableReader.new(corrupted, tablemod.defaultReaderOptions())
    local scan = r:iterator()
    scan:seekToFirst()
    while scan:valid() do
      local _ = scan:value()
      scan:next()
    end
  end)
  T.eq(okRead, false, "corrupted table rejected on read")

  -- Bad magic.
  local badMagic: string = string.sub(data, 1, #data - 8) .. "00000000"
  local okMagic: boolean = pcall(function(): void
    local _ = tablemod.TableReader.new(badMagic, tablemod.defaultReaderOptions())
  end)
  T.eq(okMagic, false, "bad magic rejected")
end

return {
  ["data blocks"] = testBlock,
  ["filter block"] = testFilter,
  ["sstable roundtrip"] = testTable,
}
