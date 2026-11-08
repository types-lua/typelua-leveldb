--- SSTable: immutable sorted table with index, bloom filter and footer.
---
--- File layout (LevelDB compatible):
---   data blocks (prefix-compressed, CRC trailer)
---   filter block
---   metaindex block (entry: "filter.leveldb.BuiltinBloomFilter2" -> handle)
---   index block (last key of each data block -> handle)
---   footer: metaindex handle, index handle, zero padding, magic
---
--- Every block is followed by a 5-byte trailer: compression type (0 = none)
--- and a masked CRC32C over the block bytes plus the type byte.

local blockmod = require("leveldb_block")
local bloommod = require("leveldb_bloom")
local codec = require("leveldb_codec")
local crc32c = require("leveldb_crc32c")
local errors = require("leveldb_errors")
local filtermod = require("leveldb_filter")
local util = require("leveldb_util")

type Error = {
  code: string,
  message: string,
}

type VarintResult = {
  value: number,
  pos: number,
  ok: boolean,
}

type Compare = (a: string, b: string) -> number

type Handle = {
  offset: number,
  size: number,
}

local MAGIC: string = "\87\251\128\139\36\117\71\219" -- 0xdb4775248b80fb57 LE
local FOOTER_SIZE: number = 48
local TRAILER_SIZE: number = 5
local COMPRESSION_NONE: number = 0

--- Lookup states shared with the DB layer.
local MISSING: number = 0
local FOUND: number = 1
local DELETED: number = 2

type Lookup = {
  state: number,
  value: string,
}

type ParsedKey = {
  userKey: string,
  sequence: number,
  valueType: number,
}

type TableOptions = {
  blockSize: number,
  blockRestartInterval: number,
  bitsPerKey: number, -- 0 disables the filter block
}

type ReaderOptions = {
  verifyChecksums: boolean,
}

local function defaultTableOptions(): TableOptions
  return { blockSize = 4096, blockRestartInterval = 16, bitsPerKey = 10 }
end

local function defaultReaderOptions(): ReaderOptions
  return { verifyChecksums = true }
end

local function encodeHandle(handle: Handle): string
  return codec.varint(handle.offset) .. codec.varint(handle.size)
end

local function decodeHandle(data: string, pos: number): (Handle, number)
  local offsetRes: VarintResult = codec.readVarint(data, pos)
  if not offsetRes.ok then error("footer: bad handle offset") end
  local sizeRes: VarintResult = codec.readVarint(data, offsetRes.pos)
  if not sizeRes.ok then error("footer: bad handle size") end
  return { offset = offsetRes.value, size = sizeRes.value }, sizeRes.pos
end

class TableBuilder {
  opts: TableOptions,
  blocks: string[],
  offset: number,
  dataBlock: any,
  indexBlock: any,
  filterBlock: any,
  lastKey: string,
  finished: boolean,

  constructor(opts: TableOptions)
    self.opts = opts
    self.blocks = {}
    self.offset = 0
    self.dataBlock = blockmod.BlockBuilder.new(opts.blockRestartInterval)
    self.indexBlock = blockmod.BlockBuilder.new(opts.blockRestartInterval)
    if opts.bitsPerKey > 0 then
      self.filterBlock = filtermod.FilterBlockBuilder.new(opts.bitsPerKey)
    else
      self.filterBlock = nil
    end
    self.lastKey = ""
    self.finished = false
  end,

  --- Appends one internal key/value pair. Keys must arrive in comparator order.
  add(ikey: string, value: string): void
    -- Fail loudly on unsorted input: a table built out of order is silently
    -- unreadable (seek assumes monotonic keys), so guard at the entry point.
    local blockEmpty: boolean = self.dataBlock:isEmpty()
    local previous: string = self.lastKey
    if not blockEmpty and previous ~= "" then
      if codec.compareInternal(previous, ikey) >= 0 then
        error("table: keys must be added in ascending order")
      end
    end
    if self.dataBlock:isEmpty() then
      local fb: any = self.filterBlock
      if fb ~= nil then
        fb:startBlock(self.offset)
      end
    end
    self.dataBlock:add(ikey, value)
    local fb2: any = self.filterBlock
    if fb2 ~= nil then
      local parsed: ParsedKey = codec.parseInternalKey(ikey)
      fb2:addKey(parsed.userKey)
    end
    self.lastKey = ikey
    if self.dataBlock:currentSizeEstimate() >= self.opts.blockSize then
      self:flush()
    end
  end,

