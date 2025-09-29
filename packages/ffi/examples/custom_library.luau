local ffi = require("@lune/ffi")

ffi.cdef([[typedef int (*ExampleCallback)(int);

int example_add_ints(int a, int b);
const char* example_greeting(void);
void example_invoke(ExampleCallback cb, int value);
]])

local function resolveLibraryPath()
    if ffi.os == "Windows" then
        return "./example.dll"
    elseif ffi.os == "OSX" then
        return "./libexample.dylib"
    else
        return "./libexample.so"
    end
end

local lib = ffi.load(resolveLibraryPath())
print("example_add_ints:", lib.example_add_ints(7, 5))

local greeting = ffi.string(lib.example_greeting())
print("Greeting from C:", greeting)

local callbackType = ffi.typeof("ExampleCallback")
local total = 0
local callback = ffi.cast(callbackType, function(value)
    total += value
    return total
end)

lib.example_invoke(callback, 9)
print("Callback invoked", total, "time(s)")
