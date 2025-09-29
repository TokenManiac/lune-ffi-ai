local ffi = require("@lune/ffi")

ffi.cdef([[int puts(const char*);]])

local message = "Hello from @lune/ffi!"
local written = ffi.C.puts(message)
print("puts returned", written)
print("errno", ffi.errno())
