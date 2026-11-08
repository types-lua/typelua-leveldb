--- Open, write, read, iterate, reopen and clean up.

import leveldb from "leveldb"

local PATH: string = "testdata/basic.db"

local function main(): void
  os.execute("mkdir -p testdata")
  leveldb.destroy(PATH)
  local opened = leveldb.open(PATH)
  if opened.err ~= nil then error(opened.err.message) end
  local db = opened.db

  db:put("hello", "world")
  db:put("lang", "typelua")
  print("hello =", db:get("hello").value)

  local it = db:newIterator()
  it:seekToFirst()
  while it:valid() do
    print("  " .. it:key() .. " = " .. it:value())
    it:next()
  end

  db:close()

  -- Unflushed writes live in the WAL; reopening replays them.
  local again = leveldb.open(PATH)
  if again.err ~= nil then error(again.err.message) end
  print("after reopen hello =", again.db:get("hello").value)
  again.db:close()
  leveldb.destroy(PATH)
end

main()
