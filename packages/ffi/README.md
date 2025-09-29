# @lune/ffi

> Work in progress Luau FFI inspired by LuaJIT.

## Status

This package is under active development. See `PROGRESS.md` for the project checklist.

## Current Capabilities

- `ffi.cdef` can register C function prototypes, typedef aliases, and basic struct/union/enum definitions (arrays and advanced declarators are still TODO).
- A lightweight Luau test harness lives under `packages/ffi/tests/_runner.luau` and can be executed with `cargo run -p lune -- run packages/ffi/tests/_runner.luau`.

