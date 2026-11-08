--- Filesystem helpers with the library's `(value, err)` convention.
---
--- Lua's io library is the lowest common denominator shared by PUC Lua,
--- LuaJIT and golua. Directory creation is the one operation it lacks, so
--- `mkdirp` falls back to os.execute when available; callers that cannot
--- spawn a shell should pre-create the database directory.
---
--- File naming follows LevelDB:
---   CURRENT                -> "MANIFEST-000123\n"
---   MANIFEST-<number>      -> version edits (log records)
---   <number>.log           -> write-ahead log
---   <number>.ldb           -> sorted table

type Error = {
  code: string,
  message: string,
}

type ReadResult = {
  data: string,
  err: Error | nil,
}

local function ioError(what: string, detail: string): Error
  return { code = "io_error", message = what .. ": " .. detail }
end

local function readFile(path: string): ReadResult
  local fh: any = io.open(path, "rb")
  if fh == nil then
    return { data = "", err = ioError("cannot open " .. path, "missing or unreadable") }
  end
  local data: any = fh:read("*a")
  fh:close()
  if type(data) ~= "string" then
    return { data = "", err = ioError("cannot read " .. path, "read failed") }
  end
  return { data = data, err = nil }
end

local function exists(path: string): boolean
  local fh: any = io.open(path, "rb")
  if fh == nil then return false end
  fh:close()
  return true
end

local function writeFile(path: string, data: string): Error | nil
  local fh: any = io.open(path, "wb")
  if fh == nil then
    return ioError("cannot create " .. path, "permission or missing directory")
  end
  local okWrite: any = fh:write(data)
  local okClose: any = fh:close()
  if okWrite == nil or okClose == nil then
    return ioError("cannot write " .. path, "write failed")
  end
  return nil
end

local function appendFile(path: string, data: string): Error | nil
  local fh: any = io.open(path, "ab")
  if fh == nil then
    return ioError("cannot append " .. path, "missing file")
  end
  local okWrite: any = fh:write(data)
  local okFlush: any = fh:flush()
  local okClose: any = fh:close()
  if okWrite == nil or okFlush == nil or okClose == nil then
    return ioError("cannot append " .. path, "write failed")
  end
  return nil
end

local function remove(path: string): Error | nil
  if not exists(path) then return nil end
  local ok: any, err: any = os.remove(path)
  if ok == nil then
    return ioError("cannot remove " .. path, tostring(err))
  end
  return nil
end

local function rename(from: string, to: string): Error | nil
  local ok: any, err: any = os.rename(from, to)
  if ok == nil then
    return ioError("cannot rename " .. from .. " to " .. to, tostring(err))
  end
  return nil
end

local function fileSize(path: string): number
  local fh: any = io.open(path, "rb")
  if fh == nil then return 0 end
  local size: any = fh:seek("end")
  fh:close()
  if type(size) == "number" then return size end
  return 0
end

--- Creates `path` and parents. Returns nil on success. Uses the shell only
--- when available; otherwise reports an actionable error.
local function mkdirp(path: string): Error | nil
  if path == "" or path == "." then return nil end
  local probe: string = path .. "/.probe"
  local fh: any = io.open(probe, "wb")
  if fh ~= nil then
    fh:close()
    os.remove(probe)
    return nil
  end
  local execute: any = os.execute
  if execute == nil then
    return ioError("cannot create directory " .. path, "os.execute unavailable")
  end
  local quoted: string = "'" .. string.gsub(path, "'", "'\\''") .. "'"
  local ok: any = execute("mkdir -p " .. quoted)
  if ok == nil or ok == false then
    return ioError("cannot create directory " .. path, "mkdir failed")
  end
  return nil
end

--- Reads a small text file and trims trailing CR/LF.
local function readTrimmed(path: string): ReadResult
  local res: ReadResult = readFile(path)
  if res.err ~= nil then return res end
  local trimmed: string = string.gsub(res.data, "[\r\n]+$", "")
  return { data = trimmed, err = nil }
end

return {
  readFile = readFile,
  readTrimmed = readTrimmed,
  exists = exists,
  writeFile = writeFile,
  appendFile = appendFile,
  remove = remove,
  rename = rename,
  fileSize = fileSize,
  mkdirp = mkdirp,
}
