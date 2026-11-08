--- Filter block: bloom filters keyed by data-block offset granularity.
---
--- Layout (LevelDB compatible):
---   filter bytes*
---   offsets: fixed32 per generated filter
---   arrayOffset: fixed32 pointing at the offsets array
---   baseLg: u8, log2 of the bytes covered by one filter slot
---
--- A reader maps a block offset to a slot with `offset >> baseLg`; gaps
--- (for block sizes larger than the slot) get empty filters so indices stay
--- aligned, exactly like the reference implementation.

import bloom from "./leveldb_bloom"
import util from "./leveldb_util"

local FILTER_BASE_LG: number = 11
local FILTER_BASE: number = 2 ^ FILTER_BASE_LG
local FILTER_POLICY_NAME: string = "filter.leveldb.BuiltinBloomFilter2"

class FilterBlockBuilder {
  bitsPerKey: number,
  keys: string[],
  result: string[],
  resultSize: number,
  offsets: number[],

  constructor(bitsPerKey: number)
    self.bitsPerKey = bitsPerKey
    self.keys = {}
    self.result = {}
    self.resultSize = 0
    self.offsets = {}
  end,

  --- Called with the file offset where the next data block starts.
  startBlock(blockOffset: number): void
    local filterIndex: number = util.idiv(blockOffset, FILTER_BASE)
    while filterIndex > #self.offsets do
      self:generate()
    end
  end,

  addKey(key: string): void
    table.insert(self.keys, key)
  end,

  generate(): void
    table.insert(self.offsets, self.resultSize)
    if #self.keys == 0 then
      return
    end
    local filter: string = bloom.create(self.keys, self.bitsPerKey)
    self.result[#self.result + 1] = filter
    self.resultSize = self.resultSize + #filter
    self.keys = {}
  end,

  finish(): string
    if #self.offsets == 0 and #self.keys == 0 then
      return ""
    end
    self:generate()
    local arrayOffset: number = self.resultSize
    local out: string[] = self.result
    for i: number = 1, #self.offsets do
      out[#out + 1] = util.putFixed32(self.offsets[i])
    end
    out[#out + 1] = util.putFixed32(arrayOffset)
    out[#out + 1] = string.char(FILTER_BASE_LG)
    return table.concat(out)
  end,
}

class FilterBlock {
  contents: string,
  baseLg: number,
  arrayOffset: number,
  numFilters: number,

  constructor(contents: string)
    self.contents = contents
    self.baseLg = FILTER_BASE_LG
    self.arrayOffset = 0
    self.numFilters = 0
    if #contents < 5 then
      return
    end
    self.baseLg = string.byte(contents, #contents)
    self.arrayOffset = util.decodeFixed32(contents, #contents - 4)
    if self.arrayOffset < 0 or self.arrayOffset > #contents - 5 then
      self.numFilters = 0
      return
    end
    self.numFilters = util.idiv(#contents - 5 - self.arrayOffset, 4)
  end,

  --- Conservative: true when the key may be present or no filter exists.
  mayMatch(blockOffset: number, key: string): boolean
    if self.numFilters == 0 then return true end
    local index: number = util.idiv(blockOffset, 2 ^ self.baseLg)
    if index >= self.numFilters then return true end
    local start: number = util.decodeFixed32(self.contents, self.arrayOffset + index * 4 + 1)
    local limit: number
    if index + 1 == self.numFilters then
      limit = self.arrayOffset
    else
      limit = util.decodeFixed32(self.contents, self.arrayOffset + (index + 1) * 4 + 1)
    end
    if start > limit or limit > self.arrayOffset then return true end
    local filter: string = string.sub(self.contents, start + 1, limit)
    return bloom.mayMatch(key, filter)
  end,
}

return {
  FilterBlockBuilder = FilterBlockBuilder,
  FilterBlock = FilterBlock,
  FILTER_POLICY_NAME = FILTER_POLICY_NAME,
  FILTER_BASE_LG = FILTER_BASE_LG,
}
