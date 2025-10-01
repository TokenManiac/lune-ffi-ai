use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::ptr;
use std::slice;

use mlua::prelude::*;

use crate::call;
use crate::callback;
use crate::types::{self, TypeCode};

type TestCallback = unsafe extern "C" fn(c_int) -> c_int;

#[allow(dead_code)]
unsafe extern "C" {
    fn luneffi_test_call_callback(cb: Option<TestCallback>, value: c_int) -> c_int;
}

#[used]
#[allow(dead_code)]
static LUNEFFI_KEEP_TEST_CALLBACK: unsafe extern "C" fn(Option<TestCallback>, c_int) -> c_int =
    luneffi_test_call_callback;

use libc::{calloc, free, memcpy, size_t};

cfg_if::cfg_if! {
    if #[cfg(any(
        target_os = "netbsd",
        target_os = "openbsd",
        target_os = "android",
        target_os = "cygwin",
    ))] {
        #[inline]
        fn errno_location() -> *mut c_int {
            unsafe { libc::__errno() }
        }
    } else if #[cfg(any(
        target_os = "linux",
        target_os = "emscripten",
        target_os = "hurd",
        target_os = "redox",
        target_os = "dragonfly",
    ))] {
        #[inline]
        fn errno_location() -> *mut c_int {
            unsafe { libc::__errno_location() }
        }
    } else if #[cfg(any(target_os = "solaris", target_os = "illumos"))] {
        #[inline]
        fn errno_location() -> *mut c_int {
            unsafe { libc::___errno() }
        }
    } else if #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))] {
        #[inline]
        fn errno_location() -> *mut c_int {
            unsafe { libc::__error() }
        }
    } else if #[cfg(target_os = "haiku")] {
        #[inline]
        fn errno_location() -> *mut c_int {
            unsafe { libc::_errnop() }
        }
    } else if #[cfg(target_os = "nto")] {
        #[inline]
        fn errno_location() -> *mut c_int {
            unsafe { libc::__get_errno_ptr() }
        }
    } else if #[cfg(any(
        all(target_os = "horizon", target_arch = "arm"),
        target_os = "vita",
    ))] {
        extern "C" {
            fn __errno() -> *mut c_int;
        }

        #[inline]
        fn errno_location() -> *mut c_int {
            unsafe { __errno() }
        }
    } else if #[cfg(target_os = "aix")] {
        #[inline]
        fn errno_location() -> *mut c_int {
            unsafe { libc::_Errno() }
        }
    } else if #[cfg(windows)] {
        #[inline]
        fn errno_location() -> *mut c_int {
            unsafe { libc::_errno() }
        }
    } else {
        compile_error!("Unsupported platform: no errno accessor available for lune-std-ffi");
    }
}

#[inline]
fn get_errno() -> c_int {
    unsafe { *errno_location() }
}

#[inline]
fn set_errno(value: c_int) {
    unsafe {
        *errno_location() = value;
    }
}

#[allow(improper_ctypes)]
unsafe extern "C" {
    fn luneffi_dlopen(path: *const c_char) -> *mut c_void;
    fn luneffi_dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    fn luneffi_dlclose(handle: *mut c_void) -> c_int;
    fn luneffi_dlerror() -> *const c_char;
}

fn last_error() -> Option<String> {
    let ptr = unsafe { luneffi_dlerror() };
    if ptr.is_null() {
        return None;
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    Some(c_str.to_string_lossy().into_owned())
}

fn detect_os() -> &'static str {
    if cfg!(target_os = "windows") {
        "Windows"
    } else if cfg!(target_os = "macos") {
        "OSX"
    } else if cfg!(target_os = "ios") {
        "iOS"
    } else if cfg!(target_os = "linux") || cfg!(target_os = "android") {
        "Linux"
    } else if cfg!(any(
        target_os = "freebsd",
        target_os = "openbsd",
        target_os = "netbsd",
        target_os = "dragonfly",
    )) {
        "BSD"
    } else if cfg!(target_os = "solaris") {
        "Solaris"
    } else {
        "Other"
    }
}

fn detect_arch() -> &'static str {
    if cfg!(target_arch = "x86_64") {
        "x64"
    } else if cfg!(target_arch = "x86") {
        "x86"
    } else if cfg!(target_arch = "aarch64") {
        "arm64"
    } else if cfg!(target_arch = "arm") {
        "arm"
    } else if cfg!(target_arch = "powerpc64") {
        "ppc64"
    } else if cfg!(target_arch = "powerpc") {
        "ppc"
    } else if cfg!(target_arch = "mips64") {
        "mips64"
    } else if cfg!(target_arch = "mips") {
        "mips"
    } else if cfg!(target_arch = "riscv64") {
        "riscv64"
    } else if cfg!(target_arch = "s390x") {
        "s390x"
    } else {
        "other"
    }
}

