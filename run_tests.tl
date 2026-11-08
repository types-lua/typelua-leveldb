--- Test entry point. Run with:
---   tlua run run_tests.tl          (embedded golua, no setup)
---   tlua build && lua5.4 dist/run_tests.lua
--- Exits non-zero when any assertion fails.

import H from "tests.harness"
import CodecTests from "tests.test_codec"
import BloomCrcTests from "tests.test_bloom_crc"
import StorageTests from "tests.test_storage"
import TableTests from "tests.test_table"
import DbTests from "tests.test_db"

local function main(): number
  print("typelua-leveldb test suite")
  CodecTests.run()
  BloomCrcTests.run()
  StorageTests.run()
  TableTests.run()
  DbTests.run()

  local passed: number = H.passed()
  local failed: number = H.failed()
  print("")
  print(string.format("passed: %d, failed: %d", passed, failed))
  if failed > 0 then
    print("failures:")
    local list: string[] = H.failures()
    for i: number = 1, #list do
      print("  - " .. list[i])
    end
    return 1
  end
  print("OK")
  return 0
end

os.exit(main())
