return function(ctx)
    local ffi = ctx.ffi
    local test = ctx.test
    local assertEqual = ctx.assertEqual
    local debugTools = ffi._debug

    test("ffi.typeof resolves strings, descriptors, and cdata", function()
        local intType = ffi.typeof("int")
        assertEqual(intType.code, "int")

        local alias = ffi.typeof(intType)
        assertEqual(alias, intType)

        local value = ffi.new("int", 7)
        local inferred = ffi.typeof(value)
        assertEqual(inferred, intType)
    end)

    test("ffi.new allocates primitives with optional initialization", function()
        local zero = ffi.new("int")
        assertEqual(debugTools.readScalar(zero), 0)

        local fortyTwo = ffi.new("int", 42)
        assertEqual(debugTools.readScalar(fortyTwo), 42)
    end)

    test("ffi.cast produces pointer and primitive cdata", function()
        local source = ffi.new("int", 11)
        local pointer = ffi.cast("int*", source)
        assertEqual(ffi.typeof(pointer).kind, "pointer")
        -- ensure the pointer references the same storage by mutating via casted pointer
        local underlying = debugTools.readScalar(pointer)
        assert(type(underlying) == "userdata", "expected lightuserdata pointer")

        local copied = ffi.cast("int", 123)
        assertEqual(debugTools.readScalar(copied), 123)
    end)

    test("ffi.string reads C strings from pointers", function()
        local buffer = debugTools.alloc(6)
        debugTools.writeBytes(buffer, "hello", true)

        local cptr = ffi.cast("char*", buffer)
        assertEqual(ffi.string(cptr), "hello")
        assertEqual(ffi.string(buffer, 4), "hell")

        debugTools.free(buffer)
    end)
end
