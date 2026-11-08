--- MemTable, WriteBatch and WAL tests.

import T from "tlua_test"
import codec from "../leveldb_codec"
import memtable from "../leveldb_memtable"
import batchmod from "../leveldb_batch"
import log from "../leveldb_log"

type Lookup = { value: string, state: number }
type Parsed = { userKey: string, sequence: number, valueType: number }
type DecodeRes = { batch: any, sequence: number, err: any }
type ReadRes = { records: string[], err: any, truncated: number }

--- Park–Miller RNG: state * 48271 stays below 2^47, so LuaJIT doubles and
--- Lua 5.4 integers produce the identical stream (deterministic tests).
local function makeRng(seed: number): () -> number
  local state: number = seed % 2147483647
  if state == 0 then state = 1 end
  return function(): number
    state = (state * 48271) % 2147483647
    return state
  end
end

local function testMemTable(): void
  local m = memtable.MemTable.new()
  m:add(1, codec.TYPE_VALUE, "b", "b1")
  m:add(2, codec.TYPE_VALUE, "a", "a2")
  m:add(3, codec.TYPE_VALUE, "a", "a3")
  m:add(4, codec.TYPE_DELETION, "c", "")
  m:add(5, codec.TYPE_VALUE, "c", "c5")

  local r1: Lookup = m:get("a", 3)
  T.eq(r1.state, memtable.FOUND, "get a@3 state")
  T.eq(r1.value, "a3", "get a@3 newest")
  local r2: Lookup = m:get("a", 2)
  T.eq(r2.value, "a2", "get a@2 snapshot")
  local r3: Lookup = m:get("a", 1)
  T.eq(r3.state, memtable.MISSING, "get a@1 before insert")

  local rd: Lookup = m:get("c", 4)
  T.eq(rd.state, memtable.DELETED, "deletion wins at seq 4")
  local rc: Lookup = m:get("c", 5)
  T.eq(rc.value, "c5", "newer value revives key")

  -- Iteration must be user-key ascending, newest sequence first.
  local it = m:iterator()
  it:seekToFirst()
  local seen: string[] = {}
  while it:valid() do
    local parsed: Parsed = codec.parseInternalKey(it:key())
    seen[#seen + 1] = tostring(parsed.sequence) .. ":" .. parsed.userKey
    it:next()
  end
  T.eq(table.concat(seen, ","), "3:a,2:a,1:b,5:c,4:c", "iterator order")
  T.eq(m:count(), 5, "entry count")
  T.ok(m:approximateMemory() > 0, "memory accounting")
end

local function testMemTableRandom(): void
  local m = memtable.MemTable.new()
  local rng: () -> number = makeRng(42)
  local model: { [string]: string | nil } = {}
  local live: string[] = {}
  local seq: number = 0

  for i: number = 1, 400 do
    local key: string = "k" .. tostring(rng() % 50)
    if rng() % 3 == 0 then
      seq = seq + 1
      m:add(seq, codec.TYPE_DELETION, key, "")
      model[key] = nil
    else
      local value: string = "v" .. tostring(i)
      seq = seq + 1
      m:add(seq, codec.TYPE_VALUE, key, value)
      model[key] = value
    end
  end

  local it = m:iterator()
  it:seekToFirst()
  local lastUser: string = ""
  local lastSeq: number = 0
  local first: boolean = true
  while it:valid() do
    local parsed: Parsed = codec.parseInternalKey(it:key())
    if not first then
      if parsed.userKey == lastUser then
        T.ok(parsed.sequence < lastSeq, "same user key: sequence descends")
      else
        T.ok(lastUser < parsed.userKey, "user keys ascend")
      end
    end
    first = false
    lastUser = parsed.userKey
    lastSeq = parsed.sequence
    it:next()
  end

  local checked: number = 0
  for key, want in pairs(model) do
    local got: Lookup = m:get(key as string, seq)
    T.eq(got.value, want as string, "model key " .. tostring(key))
    checked = checked + 1
  end
  T.ok(checked > 0, "model had live keys")
end

local function testBatch(): void
  local b = batchmod.WriteBatch.new()
  b:put("alpha", "1")
  b:put("beta", "2")
  b:delete("gamma")
  T.eq(b:count(), 3, "batch count")

  local encoded: string = b:encode(7)
  local res: DecodeRes = batchmod.decode(encoded)
  T.eq(res.err, nil, "decode ok")
  T.eq(res.sequence, 7, "base sequence")
  local rb = res.batch
  T.eq(rb:count(), 3, "decoded count")

  local visited: string[] = {}
  local nextSeq: number = rb:replay(res.sequence, function(seq: number, kind: number, key: string, value: string): void
    visited[#visited + 1] = tostring(seq) .. ":" .. tostring(kind) .. ":" .. key .. "=" .. value
  end)
  T.eq(nextSeq, 10, "replay advances sequence")
  T.eq(table.concat(visited, "|"), "7:1:alpha=1|8:1:beta=2|9:0:gamma=", "replay order/values")

  local badHeader: DecodeRes = batchmod.decode("short")
  T.eq(badHeader.err ~= nil, true, "short batch error")

  local truncatedKey: DecodeRes = batchmod.decode(string.sub(encoded, 1, 20))
  T.eq(truncatedKey.err ~= nil, true, "truncated key error")

  local trailing: DecodeRes = batchmod.decode(encoded .. "x")
  T.eq(trailing.err ~= nil, true, "trailing bytes error")

  local empty = batchmod.WriteBatch.new()
  local emptyRes: DecodeRes = batchmod.decode(empty:encode(1))
  T.eq(emptyRes.err, nil, "empty batch decodes")
  T.eq(emptyRes.batch:count(), 0, "empty batch count")
end

local function testLog(): void
  local sizes: number[] = { 0, 1, 7, 100, 32760, 32761, 40000, 70000 }
  local w = log.newWriter()
  for i: number = 1, #sizes do
    local payload: string = string.rep(string.char(65 + i), sizes[i])
    w:addRecord(payload)
  end
  local data: string = w:contents()
  local read: ReadRes = log.readRecords(data)
  T.eq(read.err, nil, "log read ok")
  T.eq(#read.records, #sizes, "record count")
  for i: number = 1, #sizes do
    T.eq(#read.records[i], sizes[i], "record " .. tostring(i) .. " length")
  end
  T.eq(read.truncated, 0, "no truncation")

  -- Corruption is detected, never silently returned.
  local corrupt: string = string.sub(data, 9, 9) .. "Z" .. string.sub(data, 11)
  local cr: ReadRes = log.readRecords(corrupt)
  T.eq(cr.err ~= nil, true, "checksum mismatch detected")

  -- Torn tail: records before the tear survive, no error.
  local cut: number = #data - 5
  local torn: ReadRes = log.readRecords(string.sub(data, 1, cut))
  T.eq(torn.err, nil, "torn tail is not corruption")
  T.ok(torn.truncated > 0, "torn tail reported")
  T.eq(#torn.records, #sizes - 1, "records before tear intact")

  -- Block-tail padding: a record leaving < 7 bytes forces zero padding.
  local w2 = log.newWriter()
  w2:addRecord(string.rep("x", 32756)) -- 7 + 32756 = 32763, leaves 5 bytes
  w2:addRecord("after-padding")
  local r2: ReadRes = log.readRecords(w2:contents())
  T.eq(r2.err, nil, "padded block read ok")
  T.eq(#r2.records, 2, "padded block record count")
  T.eq(r2.records[2], "after-padding", "record after padding")
end

return {
  ["memtable snapshots"] = testMemTable,
  ["memtable random"] = testMemTableRandom,
  ["write batch"] = testBatch,
  ["write-ahead log"] = testLog,
}
