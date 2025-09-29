#include "luneffi_loader.h"

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

#if defined(_WIN32)
#define LUNEFFI_TEST_EXPORT __declspec(dllexport)
#else
#define LUNEFFI_TEST_EXPORT __attribute__((visibility("default")))
#endif

LUNEFFI_TEST_EXPORT int luneffi_test_add_ints(int a, int b) {
    return a + b;
}

LUNEFFI_TEST_EXPORT int luneffi_test_variadic_sum(int count, ...) {
    va_list args;
    va_start(args, count);

    long long total = 0;
    for (int index = 0; index < count; ++index) {
        total += va_arg(args, int);
    }

    va_end(args);
    return (int)total;
}

LUNEFFI_TEST_EXPORT int luneffi_test_variadic_format(char* buffer, size_t size, const char* fmt, ...) {
    if (buffer == NULL || size == 0) {
        return -1;
    }

    va_list args;
    va_start(args, fmt);
    int written = vsnprintf(buffer, size, fmt, args);
    va_end(args);
    return written;
}

typedef int (*luneffi_unary_callback)(int);

LUNEFFI_TEST_EXPORT int luneffi_test_call_callback(luneffi_unary_callback cb, int value) {
    if (cb == NULL) {
        return -1;
    }
    return cb(value);
}
