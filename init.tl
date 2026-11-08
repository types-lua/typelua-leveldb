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

-- Locate sibling modules at runtime no matter where this package is
-- vendored. PUC Lua reports sources with a leading "@", golua does not.
local __src: any = debug.getinfo(1, "S").source
if string.sub(__src, 1, 1) == "@" then __src = string.sub(__src, 2) end
local __dir: any = string.match(__src, "^(.*[/\\])") or ""
if __dir ~= "" and not string.find(package.path, __dir, 1, true) then
  package.path = __dir .. "?.lua;" .. __dir .. "?/init.lua;" .. package.path
end

local batchmod = require("leveldb_batch")
local dbmod = require("leveldb_db")
local errors = require("leveldb_errors")
local options = require("leveldb_options")

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