fn build_abi_info(lua: &Lua) -> LuaResult<LuaTable> {
    let table = lua.create_table()?;

    table.set("32bit", cfg!(target_pointer_width = "32"))?;
    table.set("64bit", cfg!(target_pointer_width = "64"))?;
    table.set("le", cfg!(target_endian = "little"))?;
    table.set("be", cfg!(target_endian = "big"))?;

    let hardfp = cfg!(any(
        target_arch = "x86",
        target_arch = "x86_64",
        target_arch = "aarch64",
        target_arch = "powerpc",
        target_arch = "powerpc64",
        target_arch = "mips",
        target_arch = "mips64",
        target_arch = "riscv32",
        target_arch = "riscv64",
    ));
    let softfp = cfg!(target_arch = "arm");
    let fpu = hardfp || softfp;

    table.set("fpu", fpu)?;
    table.set("softfp", softfp)?;
    table.set("hardfp", hardfp)?;
    table.set("win", cfg!(target_os = "windows"))?;
    table.set(
        "bsd",
        cfg!(any(
            target_os = "freebsd",
            target_os = "openbsd",
            target_os = "netbsd",
            target_os = "dragonfly",
        )),
    )?;
    table.set(
        "elf",
        cfg!(any(
            target_os = "linux",
            target_os = "android",
            target_os = "freebsd",
            target_os = "openbsd",
            target_os = "netbsd",
            target_os = "dragonfly",
        )),
    )?;

    Ok(table)
}

fn build_primitive_layout(lua: &Lua) -> LuaResult<LuaTable> {
    let layout = lua.create_table()?;
    const CODES: &[&str] = &[
        "void",
        "int8",
        "uint8",
        "int16",
        "uint16",
        "int",
        "unsigned int",
        "long",
        "unsigned long",
        "long long",
        "unsigned long long",
        "size_t",
        "ssize_t",
        "intptr_t",
        "uintptr_t",
        "ptrdiff_t",
        "float",
        "double",
        "pointer",
    ];

    for code in CODES {
        let normalized = types::normalize_code(code);
        let ty = TypeCode::from_code(&normalized)?;

        let size = ty.size_of();
        let align = ty.align_of();

        let entry = lua.create_table()?;
        entry.set(
            "size",
            i64::try_from(size).map_err(|_| {
                LuaError::runtime(format!(
                    "primitive '{code}' size does not fit in Lua integer"
                ))
            })?,
        )?;
        entry.set(
            "align",
            i64::try_from(align).map_err(|_| {
                LuaError::runtime(format!(
                    "primitive '{code}' align does not fit in Lua integer"
                ))
            })?,
        )?;
        layout.set(*code, entry)?;
    }

    Ok(layout)
}

fn lua_value_to_pointer(value: &LuaValue) -> LuaResult<*mut c_void> {
    match value {
        LuaValue::Nil => Ok(ptr::null_mut()),
        LuaValue::LightUserData(ptr) => Ok(ptr.0),
        LuaValue::Integer(i) => {
            if *i < 0 {
                return Err(LuaError::runtime(
                    "pointer value must be non-negative".to_string(),
                ));
            }
            Ok((*i as u64) as usize as *mut c_void)
        }
        LuaValue::Number(n) => {
            if !n.is_finite() {
                return Err(LuaError::runtime(
                    "pointer value must be finite".to_string(),
                ));
            }
            if *n < 0.0 {
                return Err(LuaError::runtime(
                    "pointer value must be non-negative".to_string(),
                ));
            }
            if (n.trunc() - n).abs() > f64::EPSILON {
                return Err(LuaError::runtime(
                    "pointer value must be integral".to_string(),
                ));
            }
            Ok((*n as u64) as usize as *mut c_void)
        }
        LuaValue::Table(table) => {
            let marker = table.raw_get::<LuaValue>("__ffi_cdata")?;
            if !matches!(marker, LuaValue::Boolean(true)) {
                return Err(LuaError::runtime(
                    "cannot convert table value to native pointer".to_string(),
                ));
            }
            let inner = table.raw_get::<LuaValue>("__ptr")?;
            match inner {
                LuaValue::LightUserData(ptr) => Ok(ptr.0),
                LuaValue::Nil => Ok(ptr::null_mut()),
                other => Err(LuaError::runtime(format!(
                    "cdata object missing native pointer (found {other:?})",
                ))),
            }
        }
        other => Err(LuaError::runtime(format!(
            "cannot convert value {other:?} to native pointer"
        ))),
    }
}

