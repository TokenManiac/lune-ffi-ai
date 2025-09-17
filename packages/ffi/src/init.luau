local native = select(1, ...)

export type NativeHandle = lightuserdata

type LibraryState = {
handle: NativeHandle?,
name: string,
autoClose: boolean,
symbols: { [string]: any },
}

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
error(string.format(
"TODO(@lune/ffi/callbridge): invoke symbol '%s'",
self.__name
), 2)
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

return ffi
