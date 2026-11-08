--- DB: the public database engine.
---
--- Write path: batch -> WAL (durable append) -> memtable -> rotate to an
--- L0 table when the write buffer fills.
--- Read path: memtable, L0 newest-first, then levels 1..6 by binary search.
--- Compaction runs synchronously when pickCompaction reports pressure; the
--- single-threaded model keeps ordering and recovery easy to reason about.
---
--- Durability model: every batch is appended to the WAL before it touches
--- the memtable, so a crash between those steps loses nothing. Reopening
--- replays WAL records into a fresh memtable and flushes it to L0.
--- Tombstones are only dropped when no deeper level can hold the key.

local batchmod = require("leveldb.batch")
local codec = require("leveldb.codec")
local errors = require("leveldb.errors")
local fs = require("leveldb.fs")
local log = require("leveldb.log")
local memtable = require("leveldb.memtable")
local merging = require("leveldb.merging")
local options = require("leveldb.options")
local tablemod = require("leveldb.table")
local util = require("leveldb.util")
local version_edit = require("leveldb.version_edit")
local version_set = require("leveldb.version_set")

type Error = {
  code: string,
  message: string,
}

type Options = {
  createIfMissing: boolean,
  errorIfExists: boolean,
  writeBufferSize: number,
  blockSize: number,
  blockRestartInterval: number,
  maxFileSize: number,
  bitsPerKey: number,
  verifyChecksums: boolean,
  paranoidChecks: boolean,
  syncWrites: boolean,
  l0CompactionTrigger: number,
  levelBaseBytes: number,
}

type FileMeta = {
  number: number,
  size: number,
  smallest: string,
  largest: string,
}

type NewFile = {
  level: number,
  meta: FileMeta,
}

type VersionEdit = {
  comparator: string | nil,
  logNumber: number | nil,
  nextFileNumber: number | nil,
  lastSequence: number | nil,
  deleted: { level: number, number: number }[],
  newFiles: NewFile[],
}

type Compaction = {
  level: number,
  inputs: FileMeta[],
  inputsNext: FileMeta[],
  smallest: string,
  largest: string,
}

type Lookup = {
  state: number,
  value: string,
}

type Parsed = {
  userKey: string,
  sequence: number,
  valueType: number,
}

type ParsedBatch = {
  batch: any,
  sequence: number,
  err: Error | nil,
}

type LogRead = {
  records: string[],
  err: Error | nil,
  truncated: number,
}

type DecodedEdit = {
  edit: VersionEdit,
  err: Error | nil,
}

type OpenResult = {
  db: DB | nil,
  err: Error | nil,
}

type GetResult = {
  found: boolean,
  value: string,
}

local COMPARATOR_NAME: string = "leveldb.BytewiseComparator"
local NUM_LEVELS: number = 7
local CURRENT: string = "CURRENT"
local LOCK: string = "LOCK"
local LOG: string = "LOG"

local function formatNumber(n: number): string
  return string.format("%06d", n)
end

local function manifestName(n: number): string
  return "MANIFEST-" .. formatNumber(n)
end

local function tableName(n: number): string
  return formatNumber(n) .. ".ldb"
end

local function logName(n: number): string
  return formatNumber(n) .. ".log"
end

local function joinPath(dir: string, name: string): string
  if dir == "" then return name end
  if string.sub(dir, -1) == "/" then return dir .. name end
  return dir .. "/" .. name
end

--- Smallest live snapshot (or the newest sequence when none are held).
local function smallestSnapshot(snapshots: number[], lastSequence: number): number
  local smallest: number = lastSequence
  for i: number = 1, #snapshots do
    if snapshots[i] < smallest then smallest = snapshots[i] end
  end
  return smallest
end

local function tableOptions(opts: Options): any
  return {
    blockSize = opts.blockSize,
    blockRestartInterval = opts.blockRestartInterval,
    bitsPerKey = opts.bitsPerKey,
  }
end

