--- Atomic writes with WriteBatch, then a compaction round.

import leveldb from "leveldb"

local PATH: string = "testdata/batch.db"

local function main(): void
  os.execute("mkdir -p testdata")
  leveldb.destroy(PATH)
  local opened = leveldb.open(PATH)
  if opened.err ~= nil then error(opened.err.message) end
  local db = opened.db

  local batch = leveldb.WriteBatch.new()
  batch:put("a", "1")
  batch:put("b", "2")
  batch:delete("a")
  db:write(batch)
  print("a exists =", db:get("a").found)
  print("b =", db:get("b").value)

  for i: number = 1, 200 do
    db:put(string.format("k%03d", i), string.rep("x", 32))
  end
  db:compactAll()
  print(db:property("leveldb.stats"))

  db:close()
  leveldb.destroy(PATH)
end

main()
