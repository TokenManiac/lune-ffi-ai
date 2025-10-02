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

typedef struct {
    int x;
    double y;
} RuntimeStructInit;

LUNEFFI_TEST_EXPORT int luneffi_test_struct_get_x(const RuntimeStructInit* value) {
    return value != NULL ? value->x : 0;
}

LUNEFFI_TEST_EXPORT double luneffi_test_struct_get_y(const RuntimeStructInit* value) {
    return value != NULL ? value->y : 0.0;
}

typedef struct {
    int* target;
    int flag;
} RuntimePointerStruct;

LUNEFFI_TEST_EXPORT int luneffi_test_pointer_struct_flag(const RuntimePointerStruct* value) {
    return value != NULL ? value->flag : -1;
}

LUNEFFI_TEST_EXPORT int luneffi_test_pointer_struct_read(const RuntimePointerStruct* value) {
    if (value == NULL || value->target == NULL) {
        return -1;
    }
    return *value->target;
}

typedef union {
    int as_int;
    void* as_ptr;
} RuntimeTaggedUnion;

LUNEFFI_TEST_EXPORT int luneffi_test_union_int(const RuntimeTaggedUnion* value) {
    return value != NULL ? value->as_int : 0;
}

LUNEFFI_TEST_EXPORT int luneffi_test_union_is_ptr(const RuntimeTaggedUnion* value, void* ptr) {
    if (value == NULL) {
        return 0;
    }
    return value->as_ptr == ptr;
}
