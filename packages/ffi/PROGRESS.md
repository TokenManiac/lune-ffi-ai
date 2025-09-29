# @lune/ffi Progress

- [x] Create `@lune/ffi` package scaffolding (src, tests, examples, docs, CI)
- [x] Implement loader native shim (POSIX/Windows) + Luau wrapper
- [x] Implement call bridge (cdecl + Windows stdcall/ms_abi), basic varargs *(TODO: richer cdata varargs + parser integration)*
- [x] `ffi.cdef` parser (typedefs, enums, structs/unions, bitfields basic) *(arrays/nested declarators still TODO)*
- [x] `ffi.new`, `ffi.typeof`, `ffi.cast`, `ffi.string`
- [x] `ffi.sizeof`, `ffi.alignof`, `ffi.offsetof`
- [x] `ffi.C`, `ffi.load`, symbol cache
- [x] `ffi.metatype`, `ffi.gc`
- [x] `ffi.abi`, `ffi.os`, `ffi.arch`
- [x] Callback trampolines (Luau → C function pointers) + GC safety *(basic unary callbacks, TODO: expand coverage)*
- [ ] Error/errno handling
- [x] Unit & integration tests (incl. tiny C test lib built in CI) *(runtime spec executed via Rust harness)*
- [ ] Examples & README
- [ ] CI across macOS/Windows/Linux
- [ ] Compatibility matrix vs LuaJIT FFI (✅/⚠️/⏳)
- [ ] Before completing the project, explore the project hierarchy, find out missing pieces & oversights.
- [ ] Make sure the project runs safely, with minimal (ideally none) exploits causing RCE / ACE unless the user makes a mistake on their end.
