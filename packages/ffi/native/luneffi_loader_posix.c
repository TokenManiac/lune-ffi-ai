#include "luneffi_loader.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <string.h>

#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void*)0)
#endif

static __thread char luneffi_last_error[512];

static void luneffi_set_error(const char* message) {
    if (message == NULL) {
        luneffi_last_error[0] = '\0';
        return;
    }
    size_t len = strlen(message);
    if (len >= sizeof(luneffi_last_error)) {
        len = sizeof(luneffi_last_error) - 1;
    }
    memcpy(luneffi_last_error, message, len);
    luneffi_last_error[len] = '\0';
}

void* luneffi_dlopen(const char* path) {
    luneffi_set_error(NULL);
    void* handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (handle == NULL) {
        const char* err = dlerror();
        luneffi_set_error(err ? err : "unknown dlopen error");
    }
    return handle;
}

void* luneffi_dlsym(void* handle, const char* name) {
    luneffi_set_error(NULL);
    void* resolved = dlsym(handle ? handle : RTLD_DEFAULT, name);
    if (resolved == NULL) {
        const char* err = dlerror();
        luneffi_set_error(err ? err : "symbol lookup failed");
    }
    return resolved;
}

int luneffi_dlclose(void* handle) {
    if (handle == NULL) {
        return 0;
    }
    luneffi_set_error(NULL);
    int rc = dlclose(handle);
    if (rc != 0) {
        const char* err = dlerror();
        luneffi_set_error(err ? err : "dlclose failed");
    }
    return rc;
}

const char* luneffi_dlerror(void) {
    if (luneffi_last_error[0] == '\0') {
        return NULL;
    }
    return luneffi_last_error;
}
