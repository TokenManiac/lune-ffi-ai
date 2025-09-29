local ffi = require("@lune/ffi")

ffi.cdef([[double cos(double);]])

local libm = if ffi.os == "Windows" then ffi.C else ffi.load("m")
print("cos(0.5)", libm.cos(0.5))
