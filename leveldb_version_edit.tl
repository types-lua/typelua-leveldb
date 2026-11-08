--- VersionEdit: manifest records describing file set changes.
---
--- Encoding follows LevelDB's tags exactly, so manifests are portable:
---   1 comparator name (length-prefixed)
---   2 log number (varint)
---   3 next file number (varint)
---   4 last sequence (varint)
---   5 compact pointer: level + internal key
---   6 deleted file: level + file number
---   7 new file: level, number, size, smallest, largest
---   9 previous log number (legacy, ignored on read)

local codec = require("leveldb_codec")
local errors = require("leveldb_errors")
local util = require("leveldb_util")

type Error = {
  code: string,
  message: string,
}

type SliceResult = {
  value: string,
  pos: number,
  ok: boolean,
}

type VarintResult = {
  value: number,
  pos: number,
  ok: boolean,
}

type FileMeta = {
  number: number,
  size: number,
  smallest: string,
  largest: string,
}

type DeletedFile = {
  level: number,
  number: number,
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
  deleted: DeletedFile[],
  newFiles: NewFile[],
}

local TAG_COMPARATOR: number = 1
local TAG_LOG_NUMBER: number = 2
local TAG_NEXT_FILE_NUMBER: number = 3
local TAG_LAST_SEQUENCE: number = 4
local TAG_COMPACT_POINTER: number = 5
local TAG_DELETED_FILE: number = 6
local TAG_NEW_FILE: number = 7
local TAG_PREV_LOG_NUMBER: number = 9

local function newEdit(): VersionEdit
  return {
    comparator = nil,
    logNumber = nil,
    nextFileNumber = nil,
    lastSequence = nil,
    deleted = {},
    newFiles = {},
  }
end

local function putTag(out: string[], tag: number): void
  codec.putVarint(out, tag)
end

local function encode(edit: VersionEdit): string
  local out: string[] = {}
  local comp: string | nil = edit.comparator
  if comp ~= nil then
    putTag(out, TAG_COMPARATOR)
    codec.putLengthPrefixed(out, comp)
  end
  local logNum: number | nil = edit.logNumber
  if logNum ~= nil then
    putTag(out, TAG_LOG_NUMBER)
    codec.putVarint(out, logNum)
  end
  local nextNum: number | nil = edit.nextFileNumber
  if nextNum ~= nil then
    putTag(out, TAG_NEXT_FILE_NUMBER)
    codec.putVarint(out, nextNum)
  end
  local lastSeq: number | nil = edit.lastSequence
  if lastSeq ~= nil then
    putTag(out, TAG_LAST_SEQUENCE)
    codec.putVarint(out, lastSeq)
  end
  for i: number = 1, #edit.deleted do
    local del: DeletedFile = edit.deleted[i]
    putTag(out, TAG_DELETED_FILE)
    codec.putVarint(out, del.level)
    codec.putVarint(out, del.number)
  end
  for i: number = 1, #edit.newFiles do
    local nf: NewFile = edit.newFiles[i]
    putTag(out, TAG_NEW_FILE)
    codec.putVarint(out, nf.level)
    codec.putVarint(out, nf.meta.number)
    codec.putVarint(out, nf.meta.size)
    codec.putLengthPrefixed(out, nf.meta.smallest)
    codec.putLengthPrefixed(out, nf.meta.largest)
  end
  return table.concat(out)
end

type DecodeResult = {
  edit: VersionEdit,
  err: Error | nil,
}

--- Decodes one manifest record.
local function decode(data: string): DecodeResult
  local edit: VersionEdit = newEdit()
  local pos: number = 1
  while pos <= #data do
    local tagRes: VarintResult = codec.readVarint(data, pos)
    if not tagRes.ok then
      return { edit = edit, err = errors.corruption("manifest: truncated tag") }
    end
    pos = tagRes.pos
    local tag: number = tagRes.value
    if tag == TAG_COMPARATOR then
      local slice: SliceResult = codec.readLengthPrefixed(data, pos)
      if not slice.ok then
        return { edit = edit, err = errors.corruption("manifest: truncated comparator") }
      end
      edit.comparator = slice.value
      pos = slice.pos
    elseif tag == TAG_LOG_NUMBER then
      local v: VarintResult = codec.readVarint(data, pos)
      if not v.ok then return { edit = edit, err = errors.corruption("manifest: truncated log number") } end
      edit.logNumber = v.value
      pos = v.pos
    elseif tag == TAG_NEXT_FILE_NUMBER then
      local v: VarintResult = codec.readVarint(data, pos)
      if not v.ok then return { edit = edit, err = errors.corruption("manifest: truncated next file") } end
      edit.nextFileNumber = v.value
      pos = v.pos
    elseif tag == TAG_LAST_SEQUENCE then
      local v: VarintResult = codec.readVarint(data, pos)
      if not v.ok then return { edit = edit, err = errors.corruption("manifest: truncated last sequence") } end
      edit.lastSequence = v.value
      pos = v.pos
    elseif tag == TAG_COMPACT_POINTER then
      local level: VarintResult = codec.readVarint(data, pos)
      if not level.ok then return { edit = edit, err = errors.corruption("manifest: truncated pointer level") } end
      local key: SliceResult = codec.readLengthPrefixed(data, level.pos)
      if not key.ok then return { edit = edit, err = errors.corruption("manifest: truncated pointer key") } end
      pos = key.pos
    elseif tag == TAG_DELETED_FILE then
      local level: VarintResult = codec.readVarint(data, pos)
      if not level.ok then return { edit = edit, err = errors.corruption("manifest: truncated delete level") } end
      local number: VarintResult = codec.readVarint(data, level.pos)
      if not number.ok then return { edit = edit, err = errors.corruption("manifest: truncated delete number") } end
      table.insert(edit.deleted, { level = level.value, number = number.value })
      pos = number.pos
    elseif tag == TAG_NEW_FILE then
      local level: VarintResult = codec.readVarint(data, pos)
      if not level.ok then return { edit = edit, err = errors.corruption("manifest: truncated new level") } end
      local number: VarintResult = codec.readVarint(data, level.pos)
      if not number.ok then return { edit = edit, err = errors.corruption("manifest: truncated new number") } end
      local size: VarintResult = codec.readVarint(data, number.pos)
      if not size.ok then return { edit = edit, err = errors.corruption("manifest: truncated new size") } end
      local smallest: SliceResult = codec.readLengthPrefixed(data, size.pos)
      if not smallest.ok then return { edit = edit, err = errors.corruption("manifest: truncated smallest key") } end
      local largest: SliceResult = codec.readLengthPrefixed(data, smallest.pos)
      if not largest.ok then return { edit = edit, err = errors.corruption("manifest: truncated largest key") } end
      table.insert(edit.newFiles, {
        level = level.value,
        meta = {
          number = number.value,
          size = size.value,
          smallest = smallest.value,
          largest = largest.value,
        },
      })
      pos = largest.pos
    elseif tag == TAG_PREV_LOG_NUMBER then
      local v: VarintResult = codec.readVarint(data, pos)
      if not v.ok then return { edit = edit, err = errors.corruption("manifest: truncated prev log") } end
      pos = v.pos
    else
      return { edit = edit, err = errors.corruption("manifest: unknown tag " .. tostring(tag)) }
    end
  end
  return { edit = edit, err = nil }
end

return {
  newEdit = newEdit,
  encode = encode,
  decode = decode,
}
