return function(ctx)
    local ffi = ctx.ffi
    local test = ctx.test
    local assertEqual = ctx.assertEqual
    local libcprLibraryPath = ctx.libcprLibraryPath
    local targetUrl = ctx.libcprUrl
    local expectedBody = ctx.libcprExpectedBody

    test("libcpr wrapper performs HTTP requests", function()
        assert(type(libcprLibraryPath) == "string" and #libcprLibraryPath > 0, "expected libcpr library path")
        assert(type(targetUrl) == "string" and #targetUrl > 0, "expected libcpr target URL")

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

        local libcpr = ffi.load(libcprLibraryPath)
        local response = libcpr.luneffi_cpr_get(targetUrl)
        assert(response ~= nil, "expected non-null response pointer")

        local responsePtr = ffi.cast(ffi.typeof("LuneCprResponse*"), response)
        local result = responsePtr

        local function readString(ptr, length)
            if ptr == nil then
                return nil
            end

            return ffi.string(ptr, tonumber(length))
        end

        assertEqual(libcpr.luneffi_cpr_response_error_code(responsePtr), 0)

        local body = readString(
            libcpr.luneffi_cpr_response_text_data(responsePtr),
            libcpr.luneffi_cpr_response_text_length(responsePtr)
        )
        assert(type(body) == "string", "expected response body string")
        if type(expectedBody) == "string" then
            assertEqual(body, expectedBody)
        end

        local errorMessage = readString(
            libcpr.luneffi_cpr_response_error_data(responsePtr),
            libcpr.luneffi_cpr_response_error_length(responsePtr)
        )
        assert(errorMessage == nil or #errorMessage == 0, "expected no cpr error message")

        assertEqual(libcpr.luneffi_cpr_response_status(responsePtr), 200)

        libcpr.luneffi_cpr_response_free(responsePtr)
    end)

    test("libcpr example script runs without errors", function()
        assert(type(libcprLibraryPath) == "string" and #libcprLibraryPath > 0, "expected libcpr library path")

        local ok, err = pcall(function()
            rawset(_G, "LIBCPR_LIBRARY_PATH", libcprLibraryPath)
            rawset(_G, "LIBCPR_EXAMPLE_URL", targetUrl)
            require("../examples/libcpr_get")
        end)

        if not ok then
            error(err, 0)
        end
    end)
end
