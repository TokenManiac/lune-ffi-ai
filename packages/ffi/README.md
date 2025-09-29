# @lune/ffi

Luau Foreign Function Interface inspired by LuaJIT's excellent FFI while remaining idiomatic to the Lune ecosystem.

> **Status:** Work in progress. See `PROGRESS.md` for the full roadmap.

## Quickstart

```luau
local ffi = require("@lune/ffi")

local counter = 0
local value = ffi.new("int", 1337)
ffi.gc(value, function()
    counter += 1
end)

local intPtr = ffi.metatype("int*", {
    __tostring = function(self)
        local raw = rawget(self, "__ptr")
        return raw and ("int*" .. tostring(raw)) or "int*<null>"
    end,
})

local ptr = ffi.cast(intPtr, value)
print(tostring(ptr))
print("Platform", ffi.os, ffi.arch)
```

Run the local spec suite:

```bash
cargo run -p lune -- run packages/ffi/tests/_runner.luau
```

## Compatibility Snapshot

| Feature | Status | Notes |
| --- | --- | --- |
| `ffi.cdef` | ⚠️ | Typedefs, enums, structs/unions, function prototypes supported (arrays/nested declarators pending). |
| `ffi.C` / `ffi.load` | ✅ | Process handle exposed; named libraries cached with automatic `dlclose` on GC. |
| `ffi.new` / `ffi.cast` / `ffi.typeof` | ⚠️ | Primitives and pointers supported; structured allocations are TODO. |
| `ffi.gc` | ✅ | Finalizers on cdata tables; lightuserdata support TODO. |
| `ffi.metatype` | ⚠️ | Metamethods for pointers/records cached; field access helpers forthcoming. |
| `ffi.string` | ✅ | Reads NUL-terminated or length-bounded buffers. |
| `ffi.sizeof` / `ffi.alignof` / `ffi.offsetof` | ✅ | Matches platform primitives; complex bitfield offsets still TODO. |
| `ffi.abi` / `ffi.os` / `ffi.arch` | ✅ | Normalised strings/flags mirroring LuaJIT identifiers. |
| Call bridge | ⚠️ | LibFFI-backed; structured returns/varargs extensions tracked separately. |

## Testing & Development

- Specs live under `packages/ffi/tests`. The `_runner.luau` harness discovers and executes the suite.
- Native shims are located in `packages/ffi/native` and compiled as part of the Rust crate `lune-std-ffi`.
- Use `cargo fmt` and `stylua` to keep Rust and Luau code formatted.

