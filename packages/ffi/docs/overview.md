# @lune/ffi Overview

`@lune/ffi` exposes a LuaJIT-inspired foreign function interface for Luau.
The implementation combines a thin native shim (for dynamic loading, errno
bridges, and libffi calls) with a pure-Luau type system, parser, and runtime.

Key entry points are documented in the [package README](../README.md). The
highlights:

- `ffi.cdef` parses C99 declarations (typedefs, enums, structs/unions, and
  function prototypes) into reusable ctype descriptors.
- `ffi.C` gives access to process exports while `ffi.load` handles user
  libraries (with automatic `dlclose` when garbage-collected).
- `ffi.new`, `ffi.typeof`, `ffi.cast`, and `ffi.string` create and manipulate
  cdata objects representing primitive scalars and pointers.
- `ffi.errno()` reads or overrides the thread-local `errno` value.
- `ffi.metatype`, `ffi.gc`, and callback support tie the lifetime of native
  resources to Luau objects safely.

See `packages/ffi/examples/` for runnable snippets and
`packages/ffi/tests/` for the specification suite that exercises the
feature surface. Remaining TODOs and caveats are tracked in
[`PROGRESS.md`](../PROGRESS.md).
