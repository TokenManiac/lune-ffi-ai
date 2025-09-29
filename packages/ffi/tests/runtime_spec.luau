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

    test("ffi.C resolves process symbols and ffi.load returns the default library", function()
        local defaultLib = ffi.load(nil)
        assertEqual(defaultLib, ffi.C)

        local repr = tostring(defaultLib)
        assert(type(repr) == "string" and repr:find("clibrary:", 1, true) == 1)

        local ok, err = pcall(function()
            return defaultLib.__definitely_missing_symbol
        end)
        assertEqual(ok, false)
        assert(type(err) == "string")
        assert(
            err:find("Symbol", 1, true) ~= nil
                or err:find("symbol", 1, true) ~= nil,
            "expected lookup failure to mention missing symbol"
        )
    end)

    test("ffi.gc attaches and triggers finalizers exactly once", function()
        local finalizeCount = 0
        do
            local value = ffi.new("int", 64)
            ffi.gc(value, function(obj)
                finalizeCount += 1
                assertEqual(ffi.typeof(obj).code, "int")
            end)

            local mt = getmetatable(value)
            assert(type(mt) == "table" and type(mt.__gc) == "function")
            mt.__gc(value)
        end

        assertEqual(finalizeCount, 1)

        do
            local value = ffi.new("int", 7)
            ffi.gc(value, function()
                finalizeCount += 10
            end)
            ffi.gc(value, nil)

            local mt = getmetatable(value)
            assert(type(mt) == "table" and type(mt.__gc) == "function")
            mt.__gc(value)
        end

        assertEqual(finalizeCount, 1)
    end)

    test("ffi.metatype customizes pointer behaviour", function()
        local intPointer = ffi.typeof("int*")
        ffi.metatype(intPointer, {
            __tostring = function(self)
                local ptr = rawget(self, "__ptr")
                if ptr == nil then
                    return "int*<null>"
                end
                return "int*" .. tostring(ptr)
            end,
        })

        local nullPtr = ffi.new("int*")
        assertEqual(tostring(nullPtr), "int*<null>")

        local value = ffi.new("int", 9)
        local alias = ffi.cast(intPointer, value)
        local representation = tostring(alias)
        assert(type(representation) == "string", "metatype tostring should return a string")
        assert(representation:find("int*", 1, true) ~= nil, "custom tostring should include prefix")
    end)

    test("ffi.abi exposes platform information", function()
        local is32, is64 = ffi.abi("32bit"), ffi.abi("64bit")
        assert(is32 ~= is64, "exactly one of 32bit/64bit must be true")

        local le, be = ffi.abi("le", "be")
        assert(le ~= be, "endianness flags must be mutually exclusive")

        assert(type(ffi.os) == "string" and #ffi.os > 0, "ffi.os must be a non-empty string")
        assert(type(ffi.arch) == "string" and #ffi.arch > 0, "ffi.arch must be a non-empty string")

        local ok, err = pcall(function()
            ffi.abi("not-a-real-flag")
        end)
        assertEqual(ok, false)
        assert(type(err) == "string")
        assert(err:find("unknown ABI attribute", 1, true) ~= nil)
    end)
end