fn store_scalar(ptr: *mut c_void, ty: TypeCode, value: &LuaValue) -> LuaResult<()> {
    unsafe {
        match ty {
            TypeCode::Void => {
                return Err(LuaError::runtime(
                    "cannot store value for 'void' type".to_string(),
                ));
            }
            TypeCode::Int8 => {
                let v = types::clamp_signed(types::lua_value_to_i64(value)?, 8)? as i8;
                ptr::write(ptr as *mut i8, v);
            }
            TypeCode::UInt8 => {
                let v = types::clamp_unsigned(types::lua_value_to_u64(value)?, 8)? as u8;
                ptr::write(ptr as *mut u8, v);
            }
            TypeCode::Int16 => {
                let v = types::clamp_signed(types::lua_value_to_i64(value)?, 16)? as i16;
                ptr::write(ptr as *mut i16, v);
            }
            TypeCode::UInt16 => {
                let v = types::clamp_unsigned(types::lua_value_to_u64(value)?, 16)? as u16;
                ptr::write(ptr as *mut u16, v);
            }
            TypeCode::Int32 => {
                let v = types::clamp_signed(types::lua_value_to_i64(value)?, 32)? as i32;
                ptr::write(ptr as *mut i32, v);
            }
            TypeCode::UInt32 => {
                let v = types::clamp_unsigned(types::lua_value_to_u64(value)?, 32)? as u32;
                ptr::write(ptr as *mut u32, v);
            }
            TypeCode::Int64 => {
                let v = types::lua_value_to_i64(value)?;
                ptr::write(ptr as *mut i64, v);
            }
            TypeCode::UInt64 => {
                let v = types::lua_value_to_u64(value)?;
                ptr::write(ptr as *mut u64, v);
            }
            TypeCode::IntPtr => {
                let bits = usize::BITS;
                let value = types::clamp_signed(types::lua_value_to_i64(value)?, bits)?;
                if bits == 64 {
                    ptr::write(ptr as *mut i64, value);
                } else {
                    ptr::write(ptr as *mut i32, value as i32);
                }
            }
            TypeCode::UIntPtr => {
                let bits = usize::BITS;
                let value = types::clamp_unsigned(types::lua_value_to_u64(value)?, bits)?;
                if bits == 64 {
                    ptr::write(ptr as *mut u64, value);
                } else {
                    ptr::write(ptr as *mut u32, value as u32);
                }
            }
            TypeCode::Float32 => {
                let v = match value {
                    LuaValue::Number(n) => *n as f32,
                    LuaValue::Integer(i) => *i as f32,
                    LuaValue::Boolean(b) => {
                        if *b {
                            1.0
                        } else {
                            0.0
                        }
                    }
                    other => {
                        return Err(LuaError::runtime(format!(
                            "expected numeric value for float storage, got {other:?}"
                        )));
                    }
                };
                ptr::write(ptr as *mut f32, v);
            }
            TypeCode::Float64 => {
                let v = match value {
                    LuaValue::Number(n) => *n,
                    LuaValue::Integer(i) => *i as f64,
                    LuaValue::Boolean(b) => {
                        if *b {
                            1.0
                        } else {
                            0.0
                        }
                    }
                    other => {
                        return Err(LuaError::runtime(format!(
                            "expected numeric value for double storage, got {other:?}"
                        )));
                    }
                };
                ptr::write(ptr as *mut f64, v);
            }
            TypeCode::Pointer => {
                let p = lua_value_to_pointer(value)?;
                ptr::write(ptr as *mut *mut c_void, p);
            }
        }
    }

    Ok(())
}

