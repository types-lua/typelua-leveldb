--- Write-ahead log: LevelDB's 32 KiB block record format.
---
--- Record framing (7-byte header):
---   fixed32 masked crc32c(type_byte .. payload)
---   fixed16 payload length
---   u8     record type (1 full, 2 first, 3 middle, 4 last)
--- A record larger than the remaining block space is fragmented; a block
--- tail too small for a header is zero-padded.
---
--- The writer builds an in-memory byte string; the DB decides when to
--- append it to disk (every write, on sync, and before rotation). The
--- reader tolerates a torn tail (crash before fsync) but reports checksum
--- failures as corruption, exactly like the reference implementation.

local crc32c = require("leveldb.crc32c")
local errors = require("leveldb.errors")
local util = require("leveldb.util")

type Error = {
  code: string,
  message: string,
}

local BLOCK_SIZE: number = 32768
local HEADER_SIZE: number = 7

local ZERO: number = 0
local FULL: number = 1
local FIRST: number = 2
local MIDDLE: number = 3
local LAST: number = 4

class Writer {
  buffer: string[],
  blockOffset: number,
  size: number,
  blockSize: number,

  constructor(blockSize: number)
    self.buffer = {}
    self.blockOffset = 0
    self.size = 0
    self.blockSize = blockSize
  end,

  --- Appends one logical record, fragmenting across block boundaries.
  addRecord(data: string): void
    local remaining: number = #data
    local pos: number = 1
    local begin: boolean = true
    while true do
      local leftover: number = self.blockSize - self.blockOffset
      if leftover < HEADER_SIZE then
        -- Pad the block tail with zeros; readers skip it.
        local pad: string[] = {}
        for _: number = 1, leftover do pad[#pad + 1] = "\0" end
        local padding: string = table.concat(pad)
        self.buffer[#self.buffer + 1] = padding
        self.size = self.size + #padding
        self.blockOffset = 0
        leftover = self.blockSize
      end

      local avail: number = leftover - HEADER_SIZE
      local fragmentLen: number = util.min(remaining, avail)
      local endOfRecord: boolean = fragmentLen == remaining

      local recordType: number
      if begin and endOfRecord then
        recordType = FULL
      elseif begin then
        recordType = FIRST
      elseif endOfRecord then
        recordType = LAST
      else
        recordType = MIDDLE
      end

      local fragment: string = string.sub(data, pos, pos + fragmentLen - 1)
      self:emitPhysicalRecord(recordType, fragment)
      pos = pos + fragmentLen
      remaining = remaining - fragmentLen
      begin = false
      if endOfRecord then
        break
      end
    end
  end,

  emitPhysicalRecord(recordType: number, payload: string): void
    local crc: number = crc32c.extend(0, string.char(recordType))
    crc = crc32c.extend(crc, payload)
    local header: string = util.putFixed32(crc32c.mask(crc))
      .. util.putFixed16(#payload)
      .. string.char(recordType)
    self.buffer[#self.buffer + 1] = header
    self.buffer[#self.buffer + 1] = payload
    self.size = self.size + HEADER_SIZE + #payload
    self.blockOffset = self.blockOffset + HEADER_SIZE + #payload
  end,

  contents(): string
    return table.concat(self.buffer)
  end,

  --- Returns buffered bytes and clears the buffer, keeping block framing
  --- state so fragmentation stays correct across appends.
  drain(): string
    local out: string = table.concat(self.buffer)
    self.buffer = {}
    return out
  end,

  reset(): void
    self.buffer = {}
    self.blockOffset = 0
    self.size = 0
  end,

  bytes(): number
    return self.size
  end,
}

type ReadResult = {
  records: string[],
  err: Error | nil,
  truncated: number, -- tail bytes ignored because the last record was incomplete
}

--- Reads every logical record from `data`. A checksum or structure
--- violation returns the records parsed so far plus a corruption error;
--- a torn tail (crash before fsync) is not an error.
local function readRecords(data: string): ReadResult
  local records: string[] = {}
  local pos: number = 1
  local total: number = #data
  local frags: string[] = {}
  local inFragmented: boolean = false
  local result: Error | nil = nil
  local truncated: number = 0

  while pos + HEADER_SIZE - 1 <= total do
    local blockRemaining: number = BLOCK_SIZE - ((pos - 1) % BLOCK_SIZE)
    if blockRemaining < HEADER_SIZE then
      -- Skip zero padding at the end of a block.
      pos = pos + blockRemaining
    else
      local expectedCrc: number = util.decodeFixed32(data, pos)
      local length: number = util.decodeFixed16(data, pos + 4)
      local recordType: number = string.byte(data, pos + 6)

      if expectedCrc == 0 and length == 0 and recordType == ZERO then
        -- Preallocated / zeroed block tail: skip the rest of this block.
        pos = pos + blockRemaining
      else
        local payloadStart: number = pos + HEADER_SIZE
        local payloadEnd: number = payloadStart + length - 1
        if payloadEnd > total then
          truncated = total - pos + 1
          pos = total + 1
        else
          local payload: string = string.sub(data, payloadStart, payloadEnd)
          local actual: number = crc32c.extend(0, string.char(recordType))
          actual = crc32c.extend(actual, payload)
          if crc32c.mask(actual) ~= expectedCrc then
            result = errors.corruption("log record checksum mismatch at byte " .. tostring(pos))
            return { records = records, err = result, truncated = truncated }
          end
          pos = payloadEnd + 1

          if recordType == FULL then
            if inFragmented then
              result = errors.corruption("log: full record inside fragmented record")
              return { records = records, err = result, truncated = truncated }
            end
            records[#records + 1] = payload
          elseif recordType == FIRST then
            if inFragmented then
              result = errors.corruption("log: first record inside fragmented record")
              return { records = records, err = result, truncated = truncated }
            end
            frags = { payload }
            inFragmented = true
          elseif recordType == MIDDLE then
            if not inFragmented then
              result = errors.corruption("log: middle record without first")
              return { records = records, err = result, truncated = truncated }
            end
            frags[#frags + 1] = payload
          elseif recordType == LAST then
            if not inFragmented then
              result = errors.corruption("log: last record without first")
              return { records = records, err = result, truncated = truncated }
            end
            frags[#frags + 1] = payload
            records[#records + 1] = table.concat(frags)
            frags = {}
            inFragmented = false
          else
            result = errors.corruption("log: unknown record type " .. tostring(recordType))
            return { records = records, err = result, truncated = truncated }
          end
        end
      end
    end
  end

  if pos <= total then
    truncated = total - pos + 1
  end
  return { records = records, err = nil, truncated = truncated }
end

local function newWriter(): Writer
  return Writer.new(BLOCK_SIZE)
end

return {
  Writer = Writer,
  newWriter = newWriter,
  readRecords = readRecords,
  BLOCK_SIZE = BLOCK_SIZE,
  HEADER_SIZE = HEADER_SIZE,
  FULL = FULL,
  FIRST = FIRST,
  MIDDLE = MIDDLE,
  LAST = LAST,
}
