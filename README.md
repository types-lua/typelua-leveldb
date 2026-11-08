# typelua-leveldb

A from-scratch LevelDB implementation in [TypeLua](https://types-lua.github.io/docs/) — pure Lua, no C bindings.
Write-ahead log, skip-list memtable, bloom-filtered SSTables, manifest/version tracking and
synchronous compaction, on a byte-compatible on-disk format.

```lua
import leveldb from "leveldb"

local opened = leveldb.open("data")
if opened.err ~= nil then error(opened.err.message) end
local db = opened.db

db:put("hello", "world")
print(db:get("hello").value)   --> world
db:delete("hello")
db:close()
```

## Why

- **Pure TypeLua.** Runs on PUC Lua 5.4, LuaJIT (5.1-compatible build) and the embedded
  `tlua run` interpreter — no native dependencies, no build step.
- **Real LevelDB format.** WAL records, `MANIFEST-*` version edits, `.ldb` tables, bloom
  filters and CRC32C all match the reference implementation; databases are interoperable
  in both directions (see [Compatibility](#compatibility)).
- **Typed surface.** Everything is checked under `strictNilChecks`/`noImplicitAny`;
  fallible calls return `{ err }` records instead of nil-in-the-middle tuples.
- **Modular internals.** 18 focused modules, each with a single responsibility and a
  byte-level test suite (23 cases, 1160 checks) using the built-in `tlua test` runner.

## Quick start

```bash
# requires a tlua compiler build (see the TypeLua repo)
tlua check
tlua test                 # 23 cases, 1160 checks (built-in runner)
tlua run main.tl          # demo, no build artifacts
```

Or compile and run on stock Lua:

```bash
tlua build
lua5.4 dist/main.lua
tlua build --target 5.1 && luajit dist/main.lua
```

## API

All fallible calls return a record; check `err` before using the value.

```lua
local leveldb = require("leveldb")

local opened = leveldb.open(path, options) -- { db = DB | nil, err = Error | nil }
local err = leveldb.destroy(path)          -- Error | nil
local err = leveldb.repair(path)           -- rebuild a manifest after a crash

local db = opened.db
db:put(key, value)             -- Error | nil
db:delete(key)                 -- Error | nil
db:write(batch)                -- atomic group, Error | nil
db:get(key, snapshot?)         -- { found: boolean, value: string }
db:newIterator(snapshot?)      -- iterator (seek/seekToFirst/next/valid/key/value)
db:getSnapshot()               -- number
db:releaseSnapshot(sequence)   -- void
db:compactAll()                -- Error | nil
db:property(name)              -- string ("leveldb.stats", "leveldb.num-files-at-levelN", ...)
db:close()                     -- unflushed data stays in the WAL for recovery

local batch = leveldb.WriteBatch.new()
batch:put(key, value)
batch:delete(key)
```

### Options

`leveldb.defaultOptions()` returns the full record; pass a partial table to override:

| Option | Default | Meaning |
|---|---|---|
| `createIfMissing` | `true` | Create the directory/manifest when absent |
| `errorIfExists` | `false` | Refuse to open an existing database |
| `writeBufferSize` | 4 MiB | Memtable size that triggers an L0 flush |
| `blockSize` | 4096 | Uncompressed SSTable data-block target |
| `blockRestartInterval` | 16 | Prefix-compression restart interval |
| `maxFileSize` | 2 MiB | Compaction output file target |
| `bitsPerKey` | 10 | Bloom filter budget (`0` disables filters) |
| `verifyChecksums` | `true` | Verify block CRCs on read |
| `l0CompactionTrigger` | 4 | L0 file count that starts a compaction |
| `levelBaseBytes` | 10 MiB | Level 1 size budget (×10 per level) |

## Architecture

```
WAL (log.tl) ──replay──▶ MemTable (memtable.tl) ──flush──▶ L0 SSTable (table.tl)
   │                          │                                  │
   │                          └────── reads ──────────────────────┤
   ▼                                                             ▼
batch.tl                                              VersionSet (version_set.tl)
                                                             │
                                              Compaction (db.tl + merging.tl)
```

| Module | Responsibility | Highlight |
|---|---|---|
| `util.tl` | 32-bit arithmetic, fixed-width LE | exact `mul32` for LuaJIT doubles |
| `codec.tl` | varints, length-prefixed slices, internal keys | LevelDB byte order |
| `crc32c.tl` | CRC32C + masking | reference check vector |
| `bloom.tl` | bloom policy | interoperable with `BloomFilterPolicy` |
| `errors.tl` | error records | stable `code` strings |
| `fs.tl` | file IO (`io.*`) | `(value, err)` records |
| `memtable.tl` | skip-list memtable | deterministic xorshift heights |
| `batch.tl` | `WriteBatch` | LevelDB batch wire format |
| `log.tl` | WAL writer/reader | 32 KiB blocks, fragmentation, torn-tail |
| `block.tl` | prefix-compressed blocks | restart-point binary search |
| `filter.tl` | filter block | per-2 KiB slot mapping |
| `table.tl` | SSTable builder/reader | footer, index, metaindex, CRCs |
| `version_edit.tl` | manifest records | LevelDB tags |
| `version_set.tl` | levels and compaction picking | L0 overlap closure |
| `merging.tl` | k-way merge iterator | internal-key order |
| `options.tl` | defaults + validation | one source of truth |
| `db.tl` | engine | recovery, snapshots, compaction |
| `init.tl` | facade | the only import you need |

See [`docs/DESIGN.md`](docs/DESIGN.md) for formats, invariants and the recovery state machine.

## Compatibility

Verified locally against LevelDB 1.23 (`libleveldb` + `leveldbutil`):

- **ours → LevelDB:** a database written here opens in `leveldb_open`, replays the WAL
  and returns identical keys/values; `leveldbutil dump` parses our `MANIFEST-*`.
- **LevelDB → ours:** a database written by `libleveldb` (compaction, tombstones,
  bloom filters) opens here and produces identical iteration/`get` results.

Not implemented, by design or scope:

- **No Snappy compression.** Blocks are written uncompressed; reading a block with a
  non-zero compression type is reported as corruption instead of guessing.
- **Synchronous compaction.** The engine is single-threaded like the rest of TypeLua;
  compactions run inline (`compactAll`) or when L0 pressure is detected during writes.
- **No cross-process locking.** There is no `LOCK` file: one writer per directory.
- **No fsync knob.** `syncWrites` exists in options but Lua's `io` only flushes user-space
  buffers; crash tolerance comes from the WAL + replay, as in the reference design.
- **Tombstones are dropped only at the base level.** A conservative rule keeps them
  when a deeper level might still hold the key.

## Testing

Tests use the compiler's zero-config runner: files under `tests/` return a table of
named cases and assert through `tlua_test` (`eq`, `eqBytes`, `ok`, `raises`, `fail`).

```bash
tlua test                              # embedded golua, type-checks first
tlua test --filter compaction          # only matching module/case names
tlua test --format=json                # one JSON object per line
tlua test --lua lua5.4                 # stock Lua 5.4
tlua test --lua luajit --target 5.1    # LuaJIT
```

Coverage: encoding vectors, CRC/bloom reference values, memtable snapshots, WAL
fragmentation/corruption, block restart search, SSTable round-trips, corruption
detection, crash recovery, batches, snapshots, compaction, destroy and repair.

## 中文速览

纯 TypeLua 从零实现的 LevelDB：WAL、跳表 MemTable、带布隆过滤器的 SSTable、
Manifest/Version 与同步压实，磁盘格式与官方 LevelDB 双向兼容。

```lua
import leveldb from "leveldb"
local o = leveldb.open("data")
local db = o.db
db:put("k", "v")
print(db:get("k").value) -- v
```

落盘格式、恢复流程、压实策略与已知取舍见 [`docs/DESIGN.md`](docs/DESIGN.md)。

## License

MIT.

## Packaging

The library lives at `tlua_modules/leveldb/` (its own `tlua.toml` is included), so it can be
used directly in this project or copied/vendored into another project's `tlua_modules/leveldb`:

```bash
cp -r tlua_modules/leveldb /path/to/project/tlua_modules/leveldb
```