fn load_scalar(_lua: &Lua, ptr: *mut c_void, ty: TypeCode) -> LuaResult<LuaValue> {
    unsafe {
        match ty {
            TypeCode::Void => Err(LuaError::runtime(
                "cannot read value of 'void' type".to_string(),
            )),
            TypeCode::Int8 => Ok(LuaValue::Integer(ptr::read(ptr as *const i8) as i64)),
            TypeCode::UInt8 => Ok(LuaValue::Integer(ptr::read(ptr as *const u8) as i64)),
            TypeCode::Int16 => Ok(LuaValue::Integer(ptr::read(ptr as *const i16) as i64)),
            TypeCode::UInt16 => Ok(LuaValue::Integer(ptr::read(ptr as *const u16) as i64)),
            TypeCode::Int32 => Ok(LuaValue::Integer(ptr::read(ptr as *const i32) as i64)),
            TypeCode::UInt32 => Ok(LuaValue::Integer(ptr::read(ptr as *const u32) as i64)),
            TypeCode::Int64 => Ok(LuaValue::Integer(ptr::read(ptr as *const i64))),
            TypeCode::UInt64 => {
                let value = ptr::read(ptr as *const u64);
                if value <= i64::MAX as u64 {
                    Ok(LuaValue::Integer(value as i64))
                } else {
                    Ok(LuaValue::Number(value as f64))
                }
            }
            TypeCode::IntPtr => {
                if usize::BITS == 64 {
                    Ok(LuaValue::Integer(ptr::read(ptr as *const i64)))
                } else {
                    Ok(LuaValue::Integer(ptr::read(ptr as *const i32) as i64))
                }
            }
            TypeCode::UIntPtr => {
                if usize::BITS == 64 {
                    let value = ptr::read(ptr as *const u64);
                    if value <= i64::MAX as u64 {
                        Ok(LuaValue::Integer(value as i64))
                    } else {
                        Ok(LuaValue::Number(value as f64))
                    }
                } else {
                    Ok(LuaValue::Integer(ptr::read(ptr as *const u32) as i64))
                }
            }
            TypeCode::Float32 => Ok(LuaValue::Number(ptr::read(ptr as *const f32) as f64)),
            TypeCode::Float64 => Ok(LuaValue::Number(ptr::read(ptr as *const f64))),
            TypeCode::Pointer => {
                let value = ptr::read(ptr as *const *mut c_void);
                Ok(LuaValue::LightUserData(LuaLightUserData(value)))
            }
        }
    }
}

