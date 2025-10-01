#include <cpr/cpr.h>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>
#include <string>

extern "C" {

struct LuneCprString {
    const char* data;
    unsigned long long length;
};

struct LuneCprResponse {
    int status_code;
    int error_code;
    LuneCprString text;
    LuneCprString error;
};

static LuneCprString make_string(const std::string& input) {
    LuneCprString result{nullptr, 0};

    const auto length = static_cast<unsigned long long>(input.size());
    char* buffer = static_cast<char*>(std::malloc(length + 1));
    if (buffer == nullptr) {
        return result;
    }

    if (length > 0) {
        std::memcpy(buffer, input.data(), length);
    }
    buffer[length] = '\0';

    result.data = buffer;
    result.length = length;
    return result;
}

static void destroy_string(LuneCprString& value) {
    if (value.data != nullptr) {
        std::free(const_cast<char*>(value.data));
        value.data = nullptr;
        value.length = 0;
    }
}

LuneCprResponse* luneffi_cpr_get(const char* url) {
    if (url == nullptr) {
        return nullptr;
    }

    auto response = cpr::Get(
        cpr::Url{url},
        cpr::Proxies{{"http", ""}, {"https", ""}},
        cpr::Timeout{5000}
    );

    auto* result = new (std::nothrow) LuneCprResponse{};
    if (result == nullptr) {
        return nullptr;
    }

    result->status_code = response.status_code;
    result->error_code = static_cast<int>(response.error.code);
    result->text = make_string(response.text);
    if (!response.error.message.empty()) {
        result->error = make_string(response.error.message);
    } else {
        result->error = LuneCprString{nullptr, 0};
    }

    return result;
}

void luneffi_cpr_response_free(LuneCprResponse* response) {
    if (response == nullptr) {
        return;
    }

    destroy_string(response->text);
    destroy_string(response->error);
    delete response;
}

int luneffi_cpr_response_status(const LuneCprResponse* response) {
    return response != nullptr ? response->status_code : 0;
}

int luneffi_cpr_response_error_code(const LuneCprResponse* response) {
    return response != nullptr ? response->error_code : -1;
}

const char* luneffi_cpr_response_text_data(const LuneCprResponse* response) {
    return (response != nullptr && response->text.data != nullptr) ? response->text.data : nullptr;
}

unsigned long long luneffi_cpr_response_text_length(const LuneCprResponse* response) {
    return response != nullptr ? response->text.length : 0ULL;
}

const char* luneffi_cpr_response_error_data(const LuneCprResponse* response) {
    return (response != nullptr && response->error.data != nullptr) ? response->error.data : nullptr;
}

unsigned long long luneffi_cpr_response_error_length(const LuneCprResponse* response) {
    return response != nullptr ? response->error.length : 0ULL;
}

}
