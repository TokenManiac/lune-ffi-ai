return function(ctx)
    local ffi = ctx.ffi
    local test = ctx.test
    local assertEqual = ctx.assertEqual
    local debugTools = ffi._debug

    local function assertSignature(name: string)
        local signature = debugTools.getFunctionSignature(name)
        if not signature then
            error(string.format("expected signature for '%s' to be registered", name), 2)
        end
        return signature
    end

    test("ffi.cdef registers primitive function signatures", function()
        ffi.cdef([[int luneffi_test_add_ints(int a, int b);]])

        local signature = assertSignature("luneffi_test_add_ints")
        assertEqual(signature.result.code, "int")
        assertEqual(#signature.args, 2)
        assertEqual(signature.args[1].code, "int")
        assertEqual(signature.args[2].code, "int")
        assertEqual(signature.variadic, false)
        assertEqual(signature.fixedCount, 2)
    end)

    test("ffi.cdef honors typedef aliases", function()
        ffi.cdef([[typedef unsigned int uint32_t;]])
        local ty = debugTools.resolveType("uint32_t")
        assertEqual(ty.code, "unsigned int")

        ffi.cdef([[uint32_t returns_uint32(void);]])
        local signature = assertSignature("returns_uint32")
        assertEqual(signature.result.code, "unsigned int")
        assertEqual(#signature.args, 0)
        assertEqual(signature.fixedCount, 0)
    end)

    test("ffi.cdef parses pointer arguments and variadic markers", function()
        ffi.cdef([[int printf(const char *fmt, ...);]])
        local signature = assertSignature("printf")
        assertEqual(signature.result.code, "int")
        assertEqual(#signature.args, 1)
        assertEqual(signature.args[1].code, "pointer")
        assert(signature.variadic == true, "expected printf to be marked variadic")
        assertEqual(signature.fixedCount, 1)
    end)

    test("ffi.cdef strips comments within declarations", function()
        ffi.cdef([[// leading comment
        int comment_demo(/* first */ int a, int b /* second */);
        ]])
        local signature = assertSignature("comment_demo")
        assertEqual(#signature.args, 2)
        assertEqual(signature.args[1].code, "int")
        assertEqual(signature.args[2].code, "int")
    end)

    test("ffi.cdef parses typedef struct definitions", function()
        ffi.cdef([[typedef struct { int a; double b; } Pair;]])
        local ty = debugTools.resolveType("Pair")
        assertEqual(ty.kind, "struct")
        local fields = (ty :: any).fields
        assertEqual(#fields, 2)
        assertEqual(fields[1].name, "a")
        assertEqual(fields[1].ctype.code, "int")
        assertEqual(fields[1].bitWidth, nil)
        assertEqual(fields[2].name, "b")
        assertEqual(fields[2].ctype.code, "double")
    end)

    test("ffi.cdef registers union definitions", function()
        ffi.cdef([[typedef union { int i; float f; } NumberUnion;]])
        local ty = debugTools.resolveType("NumberUnion")
        assertEqual(ty.kind, "union")
        local fields = (ty :: any).fields
        assertEqual(#fields, 2)
        assertEqual(fields[1].name, "i")
        assertEqual(fields[2].name, "f")
    end)

    test("ffi.cdef parses enum values with implicit increments", function()
        ffi.cdef([[typedef enum { RED = 1, GREEN, BLUE = 8 } ColorEnum;]])
        local ty = debugTools.resolveType("ColorEnum")
        assertEqual(ty.kind, "enum")
        local values = (ty :: any).values
        assertEqual(#values, 3)
        assertEqual(values[1].name, "RED")
        assertEqual(values[1].value, 1)
        assertEqual(values[2].name, "GREEN")
        assertEqual(values[2].value, 2)
        assertEqual(values[3].name, "BLUE")
        assertEqual(values[3].value, 8)
    end)

    test("ffi.cdef records basic bitfield widths", function()
        ffi.cdef([[typedef struct { unsigned a:3; unsigned b:5; } BitfieldStruct;]])
        local ty = debugTools.resolveType("BitfieldStruct")
        local fields = (ty :: any).fields
        assertEqual(#fields, 2)
        assertEqual(fields[1].bitWidth, 3)
        assertEqual(fields[2].bitWidth, 5)
    end)

    test("ffi.cdef surfaces TODO errors for unsupported record declarators", function()
        local ok, err = pcall(function()
            ffi.cdef([[typedef struct { int values[4]; } ArrayStruct;]])
        end)
        assert(ok == false, "expected parsing to fail for arrays inside records")
        assert(type(err) == "string", "expected error to be a string")
        assert(err:find("TODO(@lune/ffi/cdef)", 1, true) ~= nil, string.format("expected TODO marker in error message, got: %s", err))
    end)
end