pub fn create(lua: &Lua) -> LuaResult<LuaTable> {
    let table = lua.create_table()?;

    let pointer_size = std::mem::size_of::<*mut c_void>();
    table.set(
        "pointerSize",
        i64::try_from(pointer_size).map_err(|_| {
            LuaError::runtime("pointer size does not fit in Lua integer".to_string())
        })?,
    )?;

    let pointer_align = std::mem::align_of::<*mut c_void>();
    table.set(
        "pointerAlign",
        i64::try_from(pointer_align).map_err(|_| {
            LuaError::runtime("pointer alignment does not fit in Lua integer".to_string())
        })?,
    )?;

    let primitive_layout = build_primitive_layout(lua)?;
    table.set("primitiveLayout", primitive_layout)?;

    let os_string = lua.create_string(detect_os())?;
    table.set("platformOS", os_string)?;

    let arch_string = lua.create_string(detect_arch())?;
    table.set("platformArch", arch_string)?;

    let abi_info = build_abi_info(lua)?;
    table.set("abiInfo", abi_info)?;

    let dlopen_fn = lua.create_function(|_, path: Option<String>| {
        let c_path =
            match path {
                Some(ref p) => Some(CString::new(p.as_str()).map_err(|_| {
                    LuaError::runtime(format!("Library path contains NUL byte: {p}"))
                })?),
                None => None,
            };

        let ptr =
            unsafe { luneffi_dlopen(c_path.as_ref().map_or(std::ptr::null(), |s| s.as_ptr())) };

        if ptr.is_null() {
            let err = last_error().unwrap_or_else(|| "Failed to load library".to_string());
            return Err(LuaError::runtime(err));
        }

        Ok(LuaLightUserData(ptr))
    })?;
    table.set("dlopen", dlopen_fn)?;

    let dlsym_fn = lua.create_function(|lua, (handle, name): (LuaLightUserData, String)| {
        let c_name = CString::new(name.as_str())
            .map_err(|_| LuaError::runtime(format!("Symbol name contains NUL byte: {name}")))?;
        let ptr = unsafe { luneffi_dlsym(handle.0, c_name.as_ptr()) };
        if ptr.is_null() {
            let err = last_error().unwrap_or_else(|| "symbol lookup failed".to_string());
            let err_value = LuaValue::String(lua.create_string(err)?);
            Ok(LuaMultiValue::from_vec(vec![LuaValue::Nil, err_value]))
        } else {
            let symbol = LuaValue::LightUserData(LuaLightUserData(ptr));
            Ok(LuaMultiValue::from_vec(vec![symbol]))
        }
    })?;
    table.set("dlsym", dlsym_fn)?;

    let dlclose_fn = lua.create_function(|_, handle: LuaLightUserData| {
        let rc = unsafe { luneffi_dlclose(handle.0) };
        if rc != 0 {
            let err = last_error().unwrap_or_else(|| "dlclose failed".to_string());
            return Err(LuaError::runtime(err));
        }
        Ok(())
    })?;
    table.set("dlclose", dlclose_fn)?;

    let errno_get_fn = lua.create_function(|_, ()| Ok(i64::from(get_errno())))?;
    table.set("getErrno", errno_get_fn)?;

    let errno_set_fn = lua.create_function(|_, value: LuaValue| {
        let coerced = types::lua_value_to_i64(&value)?;
        if coerced < c_int::MIN as i64 || coerced > c_int::MAX as i64 {
            return Err(LuaError::runtime(
                "errno value out of range for C int".to_string(),
            ));
        }
        set_errno(coerced as c_int);
        Ok(())
    })?;
    table.set("setErrno", errno_set_fn)?;

    let alloc_fn = lua.create_function(|_, size: u64| {
        let bytes = usize::try_from(size)
            .map_err(|_| LuaError::runtime("allocation size does not fit usize".to_string()))?;
        let ptr = unsafe { calloc(1, bytes as size_t) };
        if ptr.is_null() && bytes > 0 {
            return Err(LuaError::runtime(format!(
                "failed to allocate {bytes} byte(s)"
            )));
        }
        Ok(LuaLightUserData(ptr))
    })?;
    table.set("alloc", alloc_fn)?;

    let free_fn = lua.create_function(|_, ptr_value: LuaLightUserData| {
        unsafe {
            if !ptr_value.0.is_null() {
                free(ptr_value.0);
            }
        }
        Ok(())
    })?;
    table.set("free", free_fn)?;

    let store_fn = lua.create_function(
        |_, (ptr_value, code, value): (LuaLightUserData, String, LuaValue)| {
            let normalized = types::normalize_code(&code);
            let ty = TypeCode::from_code(&normalized)?;
            store_scalar(ptr_value.0, ty, &value)?;
            Ok(())
        },
    )?;
    table.set("storeScalar", store_fn)?;

    let load_fn = lua.create_function(|lua, (ptr_value, code): (LuaLightUserData, String)| {
        let normalized = types::normalize_code(&code);
        let ty = TypeCode::from_code(&normalized)?;
        load_scalar(lua, ptr_value.0, ty)
    })?;
    table.set("loadScalar", load_fn)?;

    let read_string_fn =
        lua.create_function(|lua, (ptr_value, len): (LuaLightUserData, Option<u64>)| {
            if ptr_value.0.is_null() {
                return Err(LuaError::runtime(
                    "attempt to read string from null pointer".to_string(),
                ));
            }

            let bytes = match len {
                Some(count) => {
                    let count = usize::try_from(count).map_err(|_| {
                        LuaError::runtime("string length does not fit usize".to_string())
                    })?;
                    unsafe { slice::from_raw_parts(ptr_value.0 as *const u8, count) }
                }
                None => unsafe { CStr::from_ptr(ptr_value.0 as *const c_char).to_bytes() },
            };

            let lua_string = lua.create_string(bytes)?;
            Ok(LuaValue::String(lua_string))
        })?;
    table.set("readString", read_string_fn)?;

    let write_bytes_fn = lua.create_function(
        |_, (dest, data, append_null): (LuaLightUserData, LuaString, Option<bool>)| {
            if dest.0.is_null() {
                return Err(LuaError::runtime(
                    "attempt to write to null pointer".to_string(),
                ));
            }

            let bytes = data.as_bytes();
            let length = bytes.len();

            unsafe {
                memcpy(dest.0, bytes.as_ptr() as *const c_void, length as size_t);

                if append_null.unwrap_or(false) {
                    let end = (dest.0 as *mut u8).add(length);
                    ptr::write(end, 0u8);
                }
            }

            Ok(())
        },
    )?;
    table.set("writeBytes", write_bytes_fn)?;

    let call_fn = lua.create_function(
        |lua, (func, signature, args): (LuaLightUserData, LuaTable, LuaTable)| {
            call::call(lua, func, signature, args)
        },
    )?;
    table.set("call", call_fn)?;

    callback::register(lua, &table)?;

    Ok(table)
}
