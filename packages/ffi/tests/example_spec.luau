return function(ctx)
    local ffi = ctx.ffi
    local test = ctx.test
    local assertEqual = ctx.assertEqual
    local exampleLibraryPath = ctx.exampleLibraryPath

    test("ffi.load bridges custom shared libraries", function()
        assert(type(exampleLibraryPath) == "string" and #exampleLibraryPath > 0, "expected example library path")

        ffi.cdef([[typedef int (*ExampleCallback)(int);

int example_add_ints(int a, int b);
const char* example_greeting(void);
void example_invoke(ExampleCallback cb, int value);
]])

        local lib = ffi.load(exampleLibraryPath)
        assert(type(lib) == "table", "ffi.load should return a library table")

        assertEqual(lib.example_add_ints(9, 5), 14)

        local greeting = ffi.string(lib.example_greeting())
        assertEqual(greeting, "Hello from libexample")

        local callbackType = ffi.typeof("ExampleCallback")
        local total = 0
        local callback = ffi.cast(callbackType, function(value)
            total += value
            return total
        end)

        lib.example_invoke(callback, 3)
        assertEqual(total, 3)

        lib.example_invoke(callback, 4)
        assertEqual(total, 7)
    end)
end
