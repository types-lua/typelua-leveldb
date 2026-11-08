--- Merging iterator: k-way merge over internal-key streams.
---
--- Used by reads (memtable + tables) and compaction (input files). All
--- children are internal iterators (valid/seek/next/key/value); ordering is
--- `codec.compareInternal`, so equal user keys come newest-sequence-first.

import codec from "./leveldb_codec"

local function newMergingIterator(children: any[]): any
  local it: any = {}
  local current: number = -1

  local function findSmallest(): void
    current = -1
    local best: string = ""
    for i: number = 1, #children do
      local child: any = children[i]
      if child:valid() then
        local key: string = child:key()
        if current < 0 or codec.compareInternal(key, best) < 0 then
          current = i
          best = key
        end
      end
    end
  end

  function it.valid(): boolean
    return current > 0
  end

  function it.key(): string
    if current <= 0 then return "" end
    return children[current]:key()
  end

  function it.value(): string
    if current <= 0 then return "" end
    return children[current]:value()
  end

  function it.seekToFirst(): void
    for i: number = 1, #children do
      children[i]:seekToFirst()
    end
    findSmallest()
  end

  function it.seek(_self: any, target: string): void
    for i: number = 1, #children do
      children[i]:seek(target)
    end
    findSmallest()
  end

  function it.next(): void
    if current <= 0 then return end
    children[current]:next()
    findSmallest()
  end

  return it
end

return { newMergingIterator = newMergingIterator }
