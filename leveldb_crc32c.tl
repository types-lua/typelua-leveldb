--- CRC32C compatibility wrapper over `typelua-stdlib/crc32`.
---
--- LevelDB stamps every log record and table block with this checksum. The
--- table generation, reflected CRC arithmetic and LevelDB masking live in the
--- standard library; this module preserves the historical four-function API.

import crc from "github.com/types-lua/typelua-stdlib/crc32"

local function extend(crcValue: number, data: string): number
  return crc.crc32cExtend(math.floor(crcValue), data)
end

local function value(data: string): number
  return crc.crc32c(data)
end

local function mask(crcValue: number): number
  return crc.crc32cMask(math.floor(crcValue))
end

local function unmask(masked: number): number
  return crc.crc32cUnmask(math.floor(masked))
end

return {
  extend = extend,
  value = value,
  mask = mask,
  unmask = unmask,
}
