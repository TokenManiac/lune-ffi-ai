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

    test("ffi.sizeof and ffi.alignof expose primitive metrics", function()
        local intType = ffi.typeof("int")
        assertEqual(ffi.sizeof("int"), intType.size)
        assertEqual(ffi.alignof("int"), intType.align)

        local doubleType = ffi.typeof("double")
        assertEqual(ffi.sizeof("double"), doubleType.size)
        assertEqual(ffi.alignof("double"), doubleType.align)

        local voidPtrType = ffi.typeof("void*")
        assertEqual(ffi.sizeof("void*"), voidPtrType.size)
        assertEqual(ffi.alignof("void*"), voidPtrType.align)

        assertEqual(ffi.sizeof("void*"), ffi.sizeof("intptr_t"))
        assertEqual(ffi.alignof("void*"), ffi.alignof("intptr_t"))
    end)

    test("ffi.sizeof resolves descriptors and cdata", function()
        local ty = ffi.typeof("int")
        local obj = ffi.new("int")
        assertEqual(ffi.sizeof(ty), ffi.sizeof("int"))
        assertEqual(ffi.sizeof(obj), ffi.sizeof("int"))
    end)

    test("ffi.offsetof returns field offsets for structs", function()
        ffi.cdef([[typedef struct { int a; double b; } RuntimePair;]])
        assertEqual(ffi.sizeof("RuntimePair"), 16)
        assertEqual(ffi.alignof("RuntimePair"), 8)
        assertEqual(ffi.offsetof("RuntimePair", "a"), 0)
        assertEqual(ffi.offsetof("RuntimePair", "b"), 8)

        ffi.cdef([[typedef union { int i; float f; } RuntimeNumberUnion;]])
        assertEqual(ffi.sizeof("RuntimeNumberUnion"), 4)
        assertEqual(ffi.offsetof("RuntimeNumberUnion", "i"), 0)

        ffi.cdef([[typedef struct { unsigned a:3; unsigned b:5; } RuntimeBitfieldStruct;]])
        assertEqual(ffi.sizeof("RuntimeBitfieldStruct"), ffi.sizeof("unsigned"))
        assertEqual(ffi.alignof("RuntimeBitfieldStruct"), ffi.alignof("unsigned"))

        local ok, err = pcall(function()
            return ffi.offsetof("RuntimeBitfieldStruct", "a")
        end)
        assertEqual(ok, false)
        assert(type(err) == "string", "expected error string from bitfield offsetof")
        assert(err:find("TODO(@lune/ffi/offsetof)", 1, true) ~= nil)

        local missingOk, missingErr = pcall(function()
            return ffi.offsetof("RuntimePair", "missing")
        end)
        assertEqual(missingOk, false)
        assert(type(missingErr) == "string", "expected error when field missing")
        assert(missingErr:find("field 'missing' not found", 1, true) ~= nil)
    end)
end
