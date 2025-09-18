# @lune/ffi Progress

- [x] Create `@lune/ffi` package scaffolding (src, tests, examples, docs, CI)
- [x] Implement loader native shim (POSIX/Windows) + Luau wrapper
- [ ] Implement call bridge (cdecl + Windows stdcall/ms_abi), basic varargs *(in progress: native call trampoline + debug invocation helpers; TODO varargs + integration with parser)*
- [ ] `ffi.cdef` parser (typedefs, enums, structs/unions, bitfields basic)
- [ ] `ffi.new`, `ffi.typeof`, `ffi.cast`, `ffi.string`
- [ ] `ffi.sizeof`, `ffi.alignof`, `ffi.offsetof`
- [ ] `ffi.C`, `ffi.load`, symbol cache
- [ ] `ffi.metatype`, `ffi.gc`
- [ ] `ffi.abi`, `ffi.os`, `ffi.arch`
- [ ] Callback trampolines (Luau → C function pointers) + GC safety
- [ ] Error/errno handling
- [ ] Unit & integration tests (incl. tiny C test lib built in CI)
- [ ] Examples & README
- [ ] CI across macOS/Windows/Linux
- [ ] Compatibility matrix vs LuaJIT FFI (✅/⚠️/⏳)
- [ ] Before completing the project, explore the project hierarchy, find out missing pieces & oversights.
- [ ] Make sure the project runs safely, with minimal (ideally none) exploits causing RCE / ACE unless the user makes a mistake on their end.
