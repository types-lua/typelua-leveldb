--- WriteBatch: atomic groups of put/delete operations.
---
--- Wire format matches LevelDB:
---   header: fixed64 sequence, fixed32 count
---   record: u8 type, varint key, [varint value]
--- so a batch can be replayed from a WAL or handed to another
--- implementation unchanged.

import codec from "./leveldb_codec"
import errors from "./leveldb_errors"
import util from "./leveldb_util"

type Error = {
  code: string,
  message: string,
}

--- Structural copy of codec's slice result (cross-module types are not
--- addressable, so each boundary declares the shape it consumes).
type SliceResult = {
  value: string,
  pos: number,
  ok: boolean,
}

type BatchOp = {
  kind: number,  -- codec.TYPE_VALUE or codec.TYPE_DELETION
  key: string,
  value: string,
}

class WriteBatch {
  ops: BatchOp[],

  constructor()
    self.ops = {}
  end,

  put(key: string, value: string): WriteBatch
    table.insert(self.ops, { kind = codec.TYPE_VALUE, key = key, value = value })
    return self
  end,

  delete(key: string): WriteBatch
    table.insert(self.ops, { kind = codec.TYPE_DELETION, key = key, value = "" })
    return self
  end,

  count(): number
    return #self.ops
  end,

  clear(): void
    self.ops = {}
  end,

  --- Encodes with the batch's base sequence number (records get seq, seq+1, ...).
  encode(sequence: number): string
    local out: string[] = {}
    out[#out + 1] = util.putFixed64(sequence)
    out[#out + 1] = util.putFixed32(#self.ops)
    for i: number = 1, #self.ops do
      local op: BatchOp = self.ops[i]
      out[#out + 1] = string.char(op.kind)
      codec.putLengthPrefixed(out, op.key)
      if op.kind == codec.TYPE_VALUE then
        codec.putLengthPrefixed(out, op.value)
      end
    end
    return table.concat(out)
  end,

  --- Applies every op through `apply(sequence, kind, key, value)`.
  replay(sequence: number, apply: (number, number, string, string) -> void): number
    local seq: number = sequence
    for i: number = 1, #self.ops do
      local op: BatchOp = self.ops[i]
      apply(seq, op.kind, op.key, op.value)
      seq = seq + 1
    end
    return seq
  end,
}

type DecodeResult = {
  batch: WriteBatch,
  sequence: number,
  err: Error | nil,
}

--- Decodes a serialized batch. A corrupt payload yields a `corruption`
--- error and an empty batch, never a partial one.
local function decode(data: string): DecodeResult
  if #data < 12 then
    return { batch = WriteBatch.new(), sequence = 0, err = errors.corruption("write batch shorter than header") }
  end
  local sequence: number = util.decodeFixed64(data, 1)
  local count: number = util.decodeFixed32(data, 9)
  local batch: WriteBatch = WriteBatch.new()
  local pos: number = 13
  local i: number = 0
  while i < count do
    local kind: number | nil = string.byte(data, pos)
    if kind == nil then
      return { batch = WriteBatch.new(), sequence = 0, err = errors.corruption("write batch truncated at record " .. tostring(i)) }
    end
    pos = pos + 1
    local keyRes: SliceResult = codec.readLengthPrefixed(data, pos)
    if not keyRes.ok then
      return { batch = WriteBatch.new(), sequence = 0, err = errors.corruption("write batch truncated key") }
    end
    pos = keyRes.pos
    if kind == codec.TYPE_VALUE then
      local valRes: SliceResult = codec.readLengthPrefixed(data, pos)
      if not valRes.ok then
        return { batch = WriteBatch.new(), sequence = 0, err = errors.corruption("write batch truncated value") }
      end
      pos = valRes.pos
      batch:put(keyRes.value, valRes.value)
    elseif kind == codec.TYPE_DELETION then
      batch:delete(keyRes.value)
    else
      return { batch = WriteBatch.new(), sequence = 0, err = errors.corruption("unknown write batch op " .. tostring(kind)) }
    end
    i = i + 1
  end
  if pos ~= #data + 1 then
    return { batch = WriteBatch.new(), sequence = 0, err = errors.corruption("write batch has trailing bytes") }
  end
  return { batch = batch, sequence = sequence, err = nil }
end

return {
  WriteBatch = WriteBatch,
  decode = decode,
}
