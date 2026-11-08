--- LevelDB error values.
---
--- Library convention: fallible calls return `(value, err)` and every
--- success path leaves `err` nil. Errors are plain tables (no metatables),
--- so callers can serialize or forward them freely:
---
---   local db, err = leveldb.open("./data")
---   if err ~= nil then return nil, err end
---
--- `code` is a stable lowercase string; `message` is human readable.

type Error = {
  code: string,
  message: string,
}

local function new(code: string, message: string): Error
  return { code = code, message = message }
end

local function notFound(what: string): Error
  return new("not_found", what .. " not found")
end

local function corruption(what: string): Error
  return new("corruption", what)
end

local function io(what: string): Error
  return new("io_error", what)
end

local function invalid(what: string): Error
  return new("invalid_argument", what)
end

local function busy(what: string): Error
  return new("busy", what)
end

local function closed(): Error
  return new("closed", "database is closed")
end

local function isNotFound(err: Error | nil): boolean
  if err == nil then return false end
  return err.code == "not_found"
end

local function isCorruption(err: Error | nil): boolean
  if err == nil then return false end
  return err.code == "corruption"
end

return {
  new = new,
  notFound = notFound,
  corruption = corruption,
  io = io,
  invalid = invalid,
  busy = busy,
  closed = closed,
  isNotFound = isNotFound,
  isCorruption = isCorruption,
}
