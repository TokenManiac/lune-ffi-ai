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

local function trim(value: string): string
    local stripped = value:gsub("^%s+", "")
    return stripped:gsub("%s+$", "")
end

type CType = {
    kind: string,
    name: string,
    code: string,
    size: number?,
    align: number?,
    base: CType?,
}

type TypeResolveResult = CType

local TypeRegistry = {}
TypeRegistry.__index = TypeRegistry

type TypeRegistryState = {
    builtins: { [string]: CType },
    named: { [string]: CType },
    pointerCache: { [CType]: CType },
}

local QUALIFIERS = {
    const = true,
    volatile = true,
    restrict = true,
    static = true,
    extern = true,
    register = true,
    auto = true,
}

local function createPrimitive(name: string, code: string, size: number?, align: number?): CType
    return {
        kind = "primitive",
        name = name,
        code = code,
        size = size,
        align = align,
    }
end

local POINTER_SIZE: number? = nil -- TODO(@lune/ffi/types): detect pointer size when implementing sizeof.
local POINTER_ALIGN: number? = nil -- TODO(@lune/ffi/types): detect pointer alignment when implementing sizeof.

function TypeRegistry.new(): TypeRegistryState
    local state: TypeRegistryState = {
        builtins = {},
        named = {},
        pointerCache = setmetatable({}, { __mode = "k" }) :: { [CType]: CType },
    }

    local function definePrimitive(names: { string }, code: string, size: number?, align: number?)
        local descriptor = createPrimitive(names[1], code, size, align)
        for _, entry in ipairs(names) do
            state.builtins[entry:lower()] = descriptor
        end
    end

    definePrimitive({ "void" }, "void", 0, 1)
    definePrimitive({ "bool", "_Bool" }, "uint8", 1, 1)
    definePrimitive({ "char", "signed char" }, "int8", 1, 1)
    definePrimitive({ "unsigned char" }, "uint8", 1, 1)
    definePrimitive({ "short", "short int", "signed short", "signed short int" }, "int16", 2, 2)
    definePrimitive({ "unsigned short", "unsigned short int" }, "uint16", 2, 2)
    definePrimitive({ "int", "signed", "signed int" }, "int", 4, 4)
    definePrimitive({ "unsigned", "unsigned int" }, "unsigned int", 4, 4)
    definePrimitive({ "long", "long int", "signed long", "signed long int" }, "long", nil, nil)
    definePrimitive({ "unsigned long", "unsigned long int" }, "unsigned long", nil, nil)
    definePrimitive({ "long long", "long long int", "signed long long", "signed long long int" }, "long long", 8, 8)
    definePrimitive({ "unsigned long long", "unsigned long long int" }, "unsigned long long", 8, 8)
    definePrimitive({ "size_t" }, "size_t", nil, nil)
    definePrimitive({ "ssize_t" }, "ssize_t", nil, nil)
    definePrimitive({ "intptr_t" }, "intptr_t", nil, nil)
    definePrimitive({ "uintptr_t" }, "uintptr_t", nil, nil)
    definePrimitive({ "ptrdiff_t" }, "ptrdiff_t", nil, nil)
    definePrimitive({ "float" }, "float", 4, 4)
    definePrimitive({ "double" }, "double", 8, 8)

    for key, descriptor in pairs(state.builtins) do
        state.named[key] = descriptor
    end

    return setmetatable(state, TypeRegistry) :: any
end

local function isIdentifier(token: string): boolean
    return token:match("^[%a_][%w_]*$") ~= nil
end

function TypeRegistry:defineAlias(name: string, descriptor: CType)
    local existing = self.named[name]
    if existing and existing ~= descriptor then
        error(string.format("ctype '%s' already defined with a different signature", name), 2)
    end
    self.named[name] = descriptor
end

