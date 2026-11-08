--- Minimal test harness: zero dependencies, deterministic output, and
--- exit-code friendly (run_tests.tl turns the counters into an exit status).
---
--- Every assertion records a failure without aborting the suite, so one run
--- reports all broken expectations instead of only the first.

local state = {
  suite = "",
  passed = 0,
  failed = 0,
  failures = {} as string[],
}

local function section(name: string): void
  state.suite = name
  print("  · " .. name)
end

local function describe(where: string): string
  if where == "" then
    return state.suite
  end
  return state.suite .. " / " .. where
end

local function ok(cond: boolean, where: string): void
  if cond then
    state.passed = state.passed + 1
  else
    state.failed = state.failed + 1
    table.insert(state.failures, describe(where) .. ": expected true")
    print("    FAIL " .. describe(where))
  end
end

local function eq(actual: any, expected: any, where: string): void
  if actual == expected then
    state.passed = state.passed + 1
  else
    state.failed = state.failed + 1
    local msg: string = describe(where) .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)
    table.insert(state.failures, msg)
    print("    FAIL " .. msg)
  end
end

local function neq(actual: any, unexpected: any, where: string): void
  if actual ~= unexpected then
    state.passed = state.passed + 1
  else
    state.failed = state.failed + 1
    local msg: string = describe(where) .. ": did not expect " .. tostring(unexpected)
    table.insert(state.failures, msg)
    print("    FAIL " .. msg)
  end
end

--- Compares two byte strings for exact equality (same as eq but documents
--- intent when binary payloads are involved).
local function eqBytes(actual: string, expected: string, where: string): void
  eq(actual, expected, where)
end

--- Runs `fn` and asserts it raises. Returns the error value as a string.
local function raises(fn: () -> void, where: string): string
  local okCall, err = pcall(fn)
  if okCall then
    state.failed = state.failed + 1
    table.insert(state.failures, describe(where) .. ": expected an error")
    print("    FAIL " .. describe(where) .. ": expected an error")
    return ""
  end
  state.passed = state.passed + 1
  return tostring(err)
end

local function passed(): number
  return state.passed
end

local function failed(): number
  return state.failed
end

local function failures(): string[]
  return state.failures
end

return {
  section = section,
  ok = ok,
  eq = eq,
  neq = neq,
  eqBytes = eqBytes,
  raises = raises,
  passed = passed,
  failed = failed,
  failures = failures,
}
