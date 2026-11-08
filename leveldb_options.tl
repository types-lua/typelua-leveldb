--- Database options with LevelDB-compatible defaults.
---
--- Callers pass a partial record; `withDefaults` fills the rest. Keeping
--- defaults in one place means the DB, table and compaction layers cannot
--- disagree about block size or write-buffer thresholds.

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

local function defaultOptions(): Options
  return {
    createIfMissing = true,
    errorIfExists = false,
    writeBufferSize = 4 * 1024 * 1024,
    blockSize = 4096,
    blockRestartInterval = 16,
    maxFileSize = 2 * 1024 * 1024,
    bitsPerKey = 10,
    verifyChecksums = true,
    paranoidChecks = false,
    syncWrites = false,
    l0CompactionTrigger = 4,
    levelBaseBytes = 10 * 1024 * 1024,
  }
end

--- Merges user options over defaults, validating ranges that would
--- otherwise corrupt the layout (zero sizes, negative buffers).
local function withDefaults(user: any): Options
  local out: Options = defaultOptions()
  if user == nil then return out end
  -- Explicit per-field copies: records are not indexable by dynamic keys.
  local value: any = user.createIfMissing
  if value ~= nil then out.createIfMissing = value end
  value = user.errorIfExists
  if value ~= nil then out.errorIfExists = value end
  value = user.writeBufferSize
  if value ~= nil then out.writeBufferSize = value end
  value = user.blockSize
  if value ~= nil then out.blockSize = value end
  value = user.blockRestartInterval
  if value ~= nil then out.blockRestartInterval = value end
  value = user.maxFileSize
  if value ~= nil then out.maxFileSize = value end
  value = user.bitsPerKey
  if value ~= nil then out.bitsPerKey = value end
  value = user.verifyChecksums
  if value ~= nil then out.verifyChecksums = value end
  value = user.paranoidChecks
  if value ~= nil then out.paranoidChecks = value end
  value = user.syncWrites
  if value ~= nil then out.syncWrites = value end
  value = user.l0CompactionTrigger
  if value ~= nil then out.l0CompactionTrigger = value end
  value = user.levelBaseBytes
  if value ~= nil then out.levelBaseBytes = value end
  if out.writeBufferSize < 1024 then out.writeBufferSize = 1024 end
  if out.blockSize < 64 then out.blockSize = 64 end
  if out.blockRestartInterval < 1 then out.blockRestartInterval = 1 end
  if out.maxFileSize < 4096 then out.maxFileSize = 4096 end
  if out.bitsPerKey < 0 then out.bitsPerKey = 0 end
  if out.l0CompactionTrigger < 2 then out.l0CompactionTrigger = 2 end
  if out.levelBaseBytes < 4096 then out.levelBaseBytes = 4096 end
  return out
end

return {
  defaultOptions = defaultOptions,
  withDefaults = withDefaults,
}
