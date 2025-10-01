local ffi = require("@lune/ffi")

type TestCase = {
    name: string,
    callback: () -> (),
}

local cases = {} :: { TestCase }

local function assertEqual(actual: any, expected: any, message: string?)
    if actual ~= expected then
        local prefix = if message then message .. ": " else ""
        error(prefix .. string.format("expected %s but received %s", tostring(expected), tostring(actual)), 2)
    end
end

local function test(name: string, callback: () -> ())
    if type(name) ~= "string" then
        error("test name must be a string", 2)
    end
    if type(callback) ~= "function" then
        error("test callback must be a function", 2)
    end
    table.insert(cases, { name = name, callback = callback })
end

local registry = {
    ffi = ffi,
    test = test,
    assertEqual = assertEqual,
    exampleLibraryPath = rawget(_G, "FFI_EXAMPLE_LIBRARY_PATH"),
    libcprLibraryPath = rawget(_G, "FFI_LIBCPR_LIBRARY_PATH"),
    libcprUrl = rawget(_G, "FFI_LIBCPR_TEST_URL"),
    libcprExpectedBody = rawget(_G, "FFI_LIBCPR_EXPECTED_BODY"),
}

local modules = {
    require("./cdef_spec"),
    require("./runtime_spec"),
    require("./example_spec"),
    require("./libcpr_spec"),
}

for _, register in ipairs(modules) do
    register(registry)
end

local traceback = debug.traceback

local function run()
    local failures = 0
    local output = {}

    for _, case in ipairs(cases) do
        local ok, err = xpcall(case.callback, traceback)
        if ok then
            table.insert(output, string.format("[PASS] %s", case.name))
        else
            failures += 1
            table.insert(output, string.format("[FAIL] %s", case.name))
            table.insert(output, err)
        end
    end

    for _, line in ipairs(output) do
        print(line)
    end

    if failures > 0 then
        error(string.format("%d test(s) failed", failures), 0)
    end

    print(string.format("Ran %d test(s)", #cases))
end

run()