  appendRaw(s: string): void
    self.blocks[#self.blocks + 1] = s
    self.offset = self.offset + #s
  end,

  writeRawBlock(content: string): Handle
    local handle: Handle = { offset = self.offset, size = #content }
    self:appendRaw(content)
    local typeByte: string = string.char(COMPRESSION_NONE)
    local crc: number = crc32c.extend(0, content)
    crc = crc32c.extend(crc, typeByte)
    self:appendRaw(typeByte .. util.putFixed32(crc32c.mask(crc)))
    return handle
  end,

  writeBlock(builder: any): Handle
    local content: string = builder:finish()
    return self:writeRawBlock(content)
  end,

  flush(): void
    if self.dataBlock:isEmpty() then return end
    local lastKey: string = self.lastKey
    local handle: Handle = self:writeBlock(self.dataBlock)
    self.indexBlock:add(lastKey, encodeHandle(handle))
    self.dataBlock:reset()
    self.lastKey = ""
  end,

  finish(): string
    if self.finished then return table.concat(self.blocks) end
    self:flush()

    local metaBlock = blockmod.BlockBuilder.new(self.opts.blockRestartInterval)
    local fb: any = self.filterBlock
    if fb ~= nil then
      local filterHandle: Handle = self:writeRawBlock(fb:finish())
      metaBlock:add(filtermod.FILTER_POLICY_NAME, encodeHandle(filterHandle))
    end

    local metaHandle: Handle = self:writeBlock(metaBlock)
    local indexHandle: Handle = self:writeBlock(self.indexBlock)

    local footer: string[] = {}
    footer[#footer + 1] = encodeHandle(metaHandle)
    footer[#footer + 1] = encodeHandle(indexHandle)
    local head: string = table.concat(footer)
    local padding: string[] = {}
    while #head + #table.concat(padding) < FOOTER_SIZE - #MAGIC do
      padding[#padding + 1] = "\0"
    end
    local out: string = head .. table.concat(padding) .. MAGIC
    self.finished = true
    self:appendRaw(out)
    return table.concat(self.blocks)
  end,

  size(): number
    return self.offset
  end,
}

--- Iterates every entry by streaming data blocks through the index.
--- Implemented as a closure factory so the reader and iterator can call
--- each other without a forward type declaration.
local function newTableIterator(reader: any): any
  local indexIt: any = reader.index:iterator()
  local blockIt: any = nil
  local valid: boolean = false

  local function openCurrentBlock(seekFirst: boolean): void
    if not indexIt:valid() then
      valid = false
      blockIt = nil
      return
    end
    local handle: Handle
    local _pos: number
    handle, _pos = decodeHandle(indexIt:value(), 1)
    local blockData: string = reader:readBlock(handle)
    local dataBlock = blockmod.Block.new(blockData, codec.compareInternal)
    local it: any = dataBlock:iterator()
    if seekFirst then
      it:seekToFirst()
      valid = it:valid()
    end
    blockIt = it
  end

  local iter: any = {}

  function iter.valid(): boolean
    return valid
  end

  function iter.key(): string
    if blockIt == nil then return "" end
    return blockIt:key()
  end

  function iter.value(): string
    if blockIt == nil then return "" end
    return blockIt:value()
  end

  function iter.seekToFirst(): void
    indexIt:seekToFirst()
    openCurrentBlock(true)
    while not valid and indexIt:valid() do
      indexIt:next()
      openCurrentBlock(true)
    end
  end

  function iter.seek(_self: any, target: string): void
    indexIt:seek(target)
    openCurrentBlock(false)
    if blockIt == nil then
      valid = false
    else
      blockIt:seek(target)
      valid = blockIt:valid()
    end
    while not valid and indexIt:valid() do
      indexIt:next()
      openCurrentBlock(true)
    end
  end

  function iter.next(): void
    if not valid or blockIt == nil then return end
    blockIt:next()
    if blockIt:valid() then return end
    indexIt:next()
    openCurrentBlock(true)
  end

  return iter
end

class TableReader {
  data: string,
  index: any,
  filter: any,
  verify: boolean,

  constructor(data: string, opts: ReaderOptions)
    self.data = data
    self.verify = opts.verifyChecksums
    self.filter = nil
    if #data < FOOTER_SIZE then
      error("table: file shorter than footer")
    end
    if string.sub(data, #data - 7, #data) ~= MAGIC then
      error("table: bad magic number")
    end
    -- The footer is the last 48 bytes; its handles are relative to that
    -- window, not the file start (first bug caught by the round-trip test).
    local footerStart: number = #data - FOOTER_SIZE + 1
    local metaHandle: Handle
    local afterMeta: number
    metaHandle, afterMeta = decodeHandle(data, footerStart)
    local indexHandle: Handle
    local _afterIndex: number
    indexHandle, _afterIndex = decodeHandle(data, afterMeta)

    local indexData: string = self:readBlock(indexHandle)
    self.index = blockmod.Block.new(indexData, codec.compareInternal)

    local metaData: string = self:readBlock(metaHandle)
    local metaBlock = blockmod.Block.new(metaData, util.compareBytes)
    local metaIt = metaBlock:iterator()
    metaIt:seekToFirst()
    while metaIt:valid() do
      if metaIt:key() == filtermod.FILTER_POLICY_NAME then
        local filterHandle: Handle
        local _pos: number
        filterHandle, _pos = decodeHandle(metaIt:value(), 1)
        local filterData: string = self:readBlock(filterHandle)
        self.filter = filtermod.FilterBlock.new(filterData)
      end
      metaIt:next()
    end
  end,

  readBlock(handle: Handle): string
    local start: number = handle.offset + 1
    local stop: number = handle.offset + handle.size
    if stop + TRAILER_SIZE - 1 > #self.data or start < 1 then
      error("table: block handle out of range")
    end
    local content: string = string.sub(self.data, start, stop)
    local typeByte: number = string.byte(self.data, stop + 1)
    if typeByte ~= COMPRESSION_NONE then
      error("table: unsupported compression type " .. tostring(typeByte))
    end
    if self.verify then
      local expected: number = util.decodeFixed32(self.data, stop + 2)
      local actual: number = crc32c.extend(0, content)
      actual = crc32c.extend(actual, string.char(typeByte))
      if crc32c.mask(actual) ~= expected then
        error("table: block checksum mismatch")
      end
    end
    return content
  end,

  --- Internal lookup: finds the newest entry for userKey at <= snapshot.
  get(userKey: string, snapshot: number): Lookup
    local probe: string = codec.internalKey(userKey, snapshot, codec.TYPE_VALUE)
    local indexIt = self.index:iterator()
    indexIt:seek(probe)
    if not indexIt:valid() then
      return { state = MISSING, value = "" }
    end

    local filterBlock: any = self.filter
    if filterBlock ~= nil then
      local handle: Handle
      local _pos: number
      handle, _pos = decodeHandle(indexIt:value(), 1)
      if not filterBlock:mayMatch(handle.offset, userKey) then
        return { state = MISSING, value = "" }
      end
    end

    local handle2: Handle
    local _pos2: number
    handle2, _pos2 = decodeHandle(indexIt:value(), 1)
    local blockData: string = self:readBlock(handle2)
    local dataBlock = blockmod.Block.new(blockData, codec.compareInternal)
    local it = dataBlock:iterator()
    it:seek(probe)
    if not it:valid() then
      return { state = MISSING, value = "" }
    end
    local parsed: ParsedKey = codec.parseInternalKey(it:key())
    if parsed.userKey ~= userKey then
      return { state = MISSING, value = "" }
    end
    if parsed.valueType == codec.TYPE_DELETION then
      return { state = DELETED, value = "" }
    end
    return { state = FOUND, value = it:value() }
  end,

  iterator(): any
    return newTableIterator(self)
  end,
}

return {
  TableBuilder = TableBuilder,
  TableReader = TableReader,
  MISSING = MISSING,
  FOUND = FOUND,
  DELETED = DELETED,
  defaultTableOptions = defaultTableOptions,
  defaultReaderOptions = defaultReaderOptions,
  encodeHandle = encodeHandle,
  decodeHandle = decodeHandle,
  FOOTER_SIZE = FOOTER_SIZE,
  TRAILER_SIZE = TRAILER_SIZE,
}
