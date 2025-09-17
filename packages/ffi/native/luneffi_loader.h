#ifndef LUNEFFI_LOADER_H
#define LUNEFFI_LOADER_H

#ifdef __cplusplus
extern "C" {
#endif

void* luneffi_dlopen(const char* path);
void* luneffi_dlsym(void* handle, const char* name);
int luneffi_dlclose(void* handle);
const char* luneffi_dlerror(void);

#ifdef __cplusplus
}
#endif

#endif /* LUNEFFI_LOADER_H */
