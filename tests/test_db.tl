--- End-to-end database tests: durability, snapshots, compaction, repair.
---
--- Each case uses its own directory under testdata/ and small thresholds so
--- rotation (write buffer) and compaction (L0 trigger) happen within a few
--- hundred writes.

local H = require("tests.harness")
local leveldb = require("leveldb")
local codec = require("leveldb.codec")

type OpenResult = { db: any, err: any }
type GetResult = { found: boolean, value: string }
type WriteBatch = any

local DATAROOT: string = "testdata"

local function resetDir(name: string): string
  local dir: string = DATAROOT .. "/" .. name
  os.execute("rm -rf '" .. dir .. "'")
  os.execute("mkdir -p '" .. dir .. "'")
  return dir
end

local function smallOptions(): any
  local opts = leveldb.defaultOptions()
  opts.writeBufferSize = 2048
  opts.blockSize = 256
  opts.maxFileSize = 8192
  opts.l0CompactionTrigger = 2
  opts.levelBaseBytes = 8192
  return opts
end

local function openOk(path: string, opts: any): any
  local opened: OpenResult = leveldb.open(path, opts)
  if opened.err ~= nil then
    H.ok(false, "open " .. path .. ": " .. tostring(opened.err.message))
    error("open failed")
  end
  return opened.db
end

local function testBasic(): void
  H.section("db basic")
  local dir: string = resetDir("basic")
  local db: any = openOk(dir, smallOptions())

  H.eq(db:put("alpha", "1"), nil, "put alpha")
  H.eq(db:put("beta", "2"), nil, "put beta")
  H.eq(db:put("empty", ""), nil, "put empty value")

  local a: GetResult = db:get("alpha")
  H.eq(a.found, true, "get alpha found")
  H.eq(a.value, "1", "get alpha value")
  H.eq(db:get("missing").found, false, "get missing")

  H.eq(db:delete("beta"), nil, "delete beta")
  H.eq(db:get("beta").found, false, "deleted key is gone")
  H.eq(db:get("alpha").value, "1", "delete leaves other keys")

  -- Overwrite keeps the newest value visible.
  db:put("alpha", "11")
  H.eq(db:get("alpha").value, "11", "overwrite wins")

  db:close()
  os.execute("rm -rf '" .. dir .. "'")
end

local function testRecovery(): void
  H.section("db recovery")
  local dir: string = resetDir("recovery")
  local db: any = openOk(dir, smallOptions())
  for i: number = 1, 50 do
    db:put("k" .. tostring(i), "v" .. tostring(i))
  end
  db:delete("k10")
  -- Close without an explicit flush: the WAL is the only durable copy, so
  -- reopening must replay it.
  db:close()

  local reopened: any = openOk(dir, smallOptions())
  H.eq(reopened:get("k1").value, "v1", "recovered k1")
  H.eq(reopened:get("k50").value, "v50", "recovered k50")
  H.eq(reopened:get("k10").found, false, "recovered deletion")

  local count: number = 0
  local it = reopened:newIterator()
  it:seekToFirst()
  while it:valid() do
    count = count + 1
    it:next()
  end
  H.eq(count, 49, "recovered key count")

  reopened:close()
  os.execute("rm -rf '" .. dir .. "'")
end

local function testBatchAtomic(): void
  H.section("db batch")
  local dir: string = resetDir("batch")
  local db: any = openOk(dir, smallOptions())

  local b = leveldb.WriteBatch.new()
  b:put("a", "1")
  b:put("b", "2")
  b:delete("a")
  H.eq(db:write(b), nil, "write batch")
  H.eq(db:get("a").found, false, "batch delete visible")
  H.eq(db:get("b").value, "2", "batch put visible")

  local empty = leveldb.WriteBatch.new()
  H.eq(db:write(empty), nil, "empty batch is a no-op")
  H.eq(db:get("b").value, "2", "empty batch changes nothing")

  db:close()
  os.execute("rm -rf '" .. dir .. "'")
end

local function testSnapshot(): void
  H.section("db snapshot")
  local dir: string = resetDir("snapshot")
  local db: any = openOk(dir, smallOptions())

  db:put("k", "old")
  local snap: number = db:getSnapshot()
  db:put("k", "new")
  db:delete("gone")

  H.eq(db:get("k").value, "new", "latest read")
  H.eq(db:get("k", snap).value, "old", "snapshot read")
  local it = db:newIterator(snap)
  it:seek("k")
  H.eq(it:valid(), true, "snapshot iterator valid")
  H.eq(it:value(), "old", "snapshot iterator value")
  db:releaseSnapshot(snap)

  db:close()
  os.execute("rm -rf '" .. dir .. "'")
