local ffi = require("@lune/ffi")

ffi.cdef([[typedef struct LuneCprString {
    const char* data;
    unsigned long long length;
} LuneCprString;

typedef struct LuneCprResponse {
    int status_code;
    int error_code;
    LuneCprString text;
    LuneCprString error;
} LuneCprResponse;

LuneCprResponse* luneffi_cpr_get(const char* url);
void luneffi_cpr_response_free(LuneCprResponse* response);
int luneffi_cpr_response_status(const LuneCprResponse* response);
int luneffi_cpr_response_error_code(const LuneCprResponse* response);
const char* luneffi_cpr_response_text_data(const LuneCprResponse* response);
unsigned long long luneffi_cpr_response_text_length(const LuneCprResponse* response);
const char* luneffi_cpr_response_error_data(const LuneCprResponse* response);
unsigned long long luneffi_cpr_response_error_length(const LuneCprResponse* response);
]])

local function resolveLibraryPath()
    local override = rawget(_G, "LIBCPR_LIBRARY_PATH")
    if type(override) == "string" and #override > 0 then
        return override
    end

    if ffi.os == "Windows" then
        return "./cpr_ffi.dll"
    elseif ffi.os == "OSX" then
        return "./libcpr_ffi.dylib"
    else
        return "./libcpr_ffi.so"
    end
end

local function resolveTargetUrl()
    local override = rawget(_G, "LIBCPR_EXAMPLE_URL")
    if type(override) == "string" and #override > 0 then
        return override
    end

    return "https://example.com"
end

local libcpr = ffi.load(resolveLibraryPath())
local response = libcpr.luneffi_cpr_get(resolveTargetUrl())

if response == nil then
    error("libcpr_get: request failed to allocate response", 0)
end

local responsePtr = ffi.cast(ffi.typeof("LuneCprResponse*"), response)

local function asString(ptr, length)
    if ptr == nil then
        return nil
    end

    return ffi.string(ptr, tonumber(length))
end

local status = libcpr.luneffi_cpr_response_status(responsePtr)
local body = asString(
    libcpr.luneffi_cpr_response_text_data(responsePtr),
    libcpr.luneffi_cpr_response_text_length(responsePtr)
)
local err = asString(
    libcpr.luneffi_cpr_response_error_data(responsePtr),
    libcpr.luneffi_cpr_response_error_length(responsePtr)
)

libcpr.luneffi_cpr_response_free(responsePtr)

print(string.format("Status: %d", status))

if err ~= nil then
    print("libcpr error:", err)
else
    print("Body:", body)
end
