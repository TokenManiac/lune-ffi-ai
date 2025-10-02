return function(ctx)
    local ffi = ctx.ffi
    local test = ctx.test
    local assertEqual = ctx.assertEqual
    local debugTools = ffi._debug

    ffi.cdef([[typedef struct {
        int x;
        double y;
    } RuntimeStructInit;

    typedef struct {
        int* target;
        int flag;
    } RuntimePointerStruct;

    typedef union {
        int as_int;
        void* as_ptr;
    } RuntimeTaggedUnion;

    int luneffi_test_struct_get_x(const RuntimeStructInit* value);
    double luneffi_test_struct_get_y(const RuntimeStructInit* value);
    int luneffi_test_pointer_struct_flag(const RuntimePointerStruct* value);
    int luneffi_test_pointer_struct_read(const RuntimePointerStruct* value);
    int luneffi_test_union_int(const RuntimeTaggedUnion* value);
    int luneffi_test_union_is_ptr(const RuntimeTaggedUnion* value, void* ptr);
    ]])

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

    test("ffi.new allocates structs and unions", function()
        local pair = ffi.new("RuntimeStructInit", { x = 7, y = 3.5 })
        local pairPtr = ffi.new("RuntimeStructInit*", pair)
        assertEqual(ffi.C.luneffi_test_struct_get_x(pairPtr), 7)
        assertEqual(ffi.C.luneffi_test_struct_get_y(pairPtr), 3.5)

        local copyFromPointer = ffi.new("RuntimeStructInit", pairPtr)
        local copyPtr = ffi.new("RuntimeStructInit*", copyFromPointer)
        assertEqual(ffi.C.luneffi_test_struct_get_x(copyPtr), 7)
        assertEqual(ffi.C.luneffi_test_struct_get_y(copyPtr), 3.5)

        local positional = ffi.new("RuntimeStructInit", { 11, 9.75 })
        local positionalPtr = ffi.new("RuntimeStructInit*", positional)
        assertEqual(ffi.C.luneffi_test_struct_get_x(positionalPtr), 11)
        assertEqual(ffi.C.luneffi_test_struct_get_y(positionalPtr), 9.75)

        local storedInt = ffi.new("int", 64)
        local pointerStruct = ffi.new("RuntimePointerStruct", {
            target = storedInt,
            flag = 3,
        })
        local pointerStructPtr = ffi.new("RuntimePointerStruct*", pointerStruct)
        assertEqual(ffi.C.luneffi_test_pointer_struct_flag(pointerStructPtr), 3)
        assertEqual(ffi.C.luneffi_test_pointer_struct_read(pointerStructPtr), 64)

        local unionFromTable = ffi.new("RuntimeTaggedUnion", { as_int = 128 })
        local unionPtr = ffi.new("RuntimeTaggedUnion*", unionFromTable)
        assertEqual(ffi.C.luneffi_test_union_int(unionPtr), 128)

        local unionFromPointer = ffi.new("RuntimeTaggedUnion", { as_ptr = pointerStructPtr })
        local unionPtr2 = ffi.new("RuntimeTaggedUnion*", unionFromPointer)
        assertEqual(ffi.C.luneffi_test_union_is_ptr(unionPtr2, pointerStructPtr), 1)
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

    test("ffi.cast copies structured values", function()
        local original = ffi.new("RuntimeStructInit", { x = 21, y = 4.25 })
        local originalPtr = ffi.new("RuntimeStructInit*", original)

        local castFromPointer = ffi.cast("RuntimeStructInit", originalPtr)
        local castPtr = ffi.new("RuntimeStructInit*", castFromPointer)
        assertEqual(ffi.C.luneffi_test_struct_get_x(castPtr), 21)
        assertEqual(ffi.C.luneffi_test_struct_get_y(castPtr), 4.25)

        local castFromValue = ffi.cast("RuntimeStructInit", original)
        local castPtr2 = ffi.new("RuntimeStructInit*", castFromValue)
        assertEqual(ffi.C.luneffi_test_struct_get_x(castPtr2), 21)
        assertEqual(ffi.C.luneffi_test_struct_get_y(castPtr2), 4.25)

        local pointerTarget = ffi.new("int", 255)
        local castUnion = ffi.cast("RuntimeTaggedUnion", { as_ptr = pointerTarget })
        local castUnionPtr = ffi.new("RuntimeTaggedUnion*", castUnion)
        assertEqual(ffi.C.luneffi_test_union_is_ptr(castUnionPtr, pointerTarget), 1)
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

    test("ffi.cast bridges Luau callbacks to C function pointers", function()
        ffi.cdef([[typedef int (*RuntimeUnary)(int);
int luneffi_test_call_callback(RuntimeUnary cb, int value);]])

        local cbType = ffi.typeof("RuntimeUnary")
        local total = 0

        local function handler(x)
            total += x
            return total
        end

        local cb = ffi.cast(cbType, handler)
        local first = ffi.C.luneffi_test_call_callback(cb, 3)
        assertEqual(first, 3)
        assertEqual(total, 3)

        local alias = ffi.cast("void*", cb)
        cb = nil
        local restored = ffi.cast(cbType, alias)
        local second = ffi.C.luneffi_test_call_callback(restored, 4)
        assertEqual(second, 7)
        assertEqual(total, 7)
    end)

    test("ffi variadic calls honour cdata type information", function()
        ffi.cdef([[int luneffi_test_variadic_format(char* buffer, size_t size, const char* fmt, ...);]])

        local bufferSize = 128
        local buffer = debugTools.alloc(bufferSize)
        local fmt = "%lld %.2f"
        local bigValue = 1234567890123

        local written = ffi.C.luneffi_test_variadic_format(
            buffer,
            bufferSize,
            fmt,
            ffi.cast("long long", bigValue),
            ffi.cast("float", 3.25)
        )

        assert(written > 0, "expected luneffi_test_variadic_format to succeed")
        local output = ffi.string(buffer)
        assertEqual(output, string.format("%d %.2f", bigValue, 3.25))
        debugTools.free(buffer)
    end)

    test("ffi.errno exposes native errno and allows overriding", function()
        local original = ffi.errno()
        local marker = 1337
        ffi.errno(marker)
        assertEqual(ffi.errno(), marker)
        ffi.errno(original)
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