end

local function testIterationAndCompaction(): void
  H.section("db iteration/compaction")
  local dir: string = resetDir("compact")
  local opts: any = smallOptions()
  local db: any = openOk(dir, opts)

  local expected: string[] = {}
  for i: number = 1, 300 do
    local key: string = string.format("key%04d", i)
    local value: string = string.rep("x", 40) .. tostring(i)
    db:put(key, value)
    expected[#expected + 1] = key
  end
  -- Force several L0 files, then compact everything.
  H.eq(db:compactAll(), nil, "compactAll")
  H.eq(db:compactAll(), nil, "compactAll is idempotent")

  local seen: number = 0
  local it = db:newIterator()
  it:seekToFirst()
  local last: string = ""
  while it:valid() do
    seen = seen + 1
    H.ok(last < it:key(), "iteration ascending at " .. tostring(seen))
    last = it:key()
    it:next()
  end
  H.eq(seen, 300, "all keys survive compaction")
  H.eq(db:get("key0001").found, true, "first key after compaction")
  H.eq(db:get("key0300").found, true, "last key after compaction")
  local stats: string = db:property("leveldb.stats")
  H.ok(#stats > 0, "stats property")
  H.ok(db:property("leveldb.approximate-memory-usage") ~= "", "memory property")

  -- Seek below/above the key range.
  it:seek("key0000")
  H.eq(it:key(), "key0001", "seek below first")
  it:seek("key9999")
  H.eq(it:valid(), false, "seek beyond last")

  db:close()
  os.execute("rm -rf '" .. dir .. "'")
end

local function testDeleteRange(): void
  H.section("db delete/compaction")
  local dir: string = resetDir("deleted")
  local db: any = openOk(dir, smallOptions())
  for i: number = 1, 100 do
    db:put("d" .. tostring(i), "v" .. tostring(i))
  end
  for i: number = 1, 100 do
    db:delete("d" .. tostring(i))
  end
  H.eq(db:compactAll(), nil, "compaction after deletes")
  H.eq(db:get("d1").found, false, "deleted after compaction")
  local it = db:newIterator()
  it:seekToFirst()
  H.eq(it:valid(), false, "no visible keys after mass delete")
  db:close()
  os.execute("rm -rf '" .. dir .. "'")
end

local function testCorruption(): void
  H.section("db corruption")
  local dir: string = resetDir("corrupt")
  local db: any = openOk(dir, smallOptions())
  db:put("k", "v")
  db:close()

  -- Corrupt CURRENT so the manifest cannot be located.
  local res = require("leveldb.fs").readFile(dir .. "/CURRENT")
  H.eq(res.err, nil, "read CURRENT")
  require("leveldb.fs").writeFile(dir .. "/CURRENT", "MANIFEST-999999\n")
  local opened: OpenResult = leveldb.open(dir, smallOptions())
  H.ok(opened.err ~= nil, "open reports missing manifest")

  os.execute("rm -rf '" .. dir .. "'")
end

local function testDestroyRepair(): void
  H.section("db destroy/repair")
  local dir: string = resetDir("destroy")
  local db: any = openOk(dir, smallOptions())
  for i: number = 1, 20 do
    db:put("r" .. tostring(i), "v" .. tostring(i))
  end
  db:close()

  H.eq(leveldb.destroy(dir), nil, "destroy returns nil")
  H.eq(require("leveldb.fs").exists(dir .. "/CURRENT"), false, "CURRENT removed")

  -- Rebuild from surviving tables: write a fresh DB, delete CURRENT only,
  -- then repair should reconstruct a manifest that still answers reads.
  local dir2: string = resetDir("repair")
  local db2: any = openOk(dir2, smallOptions())
  for i: number = 1, 30 do
    db2:put("s" .. tostring(i), "w" .. tostring(i))
  end
  db2:close()
  os.execute("rm -f '" .. dir2 .. "/CURRENT'")
  H.eq(leveldb.repair(dir2), nil, "repair returns nil")
  local repaired: OpenResult = leveldb.open(dir2, smallOptions())
  H.ok(repaired.err == nil, "open after repair")
  if repaired.err == nil then
    local rdb: any = repaired.db
    H.eq(rdb:get("s1").value, "w1", "repaired read")
    rdb:close()
  end
  os.execute("rm -rf '" .. dir .. "'")
  os.execute("rm -rf '" .. dir2 .. "'")
end

local function run(): void
  os.execute("mkdir -p testdata")
  testBasic()
  testRecovery()
  testBatchAtomic()
  testSnapshot()
  testIterationAndCompaction()
  testDeleteRange()
  testCorruption()
  testDestroyRepair()
end

return { run = run }