function TypeRegistry:resolveBase(tokens: { string }): (TypeResolveResult?, string?)
    if #tokens == 1 then
        local alias = self.named[tokens[1]]
        if alias then
            return alias
        end
    end

    local lowered = table.create(#tokens)
    for index = 1, #tokens do
        lowered[index] = tokens[index]:lower()
    end

    local key = table.concat(lowered, " ")
    local primitive = self.builtins[key]
    if primitive then
        return primitive
    end

    if #tokens == 1 then
        local alias = self.named[tokens[1]]
        if alias then
            return alias
        end
    end

    return nil, string.format("unknown type '%s'", table.concat(tokens, " "))
end

function TypeRegistry:makePointer(base: CType): CType
    local cached = self.pointerCache[base]
    if cached then
        return cached
    end

    local pointer = {
        kind = "pointer",
        name = string.format("%s*", base.name),
        code = "pointer",
        size = POINTER_SIZE,
        align = POINTER_ALIGN,
        base = base,
    }
    self.pointerCache[base] = pointer
    return pointer
end

function TypeRegistry:resolveTypeTokens(tokens: { string }): (TypeResolveResult?, string?)
    local baseTokens = {}
    local pointerDepth = 0

    for index = 1, #tokens do
        local token = tokens[index]
        if token == "*" then
            pointerDepth += 1
        elseif isIdentifier(token) then
            local lowered = token:lower()
            if QUALIFIERS[lowered] then
                continue
            end
            table.insert(baseTokens, token)
        else
            return nil, string.format("unsupported token '%s' in type", token)
        end
    end

    if #baseTokens == 0 then
        return nil, "missing base type"
    end

    local base, err = self:resolveBase(baseTokens)
    if not base then
        return nil, err
    end

    local descriptor = base
    for _ = 1, pointerDepth do
        descriptor = self:makePointer(descriptor)
    end

    return descriptor
end

local typeRegistry = TypeRegistry.new()

type Token = {
    kind: string,
    value: string,
}

local function tokenize(statement: string): { Token }
    local tokens = {}
    local index = 1
    local length = #statement

    while index <= length do
        local char = statement:sub(index, index)
        if char:match("%s") then
            index += 1
        elseif char == '.' and statement:sub(index, index + 2) == "..." then
            table.insert(tokens, { kind = "ellipsis", value = "..." })
            index += 3
        elseif char:match("[%a_]") then
            local start = index
            index += 1
            while index <= length and statement:sub(index, index):match("[%w_]") do
                index += 1
            end
            local word = statement:sub(start, index - 1)
            table.insert(tokens, { kind = "identifier", value = word })
        elseif char:match("[%d]") then
            local start = index
            index += 1
            while index <= length and statement:sub(index, index):match("[%d]") do
                index += 1
            end
            local number = statement:sub(start, index - 1)
            table.insert(tokens, { kind = "number", value = number })
        elseif char == '(' or char == ')' or char == ',' or char == '*' or char == '{' or char == '}' or char == '[' or char == ']' or char == ';' then
            table.insert(tokens, { kind = "symbol", value = char })
            index += 1
        else
            error(string.format("unexpected character '%s' in declaration", char), 2)
        end
    end

    return tokens
end

local function strip_comments(input: string): string
    local result = table.create(#input)
    local index = 1
    local length = #input

    while index <= length do
        local char = input:sub(index, index)
        local nextTwo = input:sub(index, index + 1)

        if nextTwo == "//" then
            index += 2
            while index <= length do
                local c = input:sub(index, index)
                index += 1
                if c == "\n" then
                    table.insert(result, "\n")
                    break
                end
            end
        elseif nextTwo == "/*" then
            index += 2
            while index <= length do
                local c = input:sub(index, index + 1)
                if c == "*/" then
                    index += 2
                    break
                end
                index += 1
            end
        else
            table.insert(result, char)
            index += 1
        end
    end

    return table.concat(result)
end

local function split_statements(input: string): { string }
    local list = {}
    local buffer = {}
    local parenDepth = 0
    local braceDepth = 0
    local bracketDepth = 0

    local function flush()
        if #buffer == 0 then
            return
        end
        local statement = trim(table.concat(buffer))
        table.clear(buffer)
        if #statement > 0 then
            table.insert(list, statement)
        end
    end

    for index = 1, #input do
        local char = input:sub(index, index)
        if char == '(' then
            parenDepth += 1
            table.insert(buffer, char)
        elseif char == ')' then
            parenDepth -= 1
            if parenDepth < 0 then
                error("unbalanced parentheses in cdef", 3)
            end
            table.insert(buffer, char)
        elseif char == '{' then
            braceDepth += 1
            table.insert(buffer, char)
        elseif char == '}' then
            braceDepth -= 1
            if braceDepth < 0 then
                error("unbalanced braces in cdef", 3)
            end
            table.insert(buffer, char)
        elseif char == '[' then
            bracketDepth += 1
            table.insert(buffer, char)
        elseif char == ']' then
            bracketDepth -= 1
            if bracketDepth < 0 then
                error("unbalanced brackets in cdef", 3)
            end
            table.insert(buffer, char)
        elseif char == ';' then
            if parenDepth == 0 and braceDepth == 0 and bracketDepth == 0 then
                flush()
            else
                table.insert(buffer, char)
            end
        else
            table.insert(buffer, char)
        end
    end

    if parenDepth ~= 0 or braceDepth ~= 0 or bracketDepth ~= 0 then
        error("unterminated declaration in cdef", 3)
    end

    flush()

    return list
end

local function tokens_to_strings(tokens: { Token }): { string }
    local values = table.create(#tokens)
    for index = 1, #tokens do
        values[index] = tokens[index].value
    end
    return values
end

local function split_tokens(tokens: { Token }, separator: string): { { Token } }
    local parts = {}
    local buffer = {}
    local depth = 0

    local function commit()
        local copy = table.create(#buffer)
        for index = 1, #buffer do
            copy[index] = buffer[index]
        end
        table.insert(parts, copy)
        table.clear(buffer)
    end

    for index = 1, #tokens do
        local token = tokens[index]
        if token.value == '(' then
            depth += 1
            table.insert(buffer, token)
        elseif token.value == ')' then
            depth -= 1
            table.insert(buffer, token)
        elseif depth == 0 and token.value == separator then
            commit()
        else
            table.insert(buffer, token)
        end
    end

    if #buffer > 0 then
        commit()
    end

    return parts
end

local function resolve_type_from_tokens(rawTokens: { Token }): CType
    local values = {}
    for index = 1, #rawTokens do
        values[index] = rawTokens[index].value
    end

    local descriptor, err = typeRegistry:resolveTypeTokens(values)
    if not descriptor then
        error(err, 3)
    end
    return descriptor
end

local function parse_function(statement: string)
    local tokens = tokenize(statement)
    local openIndex = nil
    for index = 1, #tokens do
        if tokens[index].value == '(' then
            openIndex = index
            break
        end
    end

    if not openIndex then
        error(string.format("invalid function declaration '%s'", statement), 3)
    end

    if openIndex <= 1 then
        error("function declaration missing return type", 3)
    end

    local nameToken = tokens[openIndex - 1]
    if nameToken.kind ~= "identifier" then
        error(string.format("unsupported function declarator near '%s'", nameToken.value), 3)
    end

    local closeIndex = nil
    local depth = 0
    for index = openIndex, #tokens do
        local token = tokens[index]
        if token.value == '(' then
            depth += 1
        elseif token.value == ')' then
            depth -= 1
            if depth == 0 then
                closeIndex = index
                break
            end
        end
    end

    if not closeIndex then
        error("unterminated parameter list in function declaration", 3)
    end

    local returnTokens = table.create(openIndex - 2)
    for index = 1, openIndex - 2 do
        returnTokens[index] = tokens[index]
    end

    if #returnTokens == 0 then
        error("function declaration missing return type", 3)
    end

    local returnType = resolve_type_from_tokens(returnTokens)

    local argsTokens = {}
    for index = openIndex + 1, closeIndex - 1 do
        table.insert(argsTokens, tokens[index])
    end

    local args = {}
    local variadic = false

    if #argsTokens > 0 then
        local sequences = split_tokens(argsTokens, ',')
        for _, sequence in ipairs(sequences) do
            if #sequence == 0 then
                continue
            end

            if #sequence == 1 and sequence[1].value == 'void' and not variadic and #sequences == 1 then
                continue
            end

            if #sequence == 1 and sequence[1].value == '...' then
                variadic = true
                continue
            end

            local descriptor: CType?
            local ok = true
            local message = nil

            local function attempt(tokensToParse)
                local okParse, result = pcall(resolve_type_from_tokens, tokensToParse)
                if okParse then
                    descriptor = result
                    return true
                end
                message = result
                return false
            end

            if not attempt(sequence) then
                local last = sequence[#sequence]
                if last.kind == "identifier" and not QUALIFIERS[last.value:lower()] then
                    local trimmed = table.create(#sequence - 1)
                    for index = 1, #sequence - 1 do
                        trimmed[index] = sequence[index]
                    end
                    ok = attempt(trimmed)
                else
                    ok = false
                end
            end

            if not ok or not descriptor then
                error(message or "failed to parse function argument type", 3)
            end

            table.insert(args, descriptor)
        end
    end

    return {
        kind = "function",
        name = nameToken.value,
        result = returnType,
        args = args,
        variadic = variadic,
        fixedCount = #args,
    }
end

local function parse_typedef(statement: string)
    local tokens = tokenize(statement)
    if #tokens == 0 or tokens[1].value ~= 'typedef' then
        error("typedef statement must begin with 'typedef'", 3)
    end

    local body = {}
    for index = 2, #tokens do
        table.insert(body, tokens[index])
    end

    if #body == 0 then
        error("typedef missing target type", 3)
    end

    for index = 1, #body do
        local value = body[index].value
        if value == '{' or value == '}' then
            error("TODO(@lune/ffi/cdef): struct/union typedef parsing not implemented", 3)
        end
    end

    local aliasToken = body[#body]
    if aliasToken.kind ~= "identifier" then
        error("typedef target name must be an identifier", 3)
    end

    local alias = aliasToken.value
    local typeTokens = table.create(#body - 1)
    for index = 1, #body - 1 do
        typeTokens[index] = body[index]
    end

    if #typeTokens == 0 then
        error(string.format("typedef '%s' missing source type", alias), 3)
    end

    local descriptor
    local ok, message = pcall(function()
        descriptor = resolve_type_from_tokens(typeTokens)
    end)

    if not ok then
        error(message, 3)
    end

    typeRegistry:defineAlias(alias, descriptor :: CType)

    return {
        kind = "typedef",
        name = alias,
        type = descriptor :: CType,
    }
end

local function parse_declaration(statement: string)
    if statement:match("^typedef") then
        return parse_typedef(statement)
    end

    if statement:find('(', 1, true) then
        return parse_function(statement)
    end

    error(string.format("TODO(@lune/ffi/cdef): unsupported declaration '%s'", statement), 3)
end

local function parse_cdef(source: string)
    local cleaned = strip_comments(source)
    local statements = split_statements(cleaned)
    local declarations = {}

    for _, statement in ipairs(statements) do
        local ok, result = pcall(parse_declaration, statement)
        if not ok then
            error(result, 3)
        end
        table.insert(declarations, result)
    end

    return declarations
end

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

function ffi.cdef(header: string)
    if type(header) ~= "string" then
        error("ffi.cdef expects a string", 2)
    end

    local ok, declarationsOrErr = pcall(parse_cdef, header)
    if not ok then
        error(declarationsOrErr, 2)
    end

    local declarations = declarationsOrErr :: { [number]: any }

    for _, declaration in ipairs(declarations) do
        if declaration.kind == "function" then
            register_function(declaration.name, {
                kind = "function",
                result = declaration.result,
                args = declaration.args,
                abi = declaration.abi,
                variadic = declaration.variadic,
                fixedCount = declaration.fixedCount,
            })
        elseif declaration.kind == "typedef" then
            -- nothing further: typedefs already registered inside parser
        else
            error(string.format("TODO(@lune/ffi/cdef): declaration kind '%s' not supported", tostring(declaration.kind)), 2)
        end
    end
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

function debug.parse(header: string)
    return parse_cdef(header)
end

function debug.resolveType(spec: string)
    local tokens = tokenize(spec)
    return resolve_type_from_tokens(tokens)
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

function debug.getFunctionSignature(name: string): FunctionSignature?
    return get_function_signature(name)
end

ffi._debug = debug -- TODO(@lune/ffi): remove debug helpers once parser populates signatures.

return ffi
