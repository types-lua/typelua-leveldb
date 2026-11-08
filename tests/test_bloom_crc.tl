--- CRC32C and bloom cases.
---
--- Vectors were generated from the reference algorithm (Castagnoli CRC and
--- LevelDB util::Hash), so a regression in either direction is caught.

import T from "tlua_test"
import bloom from "leveldb_bloom"
import crc from "leveldb_crc32c"

return {
  ["crc32c reference vectors"] = function(): void
    T.eq(crc.value(""), 0, "empty")
    T.eq(crc.value("123456789"), 0xE3069283, "standard check vector")
    T.eq(crc.value("a"), 0xC1D04330, "one byte")
    T.eq(crc.value("hello world"), 0xC99465AA, "phrase")

    -- Streaming must equal one-shot.
    local streaming: number = crc.extend(0, "hello")
    streaming = crc.extend(streaming, " ")
    streaming = crc.extend(streaming, "world")
    T.eq(streaming, crc.value("hello world"), "streaming equals one-shot")

    -- Mask/unmask roundtrip (mask keeps zero payloads from looking valid).
    local v: number = crc.value("payload")
    T.eq(crc.unmask(crc.mask(v)), v, "unmask(mask(x))")
    T.eq(crc.mask(0), 0xA282EAD8, "masked zero")
  end,

  ["bloom hash vectors"] = function(): void
    T.eq(bloom.hash(""), 0xBC9F1D34, "empty hash")
    T.eq(bloom.hash("a"), 0x286E9DB0, "hash a")
    T.eq(bloom.hash("hello"), 0xF795964E, "hash hello")
    T.eq(bloom.hash("abcdefgh"), 0xB2CE35DD, "hash abcdefgh")
  end,

  ["bloom filter policy"] = function(): void
    T.eq(bloom.probesFor(10), 6, "probes for 10 bits")
    T.eq(bloom.probesFor(1), 1, "probes floor at 1")
    T.eq(bloom.probesFor(100), 30, "probes cap at 30")

    local keys: string[] = { "a", "b", "c" }
    local filter: string = bloom.create(keys, 10)
    T.eq(#filter, 9, "3 keys at 10 bits => 64 bits (minimum) + k")
    T.eqBytes(filter, "\150\40\1\17\16\6\65\4\6", "reference filter bytes")
    for i: number = 1, #keys do
      T.ok(bloom.mayMatch(keys[i], filter), "member " .. keys[i])
    end
    T.eq(bloom.create({}, 10), "", "empty filter")
    T.ok(bloom.mayMatch("anything", ""), "missing filter may match")

    -- False positives are allowed but must stay rare: 10 bits/key ≈ 2%.
    local filter2: string = bloom.create({ "alpha", "beta", "gamma", "delta", "epsilon" }, 10)
    local falsePositives: number = 0
    for i: number = 1, 500 do
      local probe: string = "probe-" .. tostring(i)
      if bloom.mayMatch(probe, filter2) then
        falsePositives = falsePositives + 1
      end
    end
    T.ok(falsePositives < 50, "false positives under 10% (got " .. tostring(falsePositives) .. "/500)")
  end,
}
