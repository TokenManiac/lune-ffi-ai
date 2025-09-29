#include <stddef.h>

#if defined(_WIN32)
#define EXAMPLE_EXPORT __declspec(dllexport)
#else
#define EXAMPLE_EXPORT __attribute__((visibility("default")))
#endif

typedef int (*ExampleCallback)(int);

EXAMPLE_EXPORT int example_add_ints(int a, int b) {
    return a + b;
}

EXAMPLE_EXPORT const char* example_greeting(void) {
    return "Hello from libexample";
}

EXAMPLE_EXPORT void example_invoke(ExampleCallback cb, int value) {
    if (cb != NULL) {
        cb(value);
    }
}
