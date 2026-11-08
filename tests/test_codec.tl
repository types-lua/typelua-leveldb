--- Codec tests: varints, fixed-width integers, internal-key ordering.
--- Reference values follow LevelDB's encoding byte for byte.

type Parsed = { userKey: string, sequence: number, valueType: number }

local H = require("tests.harness")
local codec = require("leveldb.codec")
local util = require("leveldb.util")

local function run(): void
  H.section("varint")

  H.eq(codec.varint(0), "\0", "0")
  H.eq(codec.varint(1), "\1", "1")
  H.eq(codec.varint(127), "\127", "127")
  H.eqBytes(codec.varint(128), "\128\1", "128")
  H.eqBytes(codec.varint(300), "\172\2", "300")
  H.eqBytes(codec.varint(16383), "\255\127", "16383")
  H.eqBytes(codec.varint(16384), "\128\128\1", "16384")
  H.eqBytes(codec.varint(4294967295), "\255\255\255\255\15", "2^32-1")

  local samples: number[] = { 0, 1, 2, 63, 64, 127, 128, 129, 255, 256, 300, 16383, 16384, 1e9, 2 ^ 40, 2 ^ 52 }
  for i: number = 1, #samples do
    local v: number = samples[i]
    local encoded: string = codec.varint(v)
    local decoded, pos = codec.getVarint(encoded, 1)
    H.eq(decoded, v, "roundtrip " .. tostring(v))
    H.eq(pos, #encoded + 1, "roundtrip pos " .. tostring(v))
  end

  H.section("length-prefixed slices")
  local blob: string = codec.lengthPrefixed("abc") .. codec.lengthPrefixed("")
  local s1, p1 = codec.getLengthPrefixed(blob, 1)
  local s2, p2 = codec.getLengthPrefixed(blob, p1)
  H.eq(s1, "abc", "first slice")
  H.eq(s2, "", "empty slice")
  H.eq(p2, #blob + 1, "consumed")

  H.section("fixed integers")
  H.eqBytes(util.putFixed32(0), "\0\0\0\0", "fixed32 zero")
  H.eqBytes(util.putFixed32(0x78563412), "\18\52\86\120", "fixed32 LE")
  H.eq(util.decodeFixed32(util.putFixed32(0xDEADBEEF), 1), 0xDEADBEEF, "fixed32 roundtrip")
  H.eq(util.decodeFixed64(util.putFixed64(2 ^ 40 + 7), 1), 2 ^ 40 + 7, "fixed64 roundtrip")

  H.section("internal keys")
  local k1: string = codec.internalKey("user", 10, codec.TYPE_VALUE)
  local k2: string = codec.internalKey("user", 9, codec.TYPE_VALUE)
  local k3: string = codec.internalKey("user", 10, codec.TYPE_DELETION)
  local k4: string = codec.internalKey("usa", 999, codec.TYPE_VALUE)

  H.eq(#k1, #"user" + 8, "internal key length")
  local parsed: Parsed = codec.parseInternalKey(k1)
  H.eq(parsed.userKey, "user", "parse user key")
  H.eq(parsed.sequence, 10, "parse sequence")
  H.eq(parsed.valueType, codec.TYPE_VALUE, "parse type")

  H.ok(codec.compareInternal(k1, k2) < 0, "newer sequence sorts first")
  H.ok(codec.compareInternal(k3, k1) > 0, "deletion sorts after value at same seq")
  H.ok(codec.compareInternal(k2, k4) > 0, "user key order dominates")
  H.eq(codec.compareInternal(k1, k1), 0, "self comparison")
  H.ok(codec.isDeletion(k3), "deletion detection")
  H.ok(not codec.isDeletion(k1), "value detection")

  H.section("malformed input")
  H.raises(function(): void
    local _ = codec.parseInternalKey("short")
  end, "short internal key")
  H.raises(function(): void
    local _ = codec.getVarint("\128\128", 1)
  end, "truncated varint")
end

return { run = run }
