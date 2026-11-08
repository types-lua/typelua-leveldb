--- Point-in-time reads: a snapshot ignores later writes.

import leveldb from "leveldb"

local PATH: string = "testdata/snapshots.db"

local function main(): void
  os.execute("mkdir -p testdata")
  leveldb.destroy(PATH)
  local opened = leveldb.open(PATH)
  if opened.err ~= nil then error(opened.err.message) end
  local db = opened.db

  db:put("k", "old")
  local snap = db:getSnapshot()
  db:put("k", "new")

  print("latest   =", db:get("k").value)
  print("snapshot =", db:get("k", snap).value)
  db:releaseSnapshot(snap)

  db:close()
  leveldb.destroy(PATH)
end

main()
