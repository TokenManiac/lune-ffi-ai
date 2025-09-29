local ffi = require("@lune/ffi")

ffi.cdef([[int printf(const char* fmt, ...);]])

ffi.C.printf("[printf example] %s %d\\n", "count", 3)
print("errno after printf", ffi.errno())
