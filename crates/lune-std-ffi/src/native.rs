use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};

use mlua::prelude::*;

use crate::call;

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

pub fn create(lua: &Lua) -> LuaResult<LuaTable> {
    let table = lua.create_table()?;

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

    let call_fn = lua.create_function(
        |lua, (func, signature, args): (LuaLightUserData, LuaTable, LuaTable)| {
            call::call(lua, func, signature, args)
        },
    )?;
    table.set("call", call_fn)?;

    Ok(table)
}
