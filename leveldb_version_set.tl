--- Version set: the durable file layout of one database.
---
--- A Version is seven levels of immutable tables. Level 0 may overlap and
--- is ordered newest-file-first; levels 1..6 are disjoint and ordered by
--- smallest key. Compaction shrinks level N into N+1, keeping the invariant
--- that every level below 0 is sorted and non-overlapping.

import codec from "./leveldb_codec"
import util from "./leveldb_util"

type FileMeta = {
  number: number,
  size: number,
  smallest: string,
  largest: string,
}

type VersionEdit = {
  comparator: string | nil,
  logNumber: number | nil,
  nextFileNumber: number | nil,
  lastSequence: number | nil,
  deleted: { level: number, number: number }[],
  newFiles: { level: number, meta: FileMeta }[],
}

type Compaction = {
  level: number,
  inputs: FileMeta[],
  inputsNext: FileMeta[],
  smallest: string,
  largest: string,
}

local NUM_LEVELS: number = 7
local L0_COMPACTION_TRIGGER: number = 4
local MAX_FILE_SIZE: number = 2 * 1024 * 1024

--- Size budget for a level in bytes (LevelDB's defaults, scaled down only
--- by the caller through options when tests need faster compaction).
local function maxBytesForLevel(level: number, base: number): number
  local result: number = base
  local i: number = 1
  while i < level do
    result = result * 10
    i = i + 1
  end
  return result
end

class VersionSet {
  levels: FileMeta[][],
  logNumber: number,
  nextFileNumber: number,
  lastSequence: number,
  manifestNumber: number,

  constructor()
    self.levels = {}
    for i: number = 1, NUM_LEVELS do
      self.levels[i] = {}
    end
    self.logNumber = 0
    self.nextFileNumber = 2
    self.lastSequence = 0
    self.manifestNumber = 0
  end,

  apply(edit: VersionEdit): void
    local logNum: number | nil = edit.logNumber
    if logNum ~= nil then self.logNumber = logNum end
    local nextNum: number | nil = edit.nextFileNumber
    if nextNum ~= nil then self.nextFileNumber = nextNum end
    local lastSeq: number | nil = edit.lastSequence
    if lastSeq ~= nil then self.lastSequence = lastSeq end

    for i: number = 1, #edit.deleted do
      local del: { level: number, number: number } = edit.deleted[i]
      local bucket: FileMeta[] = self.levels[del.level + 1]
      local kept: FileMeta[] = {}
      for j: number = 1, #bucket do
        if bucket[j].number ~= del.number then
          kept[#kept + 1] = bucket[j]
        end
      end
      self.levels[del.level + 1] = kept
    end

    for i: number = 1, #edit.newFiles do
      local nf: { level: number, meta: FileMeta } = edit.newFiles[i]
      local bucket: FileMeta[] = self.levels[nf.level + 1]
      bucket[#bucket + 1] = nf.meta
      if nf.level == 0 then
        table.sort(bucket, function(a: FileMeta, b: FileMeta): boolean
          return a.number > b.number
        end)
      else
        table.sort(bucket, function(a: FileMeta, b: FileMeta): boolean
          return codec.compareInternal(a.smallest, b.smallest) < 0
        end)
      end
    end
  end,

  levelFiles(level: number): FileMeta[]
    return self.levels[level + 1]
  end,

  levelBytes(level: number): number
    local total: number = 0
    local files: FileMeta[] = self.levels[level + 1]
    for i: number = 1, #files do
      total = total + files[i].size
    end
    return total
  end,

  totalFiles(): number
    local total: number = 0
    for i: number = 1, NUM_LEVELS do
      total = total + #self.levels[i]
    end
    return total
  end,

  --- Files whose key range intersects [smallest, largest].
  overlapping(level: number, smallest: string, largest: string): FileMeta[]
    local out: FileMeta[] = {}
    local files: FileMeta[] = self.levels[level + 1]
    for i: number = 1, #files do
      local f: FileMeta = files[i]
      if codec.compareInternal(f.largest, smallest) >= 0 and codec.compareInternal(f.smallest, largest) <= 0 then
        out[#out + 1] = f
      end
    end
    return out
  end,

  --- Picks one compaction, or nil when every level is within budget.
  pickCompaction(l0Trigger: number, levelBaseBytes: number): Compaction | nil
    local level: number = -1
    if #self.levels[1] >= l0Trigger then
      level = 0
    else
      local candidate: number = 1
      while candidate < NUM_LEVELS - 1 do
        if self:levelBytes(candidate) > maxBytesForLevel(candidate, levelBaseBytes) then
          level = candidate
          break
        end
        candidate = candidate + 1
      end
    end
    if level < 0 then return nil end

    local files: FileMeta[] = self.levels[level + 1]
    if #files == 0 then return nil end
    local seed: FileMeta = files[1]
    local smallest: string = seed.smallest
    local largest: string = seed.largest

    local inputs: FileMeta[] = {}
    if level == 0 then
      -- All L0 files overlapping the seed range must move together.
      local all: FileMeta[] = self.levels[1]
      for i: number = 1, #all do
        local f: FileMeta = all[i]
        if codec.compareInternal(f.largest, smallest) >= 0 and codec.compareInternal(f.smallest, largest) <= 0 then
          inputs[#inputs + 1] = f
          if codec.compareInternal(f.smallest, smallest) < 0 then smallest = f.smallest end
          if codec.compareInternal(f.largest, largest) > 0 then largest = f.largest end
        end
      end
    else
      inputs[1] = seed
    end

    local inputsNext: FileMeta[] = self:overlapping(level + 1, smallest, largest)
    for i: number = 1, #inputsNext do
      local f: FileMeta = inputsNext[i]
      if codec.compareInternal(f.smallest, smallest) < 0 then smallest = f.smallest end
      if codec.compareInternal(f.largest, largest) > 0 then largest = f.largest end
    end

    return { level = level, inputs = inputs, inputsNext = inputsNext, smallest = smallest, largest = largest }
  end,
}

--- True when two files at levels >= 1 overlap (used in assertions/tests).
local function rangesOverlap(a: FileMeta, b: FileMeta): boolean
  return codec.compareInternal(a.largest, b.smallest) >= 0 and codec.compareInternal(b.largest, a.smallest) >= 0
end

return {
  VersionSet = VersionSet,
  NUM_LEVELS = NUM_LEVELS,
  L0_COMPACTION_TRIGGER = L0_COMPACTION_TRIGGER,
  MAX_FILE_SIZE = MAX_FILE_SIZE,
  maxBytesForLevel = maxBytesForLevel,
  rangesOverlap = rangesOverlap,
}
