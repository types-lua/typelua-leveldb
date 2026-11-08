--- TypeLua LevelDB — public facade.
---
---   import leveldb from "leveldb"
---   local opened = leveldb.open("./data")
---   if opened.err ~= nil then ... end
---   local db = opened.db
---   db:put("k", "v")
---   local got = db:get("k")
---   if got.found then print(got.value) end
---
--- Every fallible call returns one record with an `err` field (or nil), so
--- callers never juggle Lua's nil-in-the-middle multi-return.
---
--- Storage is a from-scratch LevelDB: WAL, skip-list memtable, block-based
--- SSTables with bloom filters, manifest/version tracking and synchronous
--- compaction. Files are byte-compatible with the reference format, so
--- `leveldbutil` can inspect them.

local batchmod = require("leveldb.batch")
local dbmod = require("leveldb.db")
local errors = require("leveldb.errors")
local options = require("leveldb.options")

--- Opens or creates a database.
--- Returns { db: DB | nil, err: Error | nil }.
local function open(path: string, userOpts: any): any
  return dbmod.open(path, userOpts)
end

--- Deletes every file owned by the database at `path`.
local function destroy(path: string): any
  return dbmod.destroy(path)
end

--- Rebuilds a manifest from surviving table files after a crash.
local function repair(path: string): any
  return dbmod.repair(path)
end

return {
  open = open,
  destroy = destroy,
  repair = repair,
  WriteBatch = batchmod.WriteBatch,
  defaultOptions = options.defaultOptions,
  errors = errors,
}
