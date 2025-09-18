local native = select(1, ...)

export type NativeHandle = lightuserdata

type LibraryState = {
    handle: NativeHandle?,
    name: string,
    autoClose: boolean,
    symbols: { [string]: any },
}

type CTypeDescriptor = {
    kind: string,
    code: string,
    [string]: any,
}

type FunctionSignature = {
    kind: string,
    result: CTypeDescriptor,
    args: { CTypeDescriptor },
    abi: string?,
    variadic: boolean?,
    fixedCount: number?,
}

local registry = {
    functions = {} :: { [string]: FunctionSignature },
}

local function register_function(name: string, signature: FunctionSignature)
    if type(name) ~= "string" then
        error("symbol name must be a string", 2)
    end
    if type(signature) ~= "table" then
        error("function signature must be a table", 2)
    end
    if signature.kind ~= "function" then
        error("expected function signature with kind = 'function'", 2)
    end
    if type(signature.result) ~= "table" then
        error("function signature requires a result type", 2)
    end

    local args = signature.args or {}
    if type(args) ~= "table" then
        error("function signature args must be an array", 2)
    end

    local normalizedArgs = table.create(#args)
    for index = 1, #args do
        normalizedArgs[index] = args[index]
    end

    local fixedCount = signature.fixedCount
    if fixedCount == nil then
        fixedCount = #normalizedArgs
    elseif type(fixedCount) ~= "number" then
        error("function signature fixedCount must be a number", 2)
    elseif fixedCount > #normalizedArgs then
        error("function signature fixedCount exceeds number of arguments", 2)
    end

    registry.functions[name] = {
        kind = "function",
        result = signature.result,
        args = normalizedArgs,
        abi = signature.abi,
        variadic = signature.variadic,
        fixedCount = fixedCount,
    }
end

local function get_function_signature(name: string): FunctionSignature?
    return registry.functions[name]
end

local function todo(name: string): ()
error(string.format("TODO(@lune/ffi): %s not implemented yet", name), 2)
end

local function ensure_handle(state: LibraryState)
if not state.handle then
error(string.format("Library '%s' has been closed", state.name), 3)
end
return state.handle
end

local symbol_mt = {}
symbol_mt.__index = symbol_mt

function symbol_mt:__call(...)
    local signature = get_function_signature(self.__name)
    if not signature then
        error(string.format("No ctype registered for symbol '%s'", self.__name), 2)
    end

    local packed = table.pack(...)
    local args = table.create(packed.n)
    for index = 1, packed.n do
        args[index] = packed[index]
    end
    args.n = packed.n

    local ok, result = pcall(native.call, self.__ptr, signature, args)
    if not ok then
        error(result, 2)
    end
    return result
end

function symbol_mt:__tostring()
return string.format("cfunction: %s", self.__name)
end

local function create_symbol_proxy(name: string, ptr: NativeHandle)
return setmetatable({
__name = name,
__ptr = ptr,
}, symbol_mt)
end

local library_mt = {}
library_mt.__index = function(self, key)
local state: LibraryState = rawget(self, "__state")
local method = library_mt[key]
if method then
return method
end
local cached = state.symbols[key]
if cached then
return cached
end
local handle = ensure_handle(state)
local sym, err = native.dlsym(handle, key)
if not sym then
error(err or string.format("Symbol '%s' not found", key), 2)
end
local proxy = create_symbol_proxy(key, sym)
state.symbols[key] = proxy
return proxy
end

function library_mt:close(): boolean
local state: LibraryState = rawget(self, "__state")
if not state.handle then
return false
end
local handle = state.handle
state.handle = nil
state.symbols = {}
if state.autoClose then
native.dlclose(handle)
return true
end
return false
end

function library_mt:__tostring()
local state: LibraryState = rawget(self, "__state")
if state.handle then
return string.format("clibrary: %s", state.name)
else
return string.format("clibrary: %s (closed)", state.name)
end
end

local function wrap_library(handle: NativeHandle, name: string, autoClose: boolean)
local state: LibraryState = {
handle = handle,
name = name,
autoClose = autoClose,
symbols = {},
}
return setmetatable({ __state = state }, library_mt)
end

local ffi = {}

function ffi.cdef(_: string)
    todo("ffi.cdef")
end

function ffi.load(libnameOrPath: string?): any
if libnameOrPath ~= nil and type(libnameOrPath) ~= "string" then
error("ffi.load expects a string or nil", 2)
end
local ok, handleOrErr = pcall(native.dlopen, libnameOrPath)
if not ok then
error(handleOrErr, 2)
end
local handle = handleOrErr :: NativeHandle
local name = libnameOrPath or "<process>"
return wrap_library(handle, name, libnameOrPath ~= nil)
end

ffi.C = wrap_library(native.dlopen(nil), "<process>", false)

function ffi.new(_: any, ...): any
todo("ffi.new")
end

function ffi.typeof(_: any): any
todo("ffi.typeof")
end

function ffi.cast(_: any, _value: any): any
todo("ffi.cast")
end

function ffi.string(_: any, _len: number?): string
todo("ffi.string")
end

function ffi.gc(_: any, _fn: ((any) -> ())?)
todo("ffi.gc")
end

function ffi.metatype(_: any, _methods: { [string]: any })
todo("ffi.metatype")
end

function ffi.sizeof(_: any): number
todo("ffi.sizeof")
end

function ffi.alignof(_: any): number
todo("ffi.alignof")
end

function ffi.offsetof(_: any, _field: string): number
todo("ffi.offsetof")
end

function ffi.abi(...: string): boolean
todo("ffi.abi")
end

ffi.os = "unknown"
ffi.arch = "unknown"

local debug = {}

function debug.primitive(code: string): CTypeDescriptor
    if type(code) ~= "string" then
        error("primitive code must be a string", 2)
    end
    return { kind = "primitive", code = code }
end

function debug.pointer(base: CTypeDescriptor?): CTypeDescriptor
    return { kind = "pointer", code = "pointer", base = base }
end

function debug.functionSignature(
    result: CTypeDescriptor,
    args: { CTypeDescriptor }?,
    opts: { abi: string?, variadic: boolean?, fixedCount: number? }?
): FunctionSignature
    local list = {}
    if args then
        for index = 1, #args do
            list[index] = args[index]
        end
    end
    local fixedCount = if opts and opts.fixedCount then opts.fixedCount else #list
    return {
        kind = "function",
        result = result,
        args = list,
        abi = if opts then opts.abi else nil,
        variadic = if opts then opts.variadic else nil,
        fixedCount = fixedCount,
    }
end

function debug.register(name: string, signature: FunctionSignature)
    register_function(name, signature)
end

ffi._debug = debug -- TODO(@lune/ffi): remove debug helpers once parser populates signatures.

return ffi
