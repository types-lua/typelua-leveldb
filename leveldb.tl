--- In-repo entry point: `import leveldb from "leveldb"`.
---
--- When the package is installed as a dependency, `require("leveldb")`
--- resolves to `init.tl` directly; this alias keeps the same import working
--- from the repository's own tests and examples.

local M = require("init")
return M
