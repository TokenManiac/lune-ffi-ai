# @lune/ffi

Luau Foreign Function Interface inspired by LuaJIT's excellent FFI while remaining idiomatic to the Lune ecosystem.

> **Status:** Work in progress. See `PROGRESS.md` for the full roadmap.

## Quickstart

```luau
local ffi = require("@lune/ffi")

ffi.cdef([[int puts(const char*);]])

local message = "Hello from native code!"
local rc = ffi.C.puts(message)
print("puts returned", rc)

local value = ffi.new("int", 42)
print("allocated", value)

print("Current errno", ffi.errno())
print("Platform", ffi.os, ffi.arch)
```

Run the Luau spec suite (this compiles the native shims and executes
`packages/ffi/tests/_runner.luau` under the embedded interpreter):

```bash
cargo test -p lune-std-ffi -- --nocapture
```

Additional micro-examples live under [`packages/ffi/examples`](./examples).

## Examples

The snippets below mirror the scripts in `packages/ffi/examples`.

### `printf` with varargs

```luau
local ffi = require("@lune/ffi")

ffi.cdef([[int printf(const char* fmt, ...);]])

ffi.C.printf("[ffi] %s %d\\n", "answer", 42)
print("errno after printf", ffi.errno())
```

### Math library bindings

```luau
local ffi = require("@lune/ffi")

ffi.cdef([[double cos(double);]])

local libm = if ffi.os == "Windows" then ffi.C else ffi.load("m")
print("cos(0.5) =", libm.cos(0.5))
```

### Custom shared library + callbacks

Build the sample library first (from `packages/ffi/examples/native`):

```bash
# Linux
cc -fPIC -shared native/example.c -o libexample.so

# macOS
cc -dynamiclib native/example.c -o libexample.dylib

# Windows (MSVC)
cl /LD native/example.c /Fe:example.dll
```

Then run:

```luau
local ffi = require("@lune/ffi")

ffi.cdef([[typedef int (*ExampleCallback)(int);

int example_add_ints(int a, int b);
const char* example_greeting(void);
void example_invoke(ExampleCallback cb, int value);
]])

local path = if ffi.os == "Windows"
    then "./example.dll"
    elseif ffi.os == "OSX" then "./libexample.dylib"
    else "./libexample.so"
local lib = ffi.load(path)

print("example_add_ints:", lib.example_add_ints(7, 5))

local greeting = ffi.string(lib.example_greeting())
print("Greeting from C:", greeting)

local callbackType = ffi.typeof("ExampleCallback")
local total = 0
local cb = ffi.cast(callbackType, function(value)
    total += value
    return total
end)

lib.example_invoke(cb, 9)
print("Callback invoked", total, "time(s)")
```

> **Tip:** Run the script from `packages/ffi/examples` so the relative paths
> resolve to the compiled shared library.

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
| `ffi.errno` | ✅ | Thread-local errno getter/setter backed by platform CRT. |
| Call bridge | ⚠️ | LibFFI-backed; structured returns/varargs extensions tracked separately. |

## Testing & Development

- Specs live under `packages/ffi/tests`. The `_runner.luau` harness discovers and executes the suite.
- Native shims are located in `packages/ffi/native` and compiled as part of the Rust crate `lune-std-ffi`.
- Use `cargo fmt` and `stylua` to keep Rust and Luau code formatted.
- The GitHub Actions workflow (`ci.yaml`) builds and tests on macOS, Linux, and Windows across x64 and arm64 targets.

