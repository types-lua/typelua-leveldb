# typelua-leveldb — design notes

A LevelDB implementation in pure TypeLua. Everything below is enforced by
tests; file/record layouts follow the reference implementation byte for byte.

## 1. Module map

```
facade        init.tl
engine        db.tl
manifest      version_edit.tl, version_set.tl
tables        block.tl, filter.tl, table.tl
memtable      memtable.tl
durability    log.tl, batch.tl
iteration     merging.tl
primitives    util.tl, codec.tl, crc32c.tl, bloom.tl, fs.tl, options.tl, errors.tl
```

Dependency direction is strictly downward: primitives never import the engine,
and the engine imports everything. `merging.tl` depends only on `codec.tl`, so
it can merge memtable and table iterators without knowing either type.

## 2. On-disk formats

| File | Format |
|---|---|
| `CURRENT` | `MANIFEST-%06d\n`, written via temp + rename |
| `MANIFEST-N` | log records; each payload is one `VersionEdit` |
| `N.log` | LevelDB log: 7-byte headers, 32 KiB blocks, fragmented records |
| `N.ldb` | data blocks → filter block → metaindex → index → 48-byte footer |

Block trailer: `u8 compression (0)` + `fixed32 masked CRC32C(block ++ type)`.

Internal keys: `user_key ++ fixed64((sequence << 8) | type)`; the comparator is
user key ascending, then sequence descending. Deletion type is `0`, value `1`.

## 3. VersionEdit tags

```
1 comparator (len-prefixed)    5 compact pointer (level + key)
2 log number (varint)          6 deleted file (level + number)
3 next file number (varint)    7 new file (level, number, size, smallest, largest)
4 last sequence (varint)       9 previous log number (legacy, ignored)
```

`version_set.apply` maintains the invariants: L0 sorted newest-file-first
(overlaps allowed), levels 1..6 sorted by smallest key and disjoint.

## 4. Write path

1. `WriteBatch.encode(seq)` → one atomic record.
2. Append the record to the WAL (durable before anything else).
3. Replay the batch into the skip-list memtable.
4. If `memtable.sqlite_bytes >= writeBufferSize`, rotate:
   allocate a new WAL, write the memtable to an L0 table, append a
   `VersionEdit` (new file + new log number), then delete the old WAL.

The order matters: table bytes land before the edit that references them, and
the old WAL is deleted only after the edit is durable.

## 5. Read path

- Memtable lookup at `snapshot` (newest sequence ≤ snapshot).
- L0 files newest-first; every file may overlap.
- Levels 1..6: binary search on **user keys** (file bounds are internal keys,
  so comparing raw tags would reject higher snapshots), then a single table
  lookup.
- A tombstone stops the search and reports "not found".

Iterators build one child per source, merge with `merging.tl`, then apply a
snapshot filter: skip records newer than the snapshot, keep the first record
per user key, hide deletions.

## 6. Compaction

`version_set.pickCompaction` returns a range when L0 has ≥ `l0CompactionTrigger`
files or a level exceeds `levelBaseBytes × 10^(level-1)`. Inputs are the seed
file (all overlapping L0 files for level 0) plus all overlapping files in the
next level.

Retention rules while merging:

- Keep every record still visible to a live snapshot (`sequence > smallestSnapshot`).
- Keep the first record per user key at or below the snapshot.
- Drop a tombstone at or below the snapshot only when no deeper level can hold
  the key (`isBaseLevelFor`); otherwise it must survive to mask older values.

Outputs split at `maxFileSize`; the edit deletes inputs, adds outputs, then
input files and their cached readers are dropped.

## 7. Recovery

```
CURRENT → manifest → replay edits → scan logs [logNumber, nextFileNumber)
        → memtable → new WAL → flush recovered memtable to L0 → delete old logs
```

A torn WAL tail is normal after a crash and is ignored. A checksum mismatch is
reported as `corruption`; silently skipping it could resurrect deleted data.

`repair` adopts surviving tables at L0 (levels cannot be trusted without the
manifest), replays surviving WALs into one fresh table, then rewrites
`CURRENT`/manifest.

## 8. Testing strategy

- **Reference vectors:** CRC32C check value, LevelDB bloom hash/filter bytes,
  varint encodings, internal-key ordering.
- **Format round-trips:** blocks (restarts, prefix sharing), tables (footer,
  index, filter, CRCs), batches, manifest edits.
- **Failure injection:** truncated varints, bad CRCs, torn logs, corrupted
  tables, missing manifests.
- **Engine behaviour:** 300-key compaction, mass deletion, snapshot reads,
  crash recovery (close without flush), destroy/repair.
- **Interop (manual):** `libleveldb` reads our WAL/tables/manifest; we read a
  database produced by `libleveldb` with compaction and tombstones.

## 9. Deliberate simplifications

| Area | Decision | Consequence |
|---|---|---|
| Compression | none | larger files; non-zero block compression is rejected |
| Scheduling | synchronous compaction | write latency spikes under pressure |
| Locking | none | one process per database directory |
| fsync | not exposed | OS-level power loss can lose the last WAL writes |
| Block cache | table reader per file number | sequential scans re-read small files |
| Manual ranges | `compactAll` only | no partial `compactRange(start, end)` |

These are scope choices, not TODOs hidden behind broken behaviour: each is
covered by a test asserting the documented outcome.
