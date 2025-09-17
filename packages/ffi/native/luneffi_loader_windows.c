#include "luneffi_loader.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <string.h>

static __declspec(thread) char luneffi_last_error[512];

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

static void luneffi_capture_last_error(const char* context) {
    DWORD err = GetLastError();
    if (err == 0) {
        luneffi_set_error(context);
        return;
    }

    DWORD flags = FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS;
    char buffer[512];
    DWORD len = FormatMessageA(
        flags,
        NULL,
        err,
        0,
        buffer,
        (DWORD)sizeof(buffer),
        NULL
    );

    if (len == 0) {
        snprintf(luneffi_last_error, sizeof(luneffi_last_error), "%s (error %lu)", context, (unsigned long)err);
        return;
    }

    // Trim trailing newlines added by FormatMessageA
    while (len > 0 && (buffer[len - 1] == '\r' || buffer[len - 1] == '\n')) {
        buffer[--len] = '\0';
    }

    snprintf(
        luneffi_last_error,
        sizeof(luneffi_last_error),
        "%s: %s",
        context,
        buffer
    );
}

void* luneffi_dlopen(const char* path) {
    luneffi_set_error(NULL);
    HMODULE handle;
    if (path == NULL || path[0] == '\0') {
        handle = GetModuleHandleA(NULL);
        if (handle == NULL) {
            luneffi_capture_last_error("GetModuleHandleA(NULL)");
        }
        return handle;
    }

    handle = LoadLibraryA(path);
    if (handle == NULL) {
        luneffi_capture_last_error("LoadLibraryA failed");
    }
    return handle;
}

void* luneffi_dlsym(void* handle, const char* name) {
    luneffi_set_error(NULL);
    HMODULE module = (HMODULE)handle;
    if (module == NULL) {
        module = GetModuleHandleA(NULL);
        if (module == NULL) {
            luneffi_capture_last_error("GetModuleHandleA(NULL)");
            return NULL;
        }
    }
    FARPROC proc = GetProcAddress(module, name);
    if (proc == NULL) {
        luneffi_capture_last_error("GetProcAddress failed");
    }
    return (void*)proc;
}

int luneffi_dlclose(void* handle) {
    luneffi_set_error(NULL);
    if (handle == NULL) {
        // Do not attempt to free the process handle
        return 0;
    }
    HMODULE module = (HMODULE)handle;
    if (module == GetModuleHandleA(NULL)) {
        // Never free the main module handle
        return 0;
    }
    BOOL ok = FreeLibrary(module);
    if (!ok) {
        luneffi_capture_last_error("FreeLibrary failed");
        return -1;
    }
    return 0;
}

const char* luneffi_dlerror(void) {
    if (luneffi_last_error[0] == '\0') {
        return NULL;
    }
    return luneffi_last_error;
}