local function readerOptions(opts: Options): any
  return { verifyChecksums = opts.verifyChecksums }
end

class DB {
  path: string,
  opts: Options,
  versions: any,
  mem: any,
  logNumber: number,
  logPath: string,
  logWriter: any,
  lastSequence: number,
  closed: boolean,
  snapshots: number[],
  tables: any,
  manifestPath: string,

  constructor(path: string, opts: Options, versions: any, manifestPath: string)
    self.path = path
    self.opts = opts
    self.versions = versions
    self.mem = memtable.MemTable.new()
    self.logNumber = 0
    self.logPath = ""
    self.logWriter = log.newWriter()
    self.lastSequence = versions.lastSequence
    self.closed = false
    self.snapshots = {}
    self.tables = {}
    self.manifestPath = manifestPath
  end,

  --- Appends one encoded VersionEdit to the manifest (a log record).
  writeEdit(edit: VersionEdit): Error | nil
    local writer = log.newWriter()
    writer:addRecord(version_edit.encode(edit))
    return fs.appendFile(self.manifestPath, writer:drain())
  end,

  --- Opens (and caches) a table by file number.
  openTable(number: number): any
    local cached: any = self.tables[number]
    if cached ~= nil then return cached end
    local res = fs.readFile(joinPath(self.path, tableName(number)))
    if res.err ~= nil then
      error("table file missing: " .. tableName(number))
    end
    local reader = tablemod.TableReader.new(res.data, readerOptions(self.opts))
    self.tables[number] = reader
    return reader
  end,

  forgetTable(number: number): void
    self.tables[number] = nil
  end,

  --- Moves the current memtable into an L0 table and starts a new WAL.
  flushToLog(newLog: number, oldLogPath: string): Error | nil
    local fileNumber: number = self.versions.nextFileNumber
    self.versions.nextFileNumber = fileNumber + 1

    local builder = tablemod.TableBuilder.new(tableOptions(self.opts))
    local smallest: string = ""
    local largest: string = ""
    local hasFirst: boolean = false
    local memIt = self.mem:iterator()
    memIt:seekToFirst()
    while memIt:valid() do
      local key: string = memIt:key()
      if not hasFirst then
        smallest = key
        hasFirst = true
      end
      largest = key
      builder:add(key, memIt:value())
      memIt:next()
    end

    local data: string = builder:finish()
    local dst: string = joinPath(self.path, tableName(fileNumber))
    local writeErr: Error | nil = fs.writeFile(dst, data)
    if writeErr ~= nil then return writeErr end

