local native = select(1, ...)

local taskLibrary: any

local function ensure_task_library()
    local existing = taskLibrary
    if existing then
        return existing
    end

    local globalTask = rawget(_G, "task")
    if type(globalTask) ~= "table" then
        error("task library is required to manage ffi finalizers", 2)
    end

    taskLibrary = globalTask
    return globalTask
end

local function warn_if_available(message: string)
    local maybeWarn = rawget(_G, "warn")
    if type(maybeWarn) == "function" then
        maybeWarn(message)
    else
        print(message)
    end
end

if type(native) ~= "table" then
    error("native bindings table is required", 2)
end

export type NativeHandle = lightuserdata

local POINTER_SIZE = native.pointerSize
if type(POINTER_SIZE) ~= "number" then
    error("native.pointerSize must be a number", 2)
end

local POINTER_ALIGN = native.pointerAlign
if type(POINTER_ALIGN) ~= "number" then
    error("native.pointerAlign must be a number", 2)
end

local PRIMITIVE_LAYOUTS = native.primitiveLayout
if type(PRIMITIVE_LAYOUTS) ~= "table" then
    error("native.primitiveLayout must be a table", 2)
end

local PLATFORM_OS = native.platformOS
if type(PLATFORM_OS) ~= "string" then
    error("native.platformOS must be a string", 2)
end

local PLATFORM_ARCH = native.platformArch
if type(PLATFORM_ARCH) ~= "string" then
    error("native.platformArch must be a string", 2)
end

local ABI_FLAGS = native.abiInfo
if type(ABI_FLAGS) ~= "table" then
    error("native.abiInfo must be a table", 2)
end

