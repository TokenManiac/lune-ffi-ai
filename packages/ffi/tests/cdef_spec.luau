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

    test("ffi.cdef surfaces TODO errors for unsupported struct typedefs", function()
        local ok, err = pcall(function()
            ffi.cdef([[typedef struct { int value; } Demo;]])
        end)
        assert(ok == false, "expected struct typedef parsing to fail")
        assert(type(err) == "string", "expected error message to be a string")
        assert(err:find("TODO"), "expected error to include TODO notice")
    end)
end