    local edit: VersionEdit = version_edit.newEdit()
    edit.logNumber = newLog
    edit.nextFileNumber = self.versions.nextFileNumber
    edit.lastSequence = self.lastSequence
    table.insert(edit.newFiles, {
      level = 0,
      meta = { number = fileNumber, size = #data, smallest = smallest, largest = largest },
    })
    local editErr: Error | nil = self:writeEdit(edit)
    if editErr ~= nil then
      fs.remove(dst)
      return editErr
    end
    self.versions:apply(edit)
    self.mem = memtable.MemTable.new()
    if oldLogPath ~= "" then
      fs.remove(oldLogPath)
    end
    self.logNumber = newLog
    self.logPath = joinPath(self.path, logName(newLog))
    self.logWriter = log.newWriter()
    self.logWriter:reset()
    return nil
  end,

  --- Rotates the memtable: new WAL first, then table + manifest, then the
  --- old WAL is removed. A crash at any step leaves a replayable state.
  rotate(): Error | nil
    local oldLogPath: string = self.logPath
    local newLog: number = self.versions.nextFileNumber
    self.versions.nextFileNumber = newLog + 1
    local createErr: Error | nil = fs.writeFile(joinPath(self.path, logName(newLog)), "")
    if createErr ~= nil then return createErr end
    local err: Error | nil = self:flushToLog(newLog, oldLogPath)
    if err ~= nil then
      fs.remove(joinPath(self.path, logName(newLog)))
      return err
    end
    return nil
  end,

  put(key: string, value: string): Error | nil
    local batch = batchmod.WriteBatch.new()
    batch:put(key, value)
    return self:write(batch)
  end,

  delete(key: string): Error | nil
    local batch = batchmod.WriteBatch.new()
    batch:delete(key)
    return self:write(batch)
  end,

  --- Atomically appends a batch: WAL first (durable), then memtable.
  write(batch: any): Error | nil
    if self.closed then return errors.closed() end
    local count: number = batch:count()
    if count == 0 then return nil end
    local seq: number = self.lastSequence + 1
    local encoded: string = batch:encode(seq)
    self.logWriter:addRecord(encoded)
    local fresh: string = self.logWriter:drain()
    local appendErr: Error | nil = fs.appendFile(self.logPath, fresh)
    if appendErr ~= nil then return appendErr end
    local mem: any = self.mem
    batch:replay(seq, function(s: number, kind: number, key: string, value: string): void
      mem:add(s, kind, key, value)
    end)
    self.lastSequence = seq + count - 1
    if self.mem:approximateMemory() >= self.opts.writeBufferSize then
      return self:rotate()
    end
    return nil
  end,

  --- Internal lookup with tombstone awareness.
  lookup(userKey: string, snapshot: number): Lookup
    local fromMem: Lookup = self.mem:get(userKey, snapshot)
    if fromMem.state ~= memtable.MISSING then return fromMem end

    local probe: string = codec.internalKey(userKey, snapshot, codec.TYPE_VALUE)
    local l0: FileMeta[] = self.versions:levelFiles(0)
    for i: number = 1, #l0 do
      local got: Lookup = self:openTable(l0[i].number):get(userKey, snapshot)
      if got.state ~= tablemod.MISSING then return got end
    end

    local level: number = 1
    while level < NUM_LEVELS do
      local files: FileMeta[] = self.versions:levelFiles(level)
      local chosen: FileMeta | nil = nil
      local left: number = 1
      local right: number = #files
      -- Compare *user* keys here: file bounds are internal keys whose
      -- sequence tags would otherwise reject a higher snapshot sequence.
      while left <= right do
        local mid: number = math.floor((left + right) / 2)
        local f: FileMeta = files[mid]
        local largestUser: string = codec.parseInternalKey(f.largest).userKey
        if largestUser < userKey then
          left = mid + 1
        else
          chosen = f
          right = mid - 1
        end
      end
      if chosen ~= nil then
        local smallestUser: string = codec.parseInternalKey(chosen.smallest).userKey
        if smallestUser <= userKey then
          local got: Lookup = self:openTable(chosen.number):get(userKey, snapshot)
          if got.state ~= tablemod.MISSING then return got end
        end
      end
      level = level + 1
    end
    return { state = memtable.MISSING, value = "" }
  end,

  get(key: string, snapshot: number | nil): GetResult
    if self.closed then return { found = false, value = "" } end
    local snap: number = self.lastSequence
    if snapshot ~= nil then snap = snapshot end
    local result: Lookup = self:lookup(key, snap)
    if result.state == memtable.FOUND then
      return { found = true, value = result.value }
    end
    return { found = false, value = "" }
  end,

  getSnapshot(): number
    local seq: number = self.lastSequence
    table.insert(self.snapshots, seq)
    return seq
  end,

  releaseSnapshot(seq: number): void
    local kept: number[] = {}
    for i: number = 1, #self.snapshots do
      if self.snapshots[i] ~= seq then kept[#kept + 1] = self.snapshots[i] end
    end
    self.snapshots = kept
  end,

  --- True when no level below `level` can contain `userKey` (tombstone safe).
  isBaseLevelFor(level: number, userKey: string): boolean
    local probe: string = codec.internalKey(userKey, self.lastSequence, codec.TYPE_VALUE)
    local l: number = level + 1
    while l < NUM_LEVELS do
      if #self.versions:overlapping(l, probe, probe) > 0 then
        return false
      end
      l = l + 1
    end
    return true
  end,

  --- Compacts one picked range into the next level.
  compactOnce(comp: Compaction): Error | nil
    local children: any[] = {}
    for i: number = 1, #comp.inputs do
      children[#children + 1] = self:openTable(comp.inputs[i].number):iterator()
    end
    for i: number = 1, #comp.inputsNext do
      children[#children + 1] = self:openTable(comp.inputsNext[i].number):iterator()
    end
    if #children == 0 then return nil end

    local merged: any = merging.newMergingIterator(children)
    merged:seekToFirst()

    local snapshot: number = smallestSnapshot(self.snapshots, self.lastSequence)
    local builder = tablemod.TableBuilder.new(tableOptions(self.opts))
    local outputNumber: number = self.versions.nextFileNumber
    self.versions.nextFileNumber = outputNumber + 1
    local firstKey: string = ""
    local lastKey: string = ""
    local newFiles: NewFile[] = {}
    local lastUser: string = ""

    local function finishOutput(): Error | nil
      if firstKey == "" then return nil end
      local data: string = builder:finish()
      local dst: string = joinPath(self.path, tableName(outputNumber))
      local writeErr: Error | nil = fs.writeFile(dst, data)
      if writeErr ~= nil then return writeErr end
      table.insert(newFiles, {
        level = comp.level + 1,
        meta = { number = outputNumber, size = #data, smallest = firstKey, largest = lastKey },
      })
      outputNumber = self.versions.nextFileNumber
      self.versions.nextFileNumber = outputNumber + 1
      builder = tablemod.TableBuilder.new(tableOptions(self.opts))
      firstKey = ""
      lastKey = ""
      return nil
    end

    while merged:valid() do
      local parsed: Parsed = codec.parseInternalKey(merged:key())
      local keep: boolean = true
      if parsed.userKey == lastUser then
        -- Duplicate user key: keep only entries still visible to a snapshot.
        if parsed.sequence <= snapshot then keep = false end
      else
        lastUser = parsed.userKey
        if parsed.valueType == codec.TYPE_DELETION and parsed.sequence <= snapshot then
          if self:isBaseLevelFor(comp.level + 1, parsed.userKey) then
            keep = false
          end
        end
      end

      if keep then
        if firstKey == "" then firstKey = merged:key() end
        lastKey = merged:key()
        builder:add(merged:key(), merged:value())
        if builder:size() >= self.opts.maxFileSize then
          local flushErr: Error | nil = finishOutput()
          if flushErr ~= nil then return flushErr end
        end
      end
      merged:next()
    end

    local tailErr: Error | nil = finishOutput()
    if tailErr ~= nil then return tailErr end

    local edit: VersionEdit = version_edit.newEdit()
    edit.nextFileNumber = self.versions.nextFileNumber
    edit.lastSequence = self.lastSequence
    for i: number = 1, #comp.inputs do
      table.insert(edit.deleted, { level = comp.level, number = comp.inputs[i].number })
    end
    for i: number = 1, #comp.inputsNext do
      table.insert(edit.deleted, { level = comp.level + 1, number = comp.inputsNext[i].number })
    end
    for i: number = 1, #newFiles do
      table.insert(edit.newFiles, newFiles[i])
    end

    local editErr: Error | nil = self:writeEdit(edit)
    if editErr ~= nil then
      for i: number = 1, #newFiles do
        fs.remove(joinPath(self.path, tableName(newFiles[i].meta.number)))
      end
      return editErr
    end
    self.versions:apply(edit)

    for i: number = 1, #comp.inputs do
      local n: number = comp.inputs[i].number
      self:forgetTable(n)
      fs.remove(joinPath(self.path, tableName(n)))
    end
    for i: number = 1, #comp.inputsNext do
      local n: number = comp.inputsNext[i].number
      self:forgetTable(n)
      fs.remove(joinPath(self.path, tableName(n)))
    end
    return nil
  end,

  --- Runs compactions until every level is within budget.
  compactAll(): Error | nil
    while true do
      local comp: Compaction | nil = self.versions:pickCompaction(self.opts.l0CompactionTrigger, self.opts.levelBaseBytes)
      if comp == nil then return nil end
      local err: Error | nil = self:compactOnce(comp)
      if err ~= nil then return err end
    end
  end,

  compactRange(): Error | nil
    return self:compactAll()
  end,

  --- Public iterator over user keys at `snapshot`.
  newIterator(snapshot: number | nil): any
    local snap: number = self.lastSequence
    if snapshot ~= nil then snap = snapshot end

    local children: any[] = {}
    children[#children + 1] = self.mem:iterator()
    local l0: FileMeta[] = self.versions:levelFiles(0)
    for i: number = 1, #l0 do
      children[#children + 1] = self:openTable(l0[i].number):iterator()
    end
    local level: number = 1
    while level < NUM_LEVELS do
      local files: FileMeta[] = self.versions:levelFiles(level)
      for i: number = 1, #files do
        children[#children + 1] = self:openTable(files[i].number):iterator()
      end
      level = level + 1
    end

    local merged: any = merging.newMergingIterator(children)
    local state: any = {
      valid = false,
      key = "",
      value = "",
      lastUser = "",
    }

    local function skipToVisible(): void
      state.valid = false
      while merged:valid() do
        local parsed: Parsed = codec.parseInternalKey(merged:key())
        if parsed.sequence > snap then
          merged:next()
        elseif parsed.userKey == state.lastUser then
          merged:next()
        elseif parsed.valueType == codec.TYPE_DELETION then
          state.lastUser = parsed.userKey
          merged:next()
        else
          state.valid = true
          state.key = parsed.userKey
          state.value = merged:value()
          return
        end
      end
    end

    local it: any = {}
    function it.valid(): boolean return state.valid end
    function it.key(): string return state.key end
    function it.value(): string return state.value end
    function it.seekToFirst(): void
      merged:seekToFirst()
      state.lastUser = ""
      skipToVisible()
    end
    function it.seek(_self: any, target: string): void
      local probe: string = codec.internalKey(target, snap, codec.TYPE_VALUE)
      merged:seek(probe)
      state.lastUser = ""
      skipToVisible()
    end
    function it.next(): void
      if not state.valid then return end
      state.lastUser = state.key
      merged:next()
      skipToVisible()
    end
    function it.close(): void end
    return it
  end,

  property(name: string): string
    if name == "leveldb.stats" then
      local out: string[] = {}
      out[#out + 1] = "level files size(MB)"
      local level: number = 0
      while level < NUM_LEVELS do
        local files: FileMeta[] = self.versions:levelFiles(level)
        local size: number = 0
        for i: number = 1, #files do size = size + files[i].size end
        out[#out + 1] = string.format("  %d %d %.1f", level, #files, size / (1024 * 1024))
        level = level + 1
      end
      out[#out + 1] = "approximate memory usage: " .. tostring(self.mem:approximateMemory())
      return table.concat(out, "\n")
    end
    if name == "leveldb.approximate-memory-usage" then
      return tostring(self.mem:approximateMemory())
    end
    if string.sub(name, 1, 26) == "leveldb.num-files-at-level" then
      local levelText: string = string.sub(name, 27)
      local level: number = 0
      local okNum: boolean = true
      if levelText == "" then okNum = false end
      if okNum then
        local parsedLevel: number | nil = tonumber(levelText)
        if parsedLevel ~= nil then level = parsedLevel end
      end
      if level < 0 or level >= NUM_LEVELS then return "0" end
      return tostring(#self.versions:levelFiles(level))
    end
    return ""
  end,

  --- Closes the DB. Unflushed data stays in the WAL by design; the next
  --- open replays it, which is exactly the crash-recovery path.
  close(): void
    if self.closed then return end
    self.closed = true
    self.tables = {}
  end,
}

--- Creates a fresh manifest and CURRENT pointer.
local function createFresh(path: string): (number, Error | nil)
  local manifestNumber: number = 1
  local edit: VersionEdit = version_edit.newEdit()
  edit.comparator = COMPARATOR_NAME
  edit.logNumber = 0
  edit.nextFileNumber = 2
  edit.lastSequence = 0
  local writer = log.newWriter()
  writer:addRecord(version_edit.encode(edit))
  local writeErr: Error | nil = fs.writeFile(joinPath(path, manifestName(manifestNumber)), writer:drain())
  if writeErr ~= nil then return 0, writeErr end

  local tmp: string = joinPath(path, "CURRENT.tmp")
  local curErr: Error | nil = fs.writeFile(tmp, manifestName(manifestNumber) .. "\n")
  if curErr ~= nil then return 0, curErr end
  local renameErr: Error | nil = fs.rename(tmp, joinPath(path, CURRENT))
  if renameErr ~= nil then return 0, renameErr end
  return manifestNumber, nil
end

--- Reads a manifest file and applies every edit.
local function loadManifest(path: string, manifestNumber: number, versions: any): Error | nil
  local res = fs.readFile(joinPath(path, manifestName(manifestNumber)))
  if res.err ~= nil then return res.err end
  local records: LogRead = log.readRecords(res.data)
  if records.err ~= nil then return records.err end
  if records.truncated > 0 then
    return errors.corruption("manifest " .. manifestName(manifestNumber) .. " has a torn tail")
  end
  for i: number = 1, #records.records do
    local decoded: DecodedEdit = version_edit.decode(records.records[i])
    if decoded.err ~= nil then return decoded.err end
    local comp: string | nil = decoded.edit.comparator
    if comp ~= nil and comp ~= COMPARATOR_NAME then
      return errors.invalid("manifest comparator " .. comp .. " is not supported")
    end
    versions:apply(decoded.edit)
  end
  return nil
end

local function parseManifestNumber(cur: string): number
  local digits: string | nil = string.match(cur, "^MANIFEST%-(%d+)$")
  if digits == nil then return 0 end
  local parsed: number | nil = tonumber(digits)
  if parsed == nil then return 0 end
  return parsed
end

--- Opens a database. Returns { db, err }.
local function open(path: string, userOpts: any): OpenResult
  local opts: Options = options.withDefaults(userOpts)

  if opts.createIfMissing then
    local mkErr: Error | nil = fs.mkdirp(path)
    if mkErr ~= nil then return { db = nil, err = mkErr } end
  end

  local currentRes = fs.readTrimmed(joinPath(path, CURRENT))
  local manifestNumber: number = 0
  local fresh: boolean = currentRes.err ~= nil
  if fresh then
    if not opts.createIfMissing then
      return { db = nil, err = errors.notFound("database at " .. path) }
    end
    local createErr: Error | nil = nil
    manifestNumber, createErr = createFresh(path)
    if createErr ~= nil then return { db = nil, err = createErr } end
  else
    if opts.errorIfExists then
      return { db = nil, err = errors.invalid("database already exists at " .. path) }
    end
    manifestNumber = parseManifestNumber(currentRes.data)
    if manifestNumber == 0 then
      return { db = nil, err = errors.corruption("CURRENT points at an invalid manifest") }
    end
  end

  local versions = version_set.VersionSet.new()
  versions.manifestNumber = manifestNumber
  local loadErr: Error | nil = loadManifest(path, manifestNumber, versions)
  if loadErr ~= nil then return { db = nil, err = loadErr } end

  local db = DB.new(path, opts, versions, joinPath(path, manifestName(manifestNumber)))
  local recoveredLogs: string[] = {}
  local mem: any = db.mem
  local maxSeq: number = versions.lastSequence
  local n: number = versions.logNumber
  while n < versions.nextFileNumber do
    local lp: string = joinPath(path, logName(n))
    local bytes = fs.readFile(lp)
    if bytes.err == nil then
      local parsedLog: LogRead = log.readRecords(bytes.data)
      if parsedLog.err ~= nil then return { db = nil, err = parsedLog.err } end
      for i: number = 1, #parsedLog.records do
        local decoded: ParsedBatch = batchmod.decode(parsedLog.records[i])
        if decoded.err ~= nil then return { db = nil, err = decoded.err } end
        local batch: any = decoded.batch
        local appliedSeq: number = batch:replay(decoded.sequence, function(s: number, kind: number, key: string, value: string): void
          mem:add(s, kind, key, value)
        end)
        if appliedSeq - 1 > maxSeq then maxSeq = appliedSeq - 1 end
      end
      recoveredLogs[#recoveredLogs + 1] = lp
    end
    n = n + 1
  end
  db.lastSequence = util.max(maxSeq, versions.lastSequence)
  versions.lastSequence = db.lastSequence

  -- Start a new WAL, then flush anything recovered into L0.
  local newLog: number = versions.nextFileNumber
  versions.nextFileNumber = newLog + 1
  local createErr2: Error | nil = fs.writeFile(joinPath(path, logName(newLog)), "")
  if createErr2 ~= nil then return { db = nil, err = createErr2 } end

  if mem:count() > 0 then
    local flushErr: Error | nil = db:flushToLog(newLog, "")
    if flushErr ~= nil then return { db = nil, err = flushErr } end
  else
    local edit: VersionEdit = version_edit.newEdit()
    edit.logNumber = newLog
    edit.nextFileNumber = versions.nextFileNumber
    edit.lastSequence = versions.lastSequence
    local editErr: Error | nil = db:writeEdit(edit)
    if editErr ~= nil then return { db = nil, err = editErr } end
    versions:apply(edit)
    db.logNumber = newLog
    db.logPath = joinPath(path, logName(newLog))
    db.logWriter = log.newWriter()
  end

  for i: number = 1, #recoveredLogs do
    fs.remove(recoveredLogs[i])
  end
  return { db = db, err = nil }
end

--- Reads the manifest (if any) just to learn the file-number watermark.
local function inferNextFile(path: string): number
  local currentRes = fs.readTrimmed(joinPath(path, CURRENT))
  if currentRes.err ~= nil then return 0 end
  local manifestNumber: number = parseManifestNumber(currentRes.data)
  if manifestNumber == 0 then return 0 end
  local versions = version_set.VersionSet.new()
  local err: Error | nil = loadManifest(path, manifestNumber, versions)
  if err ~= nil then return 0 end
  return versions.nextFileNumber
end

--- Removes every file that belongs to the database at `path`.
local function destroy(path: string): Error | nil
  local watermark: number = inferNextFile(path)
  if watermark <= 0 then watermark = 1000 end
  local n: number = 1
  while n < watermark + 1 do
    fs.remove(joinPath(path, tableName(n)))
    fs.remove(joinPath(path, logName(n)))
    n = n + 1
  end
  fs.remove(joinPath(path, CURRENT))
  fs.remove(joinPath(path, "CURRENT.tmp"))
  fs.remove(joinPath(path, LOCK))
  fs.remove(joinPath(path, LOG))
  -- Manifests are numbered from the same sequence; probe a small window.
  local m: number = 1
  while m < watermark + 16 do
    fs.remove(joinPath(path, manifestName(m)))
    m = m + 1
  end
  return nil
end

--- Rebuilds a manifest from the table files that survived a crash.
---
--- Tables are adopted at L0 (their levels cannot be reconstructed safely
--- without the old manifest). Surviving WALs are replayed into one fresh L0
--- table before being deleted, so a crash without a manifest still keeps
--- the writes that never reached a table.
local function repair(path: string): Error | nil
  local watermark: number = inferNextFile(path)
  if watermark <= 0 then watermark = 4096 end

  local versions = version_set.VersionSet.new()
  versions.manifestNumber = watermark
  local edit: VersionEdit = version_edit.newEdit()
  edit.comparator = COMPARATOR_NAME
  edit.nextFileNumber = watermark
  edit.lastSequence = 0

  local maxSeq: number = 0
  local recovered: any = memtable.MemTable.new()
  local n: number = 1
  while n < watermark do
    local tp: string = joinPath(path, tableName(n))
    local res = fs.readFile(tp)
    if res.err == nil then
      local reader = tablemod.TableReader.new(res.data, { verifyChecksums = true })
      local it = reader:iterator()
      it:seekToFirst()
      local smallest: string = ""
      local largest: string = ""
      local hasFirst: boolean = false
      while it:valid() do
        local key: string = it:key()
        if not hasFirst then
          smallest = key
          hasFirst = true
        end
        largest = key
        local parsed: Parsed = codec.parseInternalKey(key)
        if parsed.sequence > maxSeq then maxSeq = parsed.sequence end
        it:next()
      end
      if hasFirst then
        table.insert(edit.newFiles, {
          level = 0,
          meta = { number = n, size = #res.data, smallest = smallest, largest = largest },
        })
      end
    end

    local lp: string = joinPath(path, logName(n))
    local logRes = fs.readFile(lp)
    if logRes.err == nil then
      local records: LogRead = log.readRecords(logRes.data)
      if records.err ~= nil then return records.err end
      for i: number = 1, #records.records do
        local decoded: ParsedBatch = batchmod.decode(records.records[i])
        if decoded.err ~= nil then return decoded.err end
        local batch: any = decoded.batch
        local nextSeq: number = batch:replay(decoded.sequence, function(seq: number, kind: number, key: string, value: string): void
          recovered:add(seq, kind, key, value)
        end)
        if nextSeq - 1 > maxSeq then maxSeq = nextSeq - 1 end
      end
    end
    n = n + 1
  end

  local tableNumber: number = watermark
  if recovered:count() > 0 then
    local builder = tablemod.TableBuilder.new({
      blockSize = 4096,
      blockRestartInterval = 16,
      bitsPerKey = 10,
    })
    local it = recovered:iterator()
    it:seekToFirst()
    local smallest: string = ""
    local largest: string = ""
    local hasFirst: boolean = false
    while it:valid() do
      local key: string = it:key()
      if not hasFirst then
        smallest = key
        hasFirst = true
      end
      largest = key
      builder:add(key, it:value())
      it:next()
    end
    local data: string = builder:finish()
    local writeErr: Error | nil = fs.writeFile(joinPath(path, tableName(tableNumber)), data)
    if writeErr ~= nil then return writeErr end
    table.insert(edit.newFiles, {
      level = 0,
      meta = { number = tableNumber, size = #data, smallest = smallest, largest = largest },
    })
  end

  edit.lastSequence = maxSeq
  local manifestNumber: number = tableNumber + 1
  edit.nextFileNumber = manifestNumber + 1
  edit.logNumber = manifestNumber + 1
  versions:apply(edit)

  local writer = log.newWriter()
  writer:addRecord(version_edit.encode(edit))
  local manifestErr: Error | nil = fs.writeFile(joinPath(path, manifestName(manifestNumber)), writer:drain())
  if manifestErr ~= nil then return manifestErr end
  local tmp: string = joinPath(path, "CURRENT.tmp")
  local curErr: Error | nil = fs.writeFile(tmp, manifestName(manifestNumber) .. "\n")
  if curErr ~= nil then return curErr end
  local renameErr: Error | nil = fs.rename(tmp, joinPath(path, CURRENT))
  if renameErr ~= nil then return renameErr end

  -- Logs are now represented by the recovered table.
  n = 0
  while n < watermark do
    fs.remove(joinPath(path, logName(n)))
    n = n + 1
  end
  return nil
end

return {
  open = open,
  destroy = destroy,
  repair = repair,
  DB = DB,
}