type LibraryState = {
    handle: NativeHandle?,
    name: string,
    autoClose: boolean,
    symbols: { [string]: any },
    cacheKey: string?,
    finalizerIndex: number?,
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

local libraryCache = setmetatable({}, { __mode = "v" }) :: { [string]: any }

local FINALIZER_POLL_INTERVAL = 3

local finalizerRefs = setmetatable({}, { __mode = "v" }) :: { [number]: any }
local finalizerStates = {} :: { [number]: LibraryState }
local finalizerFreeSlots = {} :: { [number]: number }
local finalizerMaxIndex = 0
local finalizerLoopActive = false
local finalizerLoopSupported = true

local function clear_library_state(state: LibraryState)
    state.handle = nil
    state.symbols = {}
    if state.cacheKey then
        libraryCache[state.cacheKey] = nil
    end
end

local function release_finalizer_slot(index: number)
    finalizerRefs[index] = nil
    finalizerStates[index] = nil
    table.insert(finalizerFreeSlots, index)
end

local function ensure_finalizer_loop()
    if finalizerLoopActive then
        return true
    end
    if not finalizerLoopSupported then
        return false
    end

    local ok, schedulerOrErr = pcall(ensure_task_library)
    if not ok then
        finalizerLoopSupported = false
        warn_if_available("ffi: task library unavailable; library finalizers disabled")
        return false
    end

    finalizerLoopActive = true

    local scheduler = schedulerOrErr
    local defer = scheduler.defer
    local wait = scheduler.wait
    if type(defer) ~= "function" or type(wait) ~= "function" then
        error("task library missing defer/wait implementations", 2)
    end

    defer(function()
        while true do
            wait(FINALIZER_POLL_INTERVAL)

            for index = 1, finalizerMaxIndex do
                local state = finalizerStates[index]
                if state then
                    local wrapper = finalizerRefs[index]
                    if wrapper == nil then
                        release_finalizer_slot(index)
                        state.finalizerIndex = nil

                        if state.autoClose then
                            local handle = state.handle
                            clear_library_state(state)

                            if handle then
                                local ok, err = pcall(native.dlclose, handle)
                                if not ok then
                                    warn_if_available(string.format(
                                        "ffi: failed to close library '%s': %s",
                                        state.name,
                                        tostring(err)
                                    ))
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
end

local function register_library_finalizer(wrapper: any, state: LibraryState)
    if not ensure_finalizer_loop() then
        return
    end

    local slot = table.remove(finalizerFreeSlots)
    if slot == nil then
        finalizerMaxIndex += 1
        slot = finalizerMaxIndex
    end

    finalizerRefs[slot] = wrapper
    finalizerStates[slot] = state
    state.finalizerIndex = slot
end

local function unregister_library_finalizer(state: LibraryState)
    local slot = state.finalizerIndex
    if not slot then
        return
    end

    state.finalizerIndex = nil
    release_finalizer_slot(slot)
end

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
    fields: { RecordField }?,
    fieldMap: { [string]: RecordField }?,
    values: { EnumEntry }?,
    metatype: { [string]: any }?,
}

type TypeResolveResult = CType

local TypeRegistry = {}
TypeRegistry.__index = TypeRegistry

type RecordField = {
    name: string,
    ctype: CType,
    bitWidth: number?,
    offset: number?,
    bitOffset: number?,
}

type EnumEntry = {
    name: string,
    value: number?,
}

type TypeRegistryState = {
    builtins: { [string]: CType },
    named: { [string]: CType },
    pointerCache: { [CType]: CType },
    tags: {
        struct: { [string]: CType },
        union: { [string]: CType },
        enum: { [string]: CType },
    },
    anonymousCounter: number,
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

function TypeRegistry.new(): TypeRegistryState
    local state: TypeRegistryState = {
        builtins = {},
        named = {},
        pointerCache = setmetatable({}, { __mode = "k" }) :: { [CType]: CType },
        tags = {
            struct = {},
            union = {},
            enum = {},
        },
        anonymousCounter = 0,
    }

    local function definePrimitive(names: { string }, code: string, size: number?, align: number?)
        local layout = PRIMITIVE_LAYOUTS[code]
        if size == nil then
            if layout and type(layout.size) == "number" then
                size = layout.size
            else
                error(string.format("missing size information for primitive '%s'", code), 2)
            end
        end

        if align == nil then
            if layout and type(layout.align) == "number" then
                align = layout.align
            else
                error(string.format("missing alignment information for primitive '%s'", code), 2)
            end
        end

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

local function make_record_name(recordKind: string, tag: string?, anonymousId: number): string
    if tag then
        return string.format("%s %s", recordKind, tag)
    end
    return string.format("%s<anonymous:%d>", recordKind, anonymousId)
end

function TypeRegistry:defineRecord(recordKind: string, tag: string?, fields: { RecordField }): CType
    local tags = if recordKind == "union" then self.tags.union else self.tags.struct
    local anonymousId = if not tag then self.anonymousCounter + 1 else self.anonymousCounter
    if not tag then
        self.anonymousCounter = anonymousId
    end

    if tag then
        local existing = tags[tag]
        if existing then
            local existingFields = (existing :: any).fields :: { RecordField }
            local matches = #existingFields == #fields
            if matches then
                for index = 1, #fields do
                    local a = existingFields[index]
                    local b = fields[index]
                    if a.name ~= b.name or a.bitWidth ~= b.bitWidth or a.ctype ~= b.ctype then
                        matches = false
                        break
                    end
                end
            end

            if not matches then
                error(string.format("redefinition of %s '%s' conflicts with previous declaration", recordKind, tag), 3)
            end

            return existing
        end
    end

    local descriptor: CType & { fields: { RecordField } } = {
        kind = recordKind,
        name = make_record_name(recordKind, tag, anonymousId),
        code = recordKind,
        fields = fields,
        fieldMap = {},
    }

    if tag then
        tags[tag] = descriptor
    end

    return descriptor
end

function TypeRegistry:defineEnum(tag: string?, entries: { EnumEntry }): CType
    local anonymousId = if not tag then self.anonymousCounter + 1 else self.anonymousCounter
    if not tag then
        self.anonymousCounter = anonymousId
    end

    if tag then
        local existing = self.tags.enum[tag]
        if existing then
            local existingEntries = (existing :: any).values :: { EnumEntry }
            local matches = #existingEntries == #entries
            if matches then
                for index = 1, #entries do
                    local a = existingEntries[index]
                    local b = entries[index]
                    if a.name ~= b.name or a.value ~= b.value then
                        matches = false
                        break
                    end
                end
            end

            if not matches then
                error(string.format("redefinition of enum '%s' conflicts with previous declaration", tag), 3)
            end

            return existing
        end
    end

    local descriptor: CType & { values: { EnumEntry } } = {
        kind = "enum",
        name = if tag then string.format("enum %s", tag) else string.format("enum<anonymous:%d>", anonymousId),
        code = "enum",
        values = entries,
        size = PRIMITIVE_LAYOUTS.int.size,
        align = PRIMITIVE_LAYOUTS.int.align,
    }

    if tag then
        self.tags.enum[tag] = descriptor
    end

    return descriptor
end

function TypeRegistry:resolveBase(tokens: { string }): (TypeResolveResult?, string?)
    if #tokens >= 2 then
        local first = tokens[1]
        if first == "struct" then
            local tag = tokens[2]
            local descriptor = self.tags.struct[tag]
            if descriptor then
                return descriptor
            end
            return nil, string.format("unknown struct '%s'", tag)
        elseif first == "union" then
            local tag = tokens[2]
            local descriptor = self.tags.union[tag]
            if descriptor then
                return descriptor
            end
            return nil, string.format("unknown union '%s'", tag)
        elseif first == "enum" then
            local tag = tokens[2]
            local descriptor = self.tags.enum[tag]
            if descriptor then
                return descriptor
            end
            return nil, string.format("unknown enum '%s'", tag)
        end
    end

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
        elseif char == '(' or char == ')' or char == ',' or char == '*' or char == '{' or char == '}' or char == '[' or char == ']' or char == ';' or char == ':' or char == '=' then
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

local resolve_type_from_tokens: (rawTokens: { Token }) -> CType

local function parse_parameter_descriptor(sequence: { Token }): CType
    local descriptor: CType?
    local message: string?

    local function attempt(tokensToParse: { Token }): boolean
        local ok, result = pcall(resolve_type_from_tokens, tokensToParse)
        if ok then
            descriptor = result
            return true
        end
        message = result
        return false
    end

    if not attempt(sequence) then
        local last = sequence[#sequence]
        if last and last.kind == "identifier" and not QUALIFIERS[last.value:lower()] then
            if #sequence == 1 then
                error(message or "failed to parse parameter type", 3)
            end

            local trimmed = table.create(#sequence - 1)
            for index = 1, #sequence - 1 do
                trimmed[index] = sequence[index]
            end

            if not attempt(trimmed) then
                error(message or "failed to parse parameter type", 3)
            end
        else
            error(message or "failed to parse parameter type", 3)
        end
    end

    return descriptor :: CType
end

local function try_parse_function_pointer(tokens: { Token }): CType?
    local firstParen: number? = nil
    for index = 1, #tokens do
        if tokens[index].value == '(' then
            firstParen = index
            break
        end
    end

    if not firstParen then
        return nil
    end

    local afterOpen = firstParen + 1
    if afterOpen > #tokens or tokens[afterOpen].value ~= '*' then
        return nil
    end

    local depth = 0
    local closeIndex: number? = nil
    for index = firstParen, #tokens do
        local token = tokens[index].value
        if token == '(' then
            depth += 1
        elseif token == ')' then
            depth -= 1
            if depth == 0 then
                closeIndex = index
                break
            end
        end
    end

    if not closeIndex then
        error("unterminated function pointer declarator", 3)
    end

    local starCount = 0
    for index = firstParen + 1, closeIndex - 1 do
        local token = tokens[index]
        if token.value == '*' then
            starCount += 1
        elseif token.kind == "identifier" then
            continue
        else
            error("TODO(@lune/ffi/cdef): complex function pointer declarators not supported", 3)
        end
    end

    if starCount ~= 1 then
        error("TODO(@lune/ffi/cdef): function pointer declarators with multiple indirections not supported", 3)
    end

    local paramStart = closeIndex + 1
    if paramStart > #tokens or tokens[paramStart].value ~= '(' then
        return nil
    end

    local depthParams = 1
    local paramEnd: number? = nil
    for index = paramStart + 1, #tokens do
        local token = tokens[index].value
        if token == '(' then
            depthParams += 1
        elseif token == ')' then
            depthParams -= 1
            if depthParams == 0 then
                paramEnd = index
                break
            end
        end
    end

    if not paramEnd then
        error("unterminated parameter list in function pointer", 3)
    end

    if paramEnd ~= #tokens then
        error("TODO(@lune/ffi/cdef): trailing tokens after function pointer declarator", 3)
    end

    local returnTokens = {}
    for index = 1, firstParen - 1 do
        returnTokens[index] = tokens[index]
    end

    if #returnTokens == 0 then
        error("function pointer missing return type", 3)
    end

    local returnType = resolve_type_from_tokens(returnTokens)

    local paramTokens = {}
    for index = paramStart + 1, paramEnd - 1 do
        paramTokens[#paramTokens + 1] = tokens[index]
    end

    local args = {}
    local variadic = false
    if #paramTokens > 0 then
        local sequences = split_tokens(paramTokens, ',')
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

            local descriptor = parse_parameter_descriptor(sequence)
            table.insert(args, descriptor)
        end
    end

    local displayParts = table.create(#args)
    for index = 1, #args do
        local ty = args[index]
        displayParts[index] = ty.name or ty.code or string.format("arg%d", index)
    end
    if variadic then
        table.insert(displayParts, "...")
    end

    local signatureText = table.concat(displayParts, ", ")
    local functionName = if signatureText == "" then string.format("%s()", returnType.name) else string.format("%s(%s)", returnType.name, signatureText)

    local descriptor: CType & { result: CType, args: { CType }, variadic: boolean?, fixedCount: number?, abi: string? } = {
        kind = "function",
        name = string.format("function<%s>", functionName),
        code = "function",
        result = returnType,
        args = args,
        variadic = variadic,
        fixedCount = #args,
    }

    return typeRegistry:makePointer(descriptor)
end

resolve_type_from_tokens = function(rawTokens: { Token }): CType
    local maybeFunctionPointer = try_parse_function_pointer(rawTokens)
    if maybeFunctionPointer then
        return maybeFunctionPointer
    end

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

local function parse_record_fields(recordKind: string, fieldTokens: { { Token } }): { RecordField }
    local fields = table.create(#fieldTokens)

    local function ensure(condition: boolean, message: string)
        if not condition then
            error(message, 3)
        end
    end

    for index = 1, #fieldTokens do
        local tokens = fieldTokens[index]
        if #tokens == 0 then
            continue
        end

        local colonIndex: number? = nil
        for tokenIndex = 1, #tokens do
            if tokens[tokenIndex].value == ':' then
                colonIndex = tokenIndex
                break
            end
        end

        local nameIndex: number? = nil
        for tokenIndex = #tokens, 1, -1 do
            local token = tokens[tokenIndex]
            if token.kind == "identifier" then
                nameIndex = tokenIndex
                break
            end
        end

        ensure(nameIndex ~= nil, string.format("TODO(@lune/ffi/cdef): anonymous fields in %s not supported", recordKind))

        local resolvedNameIndex = nameIndex :: number
        local resolvedColonIndex = colonIndex

        if resolvedColonIndex then
            ensure(resolvedColonIndex == resolvedNameIndex + 1, "bitfield width must follow the field name")
        end

        ensure(resolvedNameIndex >= 2, "record fields must specify a type")

        if resolvedColonIndex then
            ensure(resolvedColonIndex + 1 <= #tokens, "bitfield width missing value")
            local widthToken = tokens[resolvedColonIndex + 1]
            ensure(widthToken.kind == "number", "bitfield width must be a numeric literal")
        end

        if resolvedNameIndex < #tokens then
            local trailing = tokens[resolvedNameIndex + 1]
            if not resolvedColonIndex or trailing.value ~= ':' then
                error("TODO(@lune/ffi/cdef): array and declarator modifiers in records not yet supported", 3)
            end
        end

        local typeSlice = table.create(resolvedNameIndex - 1)
        for tokenIndex = 1, resolvedNameIndex - 1 do
            typeSlice[tokenIndex] = tokens[tokenIndex]
        end

        local descriptor = resolve_type_from_tokens(typeSlice)

        local bitWidth: number? = nil
        if resolvedColonIndex then
            bitWidth = tonumber(tokens[resolvedColonIndex + 1].value)
        end

        table.insert(fields, {
            name = tokens[resolvedNameIndex].value,
            ctype = descriptor,
            bitWidth = bitWidth,
        })
    end

    return fields
end

local function partition_record_tokens(tokens: { Token }): { { Token } }
    local segments = {}
    local buffer = {}

    for index = 1, #tokens do
        local token = tokens[index]
        if token.value == ';' then
            local entry = table.create(#buffer)
            for n = 1, #buffer do
                entry[n] = buffer[n]
            end
            table.insert(segments, entry)
            table.clear(buffer)
        else
            if token.value == '{' or token.value == '}' then
                error("TODO(@lune/ffi/cdef): nested records within structs/unions not supported yet", 3)
            end
            table.insert(buffer, token)
        end
    end

    if #buffer > 0 then
        table.insert(segments, buffer)
    end

    return segments
end

local function parse_record_definition(recordKind: string, tokens: { Token }): CType
    local index = 2
    local tag: string? = nil

    if tokens[index] and tokens[index].kind == "identifier" then
        tag = tokens[index].value
        index += 1
    end

    if not tokens[index] or tokens[index].value ~= '{' then
        error(string.format("TODO(@lune/ffi/cdef): forward declarations of %s not supported", recordKind), 3)
    end

    index += 1

    local body = {}
    while index <= #tokens and tokens[index].value ~= '}' do
        table.insert(body, tokens[index])
        index += 1
    end

    if index > #tokens or tokens[index].value ~= '}' then
        error(string.format("unterminated %s definition", recordKind), 3)
    end

    if index ~= #tokens then
        error(string.format("unexpected tokens after %s definition", recordKind), 3)
    end

    local fieldGroups = partition_record_tokens(body)
    local fields = parse_record_fields(recordKind, fieldGroups)

    return typeRegistry:defineRecord(recordKind, tag, fields)
end

local function parse_enum_definition(tokens: { Token }): CType
    local index = 2
    local tag: string? = nil

    if tokens[index] and tokens[index].kind == "identifier" then
        tag = tokens[index].value
        index += 1
    end

    if not tokens[index] or tokens[index].value ~= '{' then
        error("TODO(@lune/ffi/cdef): forward declarations of enums not supported", 3)
    end

    index += 1

    local entries: { EnumEntry } = {}
    local expectEntry = true
    local lastValue: number? = nil

    while index <= #tokens do
        local token = tokens[index]
        if token.value == '}' then
            break
        end

        if token.value == ',' then
            expectEntry = true
            index += 1
            continue
        end

        if not expectEntry then
            error("unexpected token in enum body", 3)
        end

        if token.kind ~= "identifier" then
            error("enum entry name must be an identifier", 3)
        end

        local name = token.value
        index += 1

        local value: number? = nil
        if index <= #tokens and tokens[index].value == '=' then
            index += 1
            local literal = tokens[index]
            if not literal or literal.kind ~= "number" then
                error("TODO(@lune/ffi/cdef): complex enum expressions not supported", 3)
            end
            value = tonumber(literal.value)
            index += 1
        elseif lastValue then
            value = lastValue + 1
        else
            value = 0
        end

        lastValue = value
        table.insert(entries, { name = name, value = value })
        expectEntry = false
    end

    if index > #tokens or tokens[index].value ~= '}' then
        error("unterminated enum definition", 3)
    end

    if index ~= #tokens then
        error("unexpected tokens after enum definition", 3)
    end

    return typeRegistry:defineEnum(tag, entries)
end

local function contains_symbol(tokens: { Token }, symbol: string): boolean
    for index = 1, #tokens do
        if tokens[index].value == symbol then
            return true
        end
    end
    return false
end

local function parse_type_specifier(tokens: { Token }): CType
    if #tokens == 0 then
        error("missing type specifier", 3)
    end

    local first = tokens[1].value
    if (first == "struct" or first == "union") and contains_symbol(tokens, '{') then
        return parse_record_definition(first, tokens)
    elseif first == "enum" and contains_symbol(tokens, '{') then
        return parse_enum_definition(tokens)
    end

    return resolve_type_from_tokens(tokens)
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

            local descriptor = parse_parameter_descriptor(sequence)
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

    while #body > 0 and body[#body].value == ';' do
        table.remove(body)
    end

    if #body == 0 then
        error("typedef missing target type", 3)
    end

    local aliasIndex: number? = nil
    local parenDepth = 0
    local bracketDepth = 0
    local braceDepth = 0
    for index = #body, 1, -1 do
        local token = body[index]
        local value = token.value
        if value == ')' then
            parenDepth += 1
        elseif value == '(' then
            parenDepth -= 1
        elseif value == ']' then
            bracketDepth += 1
        elseif value == '[' then
            bracketDepth -= 1
        elseif value == '}' then
            braceDepth += 1
        elseif value == '{' then
            braceDepth -= 1
        elseif token.kind == "identifier" then
            local outside = parenDepth == 0 and bracketDepth == 0 and braceDepth == 0
            local pointerName = parenDepth == 1
                and bracketDepth == 0
                and braceDepth == 0
                and index > 1
                and body[index - 1].value == '*'

            if outside or pointerName then
                aliasIndex = index
                break
            end
        end
    end

    if not aliasIndex then
        error("typedef target name must be an identifier", 3)
    end

    local aliasToken = body[aliasIndex]
    local alias = aliasToken.value

    local typeTokens = table.create(#body - 1)
    local offset = 1
    for index = 1, #body do
        if index ~= aliasIndex then
            typeTokens[offset] = body[index]
            offset += 1
        end
    end

    if #typeTokens == 0 then
        error(string.format("typedef '%s' missing source type", alias), 3)
    end

    local descriptor
    local ok, message = pcall(function()
        descriptor = parse_type_specifier(typeTokens)
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

    local tokens = tokenize(statement)
    if #tokens > 0 then
        local first = tokens[1].value
        if first == "struct" or first == "union" then
            local descriptor = parse_type_specifier(tokens)
            return { kind = first, type = descriptor }
        elseif first == "enum" then
            local descriptor = parse_type_specifier(tokens)
            return { kind = "enum", type = descriptor }
        end
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

local function signature_from_descriptor(descriptor: CType & { result: CType, args: { CType }?, variadic: boolean?, fixedCount: number?, abi: string? }): FunctionSignature
    local args = descriptor.args or {}
    local copy = table.create(#args)
    for index = 1, #args do
        copy[index] = args[index]
    end
    local fixed = if descriptor.fixedCount then descriptor.fixedCount else #copy
    return {
        kind = "function",
        result = descriptor.result,
        args = copy,
        abi = descriptor.abi,
        variadic = descriptor.variadic,
        fixedCount = fixed,
    }
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
    local state: LibraryState? = rawget(self, "__state")
    if state then
        ensure_handle(state)
    end

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

local function create_symbol_proxy(name: string, ptr: NativeHandle, library: any, state: LibraryState)
    return setmetatable({
        __name = name,
        __ptr = ptr,
        __library = library,
        __state = state,
    }, symbol_mt)
end

local library_mt = {}
library_mt.__index = function(self, key)
    local state: LibraryState = rawget(self, "__state")
    if not state then
        error("missing library state", 2)
    end

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
    local proxy = create_symbol_proxy(key, sym, self, state)
    state.symbols[key] = proxy
    return proxy
end

function library_mt:close(): boolean
    local state: LibraryState = rawget(self, "__state")
    if not state then
        return false
    end

    local handle = state.handle
    if not handle then
        return false
    end

    if not state.autoClose then
        return false
    end

    unregister_library_finalizer(state)

    local ok, err = pcall(native.dlclose, handle)
    if not ok then
        register_library_finalizer(self, state)
        error(err, 2)
    end

    clear_library_state(state)
    return true
end

function library_mt:__tostring()
    local state: LibraryState = rawget(self, "__state")
    if state and state.handle then
        return string.format("clibrary: %s", state.name)
    elseif state then
        return string.format("clibrary: %s (closed)", state.name)
    end
    return "clibrary: <invalid>"
end

local function wrap_library(handle: NativeHandle, name: string, autoClose: boolean, cacheKey: string?)
    local state: LibraryState = {
        handle = handle,
        name = name,
        autoClose = autoClose,
        symbols = {},
        cacheKey = cacheKey,
        finalizerIndex = nil,
    }
    local library = setmetatable({ __state = state }, library_mt)
    if autoClose then
        register_library_finalizer(library, state)
    end
    return library
end

local function is_cdata(value: any): boolean
    return type(value) == "table" and rawget(value, "__ffi_cdata") == true
end

local function resolve_ctype(value: any): CType
    local valueType = type(value)
    if valueType == "string" then
        local tokens = tokenize(value)
        return resolve_type_from_tokens(tokens)
    elseif valueType == "table" then
        if is_cdata(value) then
            local descriptor = rawget(value, "__ctype")
            if descriptor then
                return descriptor
            end
        end

        if value.kind and value.code then
            return value :: CType
        end
    end

    error("invalid ctype specification", 3)
end

local get_type_size: (descriptor: CType) -> number
local get_type_align: (descriptor: CType) -> number

local function align_to(value: number, alignment: number): number
    if alignment <= 0 then
        return value
    end

    local remainder = value % alignment
    if remainder == 0 then
        return value
    end

    return value + (alignment - remainder)
end

local function ensure_layout(descriptor: CType)
    if descriptor.kind == "enum" then
        if type(descriptor.size) ~= "number" or type(descriptor.align) ~= "number" then
            local layout = PRIMITIVE_LAYOUTS.int
            descriptor.size = layout.size
            descriptor.align = layout.align
        end
        return
    end

    if descriptor.kind ~= "struct" and descriptor.kind ~= "union" then
        return
    end

    local fields = descriptor.fields
    if not fields then
        descriptor.size = descriptor.size or 0
        descriptor.align = descriptor.align or 1
        return
    end

    local function ensure_field_map(): { [string]: RecordField }
        local map = descriptor.fieldMap
        if not map then
            map = {}
            descriptor.fieldMap = map
        else
            table.clear(map)
        end
        return map
    end

    if descriptor.kind == "union" then
        if type(descriptor.size) == "number" and type(descriptor.align) == "number" then
            return
        end

        local map = ensure_field_map()
        local maxAlign = 1
        local maxSize = 0

        for _, field in ipairs(fields) do
            local fieldType = field.ctype
            ensure_layout(fieldType)
            local align = fieldType.align or 1
            if align > maxAlign then
                maxAlign = align
            end

            local size = get_type_size(fieldType)
            if field.bitWidth ~= nil then
                if field.bitWidth < 0 then
                    error("bitfield width must be non-negative", 3)
                end
                local maxBits = size * 8
                if field.bitWidth > maxBits then
                    error("TODO(@lune/ffi/layout): bitfield width exceeds storage unit", 3)
                end
                field.bitOffset = 0
            else
                field.bitOffset = nil
            end

            field.offset = 0
            if size > maxSize then
                maxSize = size
            end
            map[field.name] = field
        end

        descriptor.align = if maxAlign > 0 then maxAlign else 1
        descriptor.size = align_to(maxSize, descriptor.align)
        return
    end

    if type(descriptor.size) == "number" and type(descriptor.align) == "number" then
        return
    end

    local map = ensure_field_map()
    local offset = 0
    local maxAlign = 1

    local active = nil :: { type: CType, offset: number, size: number, bitsUsed: number }?

    local function flush_active()
        if active then
            offset = active.offset + active.size
            active = nil
        end
    end

    for _, field in ipairs(fields) do
        local fieldType = field.ctype
        ensure_layout(fieldType)
        local align = fieldType.align or 1
        if align > maxAlign then
            maxAlign = align
        end

        if field.bitWidth ~= nil then
            if field.bitWidth < 0 then
                error("bitfield width must be non-negative", 3)
            end

            local unitSize = get_type_size(fieldType)
            local unitBits = unitSize * 8
            if unitBits == 0 then
                error("TODO(@lune/ffi/layout): zero-sized bitfield storage not supported", 3)
            end
            if field.bitWidth > unitBits then
                error("TODO(@lune/ffi/layout): bitfield width exceeds storage unit", 3)
            end

            if not active or active.type ~= fieldType or active.bitsUsed >= unitBits or active.bitsUsed + field.bitWidth > unitBits then
                flush_active()
                offset = align_to(offset, align)
                active = {
                    type = fieldType,
                    offset = offset,
                    size = unitSize,
                    bitsUsed = 0,
                }
            end

            local container = active :: { type: CType, offset: number, size: number, bitsUsed: number }
            field.offset = container.offset
            field.bitOffset = container.bitsUsed
            container.bitsUsed += field.bitWidth
            if container.bitsUsed == unitBits then
                flush_active()
            end
        else
            flush_active()
            offset = align_to(offset, align)
            field.offset = offset
            field.bitOffset = nil
            offset += get_type_size(fieldType)
        end

        map[field.name] = field
    end

    flush_active()

    if maxAlign < 1 then
        maxAlign = 1
    end

    descriptor.align = maxAlign
    descriptor.size = align_to(offset, maxAlign)
end

get_type_size = function(descriptor: CType): number
    ensure_layout(descriptor)
    if type(descriptor.size) == "number" then
        return descriptor.size
    end
    error(string.format("TODO(@lune/ffi/types): sizeof for type '%s' not implemented", descriptor.name), 3)
end

get_type_align = function(descriptor: CType): number
    ensure_layout(descriptor)
    if type(descriptor.align) == "number" then
        return descriptor.align
    end
    error(string.format("TODO(@lune/ffi/types): alignof for type '%s' not implemented", descriptor.name), 3)
end

local function with_pointer_scratch(callback: (NativeHandle) -> any)
    local scratch = native.alloc(POINTER_SIZE)
    local ok, result = pcall(callback, scratch)
    native.free(scratch)
    if ok then
        return result
    end
    error(result, 3)
end

local function pointer_add(base: NativeHandle, offset: number): NativeHandle
    if type(offset) ~= "number" then
        error("pointer offset must be numeric", 3)
    end
    if offset == 0 then
        return base
    end
    if offset < 0 then
        error("pointer offset must be non-negative", 3)
    end
    if offset % 1 ~= 0 then
        error("pointer offset must be integral", 3)
    end

    local integral = offset
    return with_pointer_scratch(function(scratch)
        local okStore, storeErr = pcall(native.storeScalar, scratch, "pointer", base)
        if not okStore then
            error(storeErr, 3)
        end

        local okAddr, addrOrErr = pcall(native.loadScalar, scratch, "uintptr_t")
        if not okAddr then
            error(addrOrErr, 3)
        end
        local address = addrOrErr
        if type(address) ~= "number" then
            error("native.loadScalar returned non-numeric pointer address", 3)
        end

        local resultAddress = address + integral
        if resultAddress < 0 then
            error("pointer arithmetic produced negative address", 3)
        end

        local okStoreAddr, storeAddrErr = pcall(native.storeScalar, scratch, "uintptr_t", resultAddress)
        if not okStoreAddr then
            error(storeAddrErr, 3)
        end

        local okLoadPtr, ptrOrErr = pcall(native.loadScalar, scratch, "pointer")
        if not okLoadPtr then
            error(ptrOrErr, 3)
        end

        return ptrOrErr :: NativeHandle
    end)
end

local function copy_memory(dest: NativeHandle, source: NativeHandle?, size: number)
    if size <= 0 then
        return
    end
    if source == nil then
        error("cannot copy from null pointer", 3)
    end

    local okRead, dataOrErr = pcall(native.readString, source :: NativeHandle, size)
    if not okRead then
        error(dataOrErr, 3)
    end
    local bytes = dataOrErr

    local okWrite, writeErr = pcall(native.writeBytes, dest, bytes, false)
    if not okWrite then
        error(writeErr, 3)
    end
end

local function convert_scalar_to_pointer(value: any): NativeHandle?
    return with_pointer_scratch(function(scratch)
        local ok, err = pcall(native.storeScalar, scratch, "pointer", value)
        if not ok then
            error(err, 3)
        end

        local okLoad, loaded = pcall(native.loadScalar, scratch, "pointer")
        if not okLoad then
            error(loaded, 3)
        end

        if loaded == nil then
            return nil
        end

        if type(loaded) ~= "userdata" then
            error("native.loadScalar returned unexpected value for pointer", 3)
        end

        return loaded :: NativeHandle
    end)
end

local function coerce_pointer_value(value: any): NativeHandle?
    local valueType = type(value)
    if value == nil then
        return nil
    elseif valueType == "userdata" then
        return value :: NativeHandle
    elseif valueType == "table" and is_cdata(value) then
        local ptr = rawget(value, "__ptr")
        if ptr == nil then
            return nil
        end
        return ptr :: NativeHandle
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("pointer value must be finite", 3)
        end
        if value < 0 then
            error("pointer value must be non-negative", 3)
        end
        if value % 1 ~= 0 then
            error("pointer value must be integral", 3)
        end
        return convert_scalar_to_pointer(value)
    elseif valueType == "boolean" then
        if value then
            error("cannot convert boolean 'true' to pointer", 3)
        end
        return nil
    else
        error("cannot convert value to pointer", 3)
    end
end

local function get_scalar_code(descriptor: CType): string
    if descriptor.kind == "primitive" then
        return descriptor.code
    elseif descriptor.kind == "enum" then
        return "int"
    end
    error(string.format("type '%s' is not a scalar", descriptor.name), 3)
end

local function is_unsigned_code(code: string?): boolean
    if type(code) ~= "string" then
        return false
    end
    local lowered = code:lower()
    return lowered:find("unsigned", 1, true) ~= nil or lowered:find("uint", 1, true) ~= nil
end

local store_value
local assign_record_value

local function write_bitfield_value(basePtr: NativeHandle, field: RecordField, value: any)
    local width = field.bitWidth
    if not width or width <= 0 then
        return
    end

    local containerType = field.ctype
    local totalBits = get_type_size(containerType) * 8
    local shift = field.bitOffset or 0

    if totalBits <= 0 then
        error("bitfield container has zero size", 3)
    end
    if width > 52 or shift + width > 52 or totalBits > 52 then
        error("bitfield assignments wider than 52 bits not supported", 3)
    end

    local numeric
    local valueType = type(value)
    if valueType == "boolean" then
        numeric = if value then 1 else 0
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("bitfield value must be finite", 3)
        end
        numeric = value
    else
        error("bitfield value must be numeric or boolean", 3)
    end

    if math.floor(numeric + 0.0) ~= numeric then
        error("bitfield value must be integral", 3)
    end

    local signedField = not is_unsigned_code(containerType.code)
    local range = 2 ^ width
    local minValue = if signedField then -(range / 2) else 0
    local maxValue = if signedField then (range / 2) - 1 else range - 1

    if numeric < minValue or numeric > maxValue then
        error(string.format("bitfield value %d out of range", numeric), 3)
    end

    local unsignedValue = if signedField and numeric < 0 then numeric + range else numeric

    local containerPtr = pointer_add(basePtr, field.offset or 0)
    local okRead, currentOrErr = pcall(native.loadScalar, containerPtr, containerType.code)
    if not okRead then
        error(currentOrErr, 3)
    end

    local currentValue = currentOrErr
    if type(currentValue) ~= "number" then
        error("bitfield container read produced non-numeric value", 3)
    end

    local containerUnsigned = currentValue
    if containerUnsigned < 0 then
        containerUnsigned += 2 ^ totalBits
    end

    local lowerMask = 2 ^ shift
    local lower = if shift == 0 then 0 else containerUnsigned % lowerMask
    local upperFactor = 2 ^ (shift + width)
    local higher = math.floor(containerUnsigned / upperFactor)
    local resultUnsigned = lower + unsignedValue * lowerMask + higher * upperFactor

    local storeNumeric
    if is_unsigned_code(containerType.code) then
        storeNumeric = resultUnsigned
    else
        local signThreshold = 2 ^ (totalBits - 1)
        if resultUnsigned >= signThreshold then
            storeNumeric = resultUnsigned - 2 ^ totalBits
        else
            storeNumeric = resultUnsigned
        end
    end

    local okStore, storeErr = pcall(native.storeScalar, containerPtr, containerType.code, storeNumeric)
    if not okStore then
        error(storeErr, 3)
    end
end

local function initialize_record_from_table(ptr: NativeHandle, descriptor: CType, init: { [any]: any })
    ensure_layout(descriptor)
    local fields = descriptor.fields
    if not fields then
        return
    end

    if descriptor.kind == "union" then
        local selectedField: RecordField? = nil
        local selectedValue: any = nil
        local arrayIndex = 1

        for _, field in ipairs(fields) do
            local value = init[field.name]
            if value == nil then
                value = init[arrayIndex]
                if value ~= nil then
                    arrayIndex += 1
                end
            end
            if value ~= nil then
                selectedField = field
                selectedValue = value
                break
            end
        end

        if selectedField ~= nil then
            if selectedField.bitWidth ~= nil then
                write_bitfield_value(ptr, selectedField, selectedValue)
            else
                local fieldPtr = pointer_add(ptr, selectedField.offset or 0)
                assert(store_value ~= nil)
                store_value(fieldPtr, selectedField.ctype, selectedValue)
            end
        end
        return
    end

    local arrayIndex = 1
    for _, field in ipairs(fields) do
        local value = init[field.name]
        if value == nil then
            value = init[arrayIndex]
            if value ~= nil then
                arrayIndex += 1
            end
        end
        if value ~= nil then
            if field.bitWidth ~= nil then
                write_bitfield_value(ptr, field, value)
            else
                local fieldPtr = pointer_add(ptr, field.offset or 0)
                assert(store_value ~= nil)
                store_value(fieldPtr, field.ctype, value)
            end
        end
    end
end

assign_record_value = function(ptr: NativeHandle, descriptor: CType, value: any)
    if value == nil then
        return
    end

    local valueType = type(value)
    if valueType == "table" then
        if is_cdata(value) then
            local valueDescriptor = resolve_ctype(value)
            if valueDescriptor.kind == "pointer" then
                local base = valueDescriptor.base
                if base ~= descriptor then
                    if not (base and base.kind == "primitive" and base.code == "void") then
                        error(string.format("cannot initialize %s from pointer to %s", descriptor.name, base and base.name or "<unknown>"), 3)
                    end
                end
                local sourcePtr = coerce_pointer_value(value)
                if sourcePtr == nil then
                    error(string.format("cannot copy from null pointer into %s", descriptor.name), 3)
                end
                copy_memory(ptr, sourcePtr, get_type_size(descriptor))
            else
                if valueDescriptor ~= descriptor then
                    error(string.format("expected value of type '%s'", descriptor.name), 3)
                end
                local sourcePtr = rawget(value, "__ptr")
                if sourcePtr == nil then
                    error("cdata value missing native pointer", 3)
                end
                copy_memory(ptr, sourcePtr :: NativeHandle, get_type_size(descriptor))
            end
        else
            initialize_record_from_table(ptr, descriptor, value)
        end
    elseif valueType == "userdata" then
        copy_memory(ptr, value :: NativeHandle, get_type_size(descriptor))
    elseif valueType == "string" then
        local size = get_type_size(descriptor)
        if #value < size then
            error(string.format("initializer string too short for type '%s'", descriptor.name), 3)
        end
        local slice = if #value == size then value else value:sub(1, size)
        local okWrite, writeErr = pcall(native.writeBytes, ptr, slice, false)
        if not okWrite then
            error(writeErr, 3)
        end
    else
        error(string.format("cannot initialize %s from value of type '%s'", descriptor.name, valueType), 3)
    end
end

store_value = function(ptr: NativeHandle, descriptor: CType, value: any)
    local kind = descriptor.kind
    if kind == "primitive" then
        local ok, err = pcall(native.storeScalar, ptr, descriptor.code, value)
        if not ok then
            error(err, 3)
        end
    elseif kind == "enum" then
        local ok, err = pcall(native.storeScalar, ptr, "int", value)
        if not ok then
            error(err, 3)
        end
    elseif kind == "pointer" then
        local pointerValue = coerce_pointer_value(value)
        local ok, err = pcall(native.storeScalar, ptr, "pointer", pointerValue)
        if not ok then
            error(err, 3)
        end
    elseif kind == "struct" or kind == "union" then
        assert(assign_record_value ~= nil)
        assign_record_value(ptr, descriptor, value)
    else
        error(string.format("cannot assign value to type '%s'", descriptor.name), 3)
    end
end

local function unwrap_pointer(value: any): NativeHandle
    local valueType = type(value)
    if valueType == "userdata" then
        return value :: NativeHandle
    elseif valueType == "table" and is_cdata(value) then
        local ptr = rawget(value, "__ptr")
        if ptr == nil then
            error("cdata has null pointer", 3)
        end
        return ptr :: NativeHandle
    end

    error("expected cdata or lightuserdata", 3)
end

local cdata_mt = {}

local function get_descriptor_meta(descriptor: CType): { [string]: any }?
    local meta = descriptor.metatype
    if type(meta) == "table" then
        return meta
    end
    return nil
end

local function get_object_meta(self): { [string]: any }?
    local meta = rawget(self, "__meta")
    if type(meta) == "table" then
        return meta
    end
    local descriptor: CType? = rawget(self, "__ctype")
    if descriptor then
        local descriptorMeta = get_descriptor_meta(descriptor)
        if descriptorMeta then
            rawset(self, "__meta", descriptorMeta)
            return descriptorMeta
        end
    end
    return nil
end

function cdata_mt:__index(key)
    local meta = get_object_meta(self)
    if meta then
        local indexer = rawget(meta, "__index")
        if type(indexer) == "function" then
            return indexer(self, key)
        elseif type(indexer) == "table" then
            local value = indexer[key]
            if value ~= nil then
                return value
            end
        end
    end
    return rawget(cdata_mt, key)
end

function cdata_mt:__newindex(key, value)
    local meta = get_object_meta(self)
    if meta then
        local handler = rawget(meta, "__newindex")
        if type(handler) == "function" then
            handler(self, key, value)
            return
        elseif type(handler) == "table" then
            handler[key] = value
            return
        end
    end
    rawset(self, key, value)
end

function cdata_mt:__tostring()
    local meta = get_object_meta(self)
    if meta then
        local handler = rawget(meta, "__tostring")
        if type(handler) == "function" then
            return handler(self)
        end
    end

    local descriptor: CType? = rawget(self, "__ctype")
    local ptr: NativeHandle? = rawget(self, "__ptr")
    local name = if descriptor and descriptor.name then descriptor.name else "<unknown>"
    local pointerRepr = if ptr then tostring(ptr) else "NULL"
    return string.format("cdata<%s>:%s", name, pointerRepr)
end

function cdata_mt:__len()
    local meta = get_object_meta(self)
    if meta then
        local handler = rawget(meta, "__len")
        if type(handler) == "function" then
            return handler(self)
        end
    end
    error("length operation not defined for cdata", 2)
end

function cdata_mt:__call(...)
    local meta = get_object_meta(self)
    if meta then
        local handler = rawget(meta, "__call")
        if type(handler) == "function" then
            return handler(self, ...)
        end
    end
    error("attempt to call cdata value", 2)
end

function cdata_mt:__eq(other)
    local meta = get_object_meta(self)
    if meta then
        local handler = rawget(meta, "__eq")
        if type(handler) == "function" then
            return handler(self, other)
        end
    end

    if type(other) == "table" and is_cdata(other) then
        local selfPtr = rawget(self, "__ptr")
        local otherPtr = rawget(other, "__ptr")
        if selfPtr ~= nil and otherPtr ~= nil then
            return selfPtr == otherPtr
        end
    end

    return rawequal(self, other)
end

function cdata_mt:__gc()
    local finalizer = rawget(self, "__finalizer")
    if type(finalizer) == "function" then
        rawset(self, "__finalizer", nil)
        local ok, err = pcall(finalizer, self)
        if not ok then
            warn_if_available(string.format("ffi: error in cdata finalizer: %s", tostring(err)))
        end
    end

    if rawget(self, "__owned") then
        local ptr = rawget(self, "__ptr")
        if ptr ~= nil then
            native.free(ptr :: NativeHandle)
            rawset(self, "__ptr", nil)
        end
    end
end

local function create_cdata(descriptor: CType, pointer: NativeHandle?, owned: boolean): any
    local object = {
        __ffi_cdata = true,
        __ctype = descriptor,
        __owned = owned,
    }

    if pointer then
        rawset(object, "__ptr", pointer)
    end

    local meta = get_descriptor_meta(descriptor)
    if meta then
        rawset(object, "__meta", meta)
    end

    return setmetatable(object, cdata_mt)
end

local function allocate_scalar(descriptor: CType, init: any?): any
    local size = get_type_size(descriptor)
    local ptr = native.alloc(size)

    local ok, err = pcall(function()
        if init ~= nil then
            local code = get_scalar_code(descriptor)
            local okStore, storeErr = pcall(native.storeScalar, ptr, code, init)
            if not okStore then
                error(storeErr, 3)
            end
        end
    end)

    if not ok then
        native.free(ptr)
        error(err, 3)
    end

    return create_cdata(descriptor, ptr, true)
end

local function allocate_record(descriptor: CType, init: any?): any
    local size = get_type_size(descriptor)
    local ptr = native.alloc(size)

    local ok, err = pcall(function()
        if init ~= nil then
            assert(assign_record_value ~= nil)
            assign_record_value(ptr, descriptor, init)
        end
    end)

    if not ok then
        native.free(ptr)
        error(err, 3)
    end

    return create_cdata(descriptor, ptr, true)
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
        elseif declaration.kind == "struct" or declaration.kind == "union" or declaration.kind == "enum" then
            -- definitions already recorded in the registry via parse_type_specifier
        else
            error(string.format("TODO(@lune/ffi/cdef): declaration kind '%s' not supported", tostring(declaration.kind)), 2)
        end
    end
end

local function create_process_library(): any
    local ok, result = pcall(native.dlopen, nil)
    if not ok then
        error(result, 2)
    end
    return wrap_library(result :: NativeHandle, "<process>", false, nil)
end

ffi.C = create_process_library()

function ffi.load(libnameOrPath: string?): any
    if libnameOrPath == nil then
        return ffi.C
    end
    if type(libnameOrPath) ~= "string" then
        error("ffi.load expects a string or nil", 2)
    end

    local trimmed = trim(libnameOrPath)
    if trimmed == "" then
        error("ffi.load expects a non-empty library name", 2)
    end

    local cached = libraryCache[trimmed]
    if cached then
        local state: LibraryState? = rawget(cached, "__state")
        if state and state.handle then
            return cached
        end
        libraryCache[trimmed] = nil
    end

    local ok, handleOrErr = pcall(native.dlopen, libnameOrPath)
    if not ok then
        error(handleOrErr, 2)
    end
    local handle = handleOrErr :: NativeHandle
    local library = wrap_library(handle, libnameOrPath, true, trimmed)
    libraryCache[trimmed] = library
    return library
end

function ffi.typeof(spec: any): CType
    return resolve_ctype(spec)
end

function ffi.new(spec: any, ...): any
    local descriptor = resolve_ctype(spec)

    if descriptor.kind == "primitive" or descriptor.kind == "enum" then
        local init = if select("#", ...) >= 1 then select(1, ...) else nil
        return allocate_scalar(descriptor, init)
    elseif descriptor.kind == "pointer" then
        local pointerValue: NativeHandle? = nil
        if select("#", ...) >= 1 then
            pointerValue = coerce_pointer_value(select(1, ...))
        end
        return create_cdata(descriptor, pointerValue, false)
    elseif descriptor.kind == "struct" or descriptor.kind == "union" then
        local init = if select("#", ...) >= 1 then select(1, ...) else nil
        return allocate_record(descriptor, init)
    end

    error(string.format("ffi.new does not support type '%s'", descriptor.name), 2)
end

function ffi.cast(spec: any, value: any): any
    local descriptor = resolve_ctype(spec)

    if descriptor.kind == "pointer" then
        local base = rawget(descriptor, "base")
        if base and base.kind == "function" and type(value) == "function" then
            local signature = signature_from_descriptor(base)
            local ptr, handle = native.createCallback(signature, value)
            local cdata = create_cdata(descriptor, ptr, false)
            if handle ~= nil then
                rawset(cdata, "__callback_handle", handle)
            end
            return cdata
        end

        local callbackHandle = nil
        if type(value) == "table" and is_cdata(value) then
            callbackHandle = rawget(value, "__callback_handle")
        end

        local pointerValue = coerce_pointer_value(value)
        local object = create_cdata(descriptor, pointerValue, false)
        if callbackHandle ~= nil then
            rawset(object, "__callback_handle", callbackHandle)
        end
        return object
    elseif descriptor.kind == "primitive" or descriptor.kind == "enum" then
        return allocate_scalar(descriptor, value)
    elseif descriptor.kind == "struct" or descriptor.kind == "union" then
        return allocate_record(descriptor, value)
    end

    error(string.format("ffi.cast does not support type '%s'", descriptor.name), 2)
end

function ffi.string(value: any, len: number?): string
    local pointer: NativeHandle
    local valueType = type(value)
    if valueType == "userdata" then
        pointer = value :: NativeHandle
    elseif valueType == "table" and is_cdata(value) then
        local ptr = rawget(value, "__ptr")
        if ptr == nil then
            error("ffi.string expects a non-null pointer", 2)
        end
        pointer = ptr :: NativeHandle
    else
        error("ffi.string expects cdata or lightuserdata", 2)
    end

    local lengthArg: number? = nil
    if len ~= nil then
        if type(len) ~= "number" then
            error("ffi.string length must be a number", 2)
        end
        if len < 0 then
            error("ffi.string length must be non-negative", 2)
        end
        lengthArg = math.floor(len + 0.0)
    end

    local ok, result = pcall(native.readString, pointer, lengthArg)
    if not ok then
        error(result, 2)
    end

    return result
end

function ffi.gc(value: any, finalizer: ((any) -> ())?)
    local valueType = type(value)
    if valueType == "userdata" then
        error("TODO(@lune/ffi/gc): finalizers for lightuserdata not supported yet", 2)
    end
    if not is_cdata(value) then
        error("ffi.gc expects a cdata value", 2)
    end
    if finalizer ~= nil and type(finalizer) ~= "function" then
        error("ffi.gc finalizer must be a function or nil", 2)
    end

    if finalizer then
        rawset(value, "__finalizer", finalizer)
    else
        rawset(value, "__finalizer", nil)
    end

    return value
end

function ffi.metatype(spec: any, methods: { [string]: any })
    if methods == nil then
        error("ffi.metatype expects a metamethod table", 2)
    end
    if type(methods) ~= "table" then
        error("ffi.metatype metamethods must be provided as a table", 2)
    end

    local descriptor = resolve_ctype(spec)
    if descriptor.kind ~= "struct" and descriptor.kind ~= "union" and descriptor.kind ~= "pointer" then
        error(string.format("ffi.metatype does not support type '%s' yet", descriptor.name), 2)
    end

    local copy = {}
    for key, value in pairs(methods) do
        copy[key] = value
    end

    descriptor.metatype = copy
    return descriptor
end

function ffi.sizeof(spec: any): number
    local descriptor = resolve_ctype(spec)
    return get_type_size(descriptor)
end

function ffi.alignof(spec: any): number
    local descriptor = resolve_ctype(spec)
    return get_type_align(descriptor)
end

function ffi.errno(value: any?): number
    if value ~= nil then
        local ok, err = pcall(native.setErrno, value)
        if not ok then
            error(err, 2)
        end
    end

    local ok, result = pcall(native.getErrno)
    if not ok then
        error(result, 2)
    end

    return result
end

function ffi.offsetof(spec: any, field: string): number
    if type(field) ~= "string" then
        error("ffi.offsetof expects field name string", 2)
    end

    local descriptor = resolve_ctype(spec)
    if descriptor.kind ~= "struct" and descriptor.kind ~= "union" then
        error("ffi.offsetof expects a struct or union type", 2)
    end

    ensure_layout(descriptor)
    local map = descriptor.fieldMap
    if not map then
        error("TODO(@lune/ffi/offsetof): missing field metadata", 2)
    end

    local entry = map[field]
    if not entry then
        error(string.format("field '%s' not found", field), 2)
    end

    if entry.bitWidth ~= nil then
        error("TODO(@lune/ffi/offsetof): bitfield offsets not supported", 2)
    end

    local offset = entry.offset
    if type(offset) ~= "number" then
        error("TODO(@lune/ffi/offsetof): offset metadata missing", 2)
    end

    return offset
end

function ffi.abi(...: string): boolean
    local count = select("#", ...)
    if count == 0 then
        error("ffi.abi expects at least one attribute", 2)
    end

    local results = table.create(count)
    for index = 1, count do
        local attr = select(index, ...)
        if type(attr) ~= "string" then
            error("ffi.abi attribute must be a string", 2)
        end
        local value = ABI_FLAGS[attr]
        if value == nil then
            error(string.format("unknown ABI attribute '%s'", attr), 2)
        end
        results[index] = value == true
    end

    return table.unpack(results, 1, count)
end

ffi.os = PLATFORM_OS
ffi.arch = PLATFORM_ARCH

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

function debug.readScalar(object: any): any
    if not is_cdata(object) then
        error("debug.readScalar expects cdata", 2)
    end

    local descriptor = resolve_ctype(object)
    if descriptor.kind == "primitive" then
        local ptr = unwrap_pointer(object)
        local ok, result = pcall(native.loadScalar, ptr, descriptor.code)
        if not ok then
            error(result, 2)
        end
        return result
    elseif descriptor.kind == "pointer" then
        return rawget(object, "__ptr")
    end

    error("debug.readScalar only supports primitive and pointer types", 2)
end

function debug.writeBytes(target: any, data: string, appendNull: boolean?)
    local pointer: NativeHandle
    if is_cdata(target) then
        pointer = unwrap_pointer(target)
    elseif type(target) == "userdata" then
        pointer = target :: NativeHandle
    else
        error("debug.writeBytes expects cdata or lightuserdata", 2)
    end

    local ok, err = pcall(native.writeBytes, pointer, data, appendNull == true)
    if not ok then
        error(err, 2)
    end
end

function debug.alloc(size: number): NativeHandle
    if type(size) ~= "number" then
        error("debug.alloc expects numeric size", 2)
    end
    if size < 0 then
        error("debug.alloc size must be non-negative", 2)
    end
    local ok, result = pcall(native.alloc, math.floor(size + 0.0))
    if not ok then
        error(result, 2)
    end
    return result
end

function debug.free(ptr: any)
    if ptr == nil then
        return
    end
    if type(ptr) ~= "userdata" then
        error("debug.free expects lightuserdata", 2)
    end
    native.free(ptr :: NativeHandle)
end

ffi._debug = debug -- TODO(@lune/ffi): remove debug helpers once parser populates signatures.

return ffi
