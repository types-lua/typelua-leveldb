--- TypeLua LevelDB demo: open, write, read, iterate, snapshot, compact.
---
---   tlua run main.tl
---
--- The database lives in ./demo.db; the script starts from a clean slate.

import leveldb from "leveldb"

local PATH: string = "demo.db"

local function main(): void
  leveldb.destroy(PATH)

  local opened = leveldb.open(PATH)
  if opened.err ~= nil then
    print("open failed:", opened.err.message)
    os.exit(1)
  end
  local db = opened.db

  -- Single writes.
  db:put("hello", "world")
  db:put("lang", "typelua")

  -- Atomic batch: both records become visible together.
  local batch = leveldb.WriteBatch.new()
  batch:put("counter", "0")
  batch:put("owner", "docs")
  batch:delete("lang")
  db:write(batch)

  local got = db:get("hello")
  print("hello =", got.value)
  print("lang exists =", db:get("lang").found)

  -- Snapshot: reads pinned to this sequence ignore later writes.
  local snap = db:getSnapshot()
  db:put("hello", "again")
  print("now =", db:get("hello").value)
  print("snapshot =", db:get("hello", snap).value)
  db:releaseSnapshot(snap)

  -- Ordered iteration over user keys.
  db:put("a", "1")
  db:put("z", "26")
  local it = db:newIterator()
  it:seekToFirst()
  local keys: string[] = {}
  while it:valid() do
    keys[#keys + 1] = it:key() .. "=" .. it:value()
    it:next()
  end
  print("keys:", table.concat(keys, ", "))

  -- Compaction merges L0 tables into deeper levels.
  db:compactAll()
  print(db:property("leveldb.stats"))

  db:close()

  -- Reopen: unflushed writes are recovered from the WAL.
  local reopened = leveldb.open(PATH)
  if reopened.err ~= nil then
    print("reopen failed:", reopened.err.message)
    os.exit(1)
  end
  print("after reopen hello =", reopened.db:get("hello").value)
  reopened.db:close()

  leveldb.destroy(PATH)
  print("done")
end

main()
