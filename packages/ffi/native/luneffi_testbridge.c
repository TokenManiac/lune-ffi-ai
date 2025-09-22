#include "luneffi_loader.h"

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

int luneffi_test_add_ints(int a, int b) {
    return a + b;
}

int luneffi_test_variadic_sum(int count, ...) {
    va_list args;
    va_start(args, count);

    long long total = 0;
    for (int index = 0; index < count; ++index) {
        total += va_arg(args, int);
    }

    va_end(args);
    return (int)total;
}

int luneffi_test_variadic_format(char* buffer, size_t size, const char* fmt, ...) {
    if (buffer == NULL || size == 0) {
        return -1;
    }

    va_list args;
    va_start(args, fmt);
    int written = vsnprintf(buffer, size, fmt, args);
    va_end(args);
    return written;
}
