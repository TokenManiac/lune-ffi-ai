use std::ffi::c_void;
use std::ptr;

use libffi::middle::Closure;
use mlua::RegistryKey;
use mlua::prelude::*;

use crate::signature::{CType, Signature};
use crate::types::{self, TypeCode};

const CALLBACK_RESULT_SIZE: usize = 16;

struct CallbackData {
    lua: Lua,
    function_key: Option<RegistryKey>,
    signature: Signature,
}

impl CallbackData {
    fn new(lua: Lua, signature: Signature, function_key: RegistryKey) -> Self {
        Self {
            lua,
            function_key: Some(function_key),
            signature,
        }
    }

    fn signature(&self) -> &Signature {
        &self.signature
    }

    fn get_function(&self) -> LuaResult<LuaFunction> {
        let key = self
            .function_key
            .as_ref()
            .ok_or_else(|| LuaError::runtime("callback function has been released".to_string()))?;
        self.lua.registry_value(key)
    }

    fn read_argument(
        &self,
        args: *const *const c_void,
        index: usize,
        ty: &CType,
    ) -> LuaResult<LuaValue> {
        unsafe {
            let arg_ptr = *args.add(index);
            match ty.code() {
                TypeCode::Void => Err(LuaError::runtime(
                    "void type cannot be used as a callback argument".to_string(),
                )),
                TypeCode::Int8 => Ok(LuaValue::Integer(*(arg_ptr as *const i8) as i64)),
                TypeCode::UInt8 => Ok(LuaValue::Integer(*(arg_ptr as *const u8) as i64)),
                TypeCode::Int16 => Ok(LuaValue::Integer(*(arg_ptr as *const i16) as i64)),
                TypeCode::UInt16 => Ok(LuaValue::Integer(*(arg_ptr as *const u16) as i64)),
                TypeCode::Int32 => Ok(LuaValue::Integer(*(arg_ptr as *const i32) as i64)),
                TypeCode::UInt32 => Ok(LuaValue::Integer(*(arg_ptr as *const u32) as i64)),
                TypeCode::Int64 => Ok(LuaValue::Integer(*(arg_ptr as *const i64))),
                TypeCode::UInt64 => {
                    let value = *(arg_ptr as *const u64);
                    if value <= i64::MAX as u64 {
                        Ok(LuaValue::Integer(value as i64))
                    } else {
                        Ok(LuaValue::Number(value as f64))
                    }
                }
                TypeCode::IntPtr => {
                    if usize::BITS == 64 {
                        Ok(LuaValue::Integer(*(arg_ptr as *const i64)))
                    } else {
                        Ok(LuaValue::Integer(*(arg_ptr as *const i32) as i64))
                    }
                }
                TypeCode::UIntPtr => {
                    if usize::BITS == 64 {
                        let value = *(arg_ptr as *const u64);
                        if value <= i64::MAX as u64 {
                            Ok(LuaValue::Integer(value as i64))
                        } else {
                            Ok(LuaValue::Number(value as f64))
                        }
                    } else {
                        Ok(LuaValue::Integer(*(arg_ptr as *const u32) as i64))
                    }
                }
                TypeCode::Float32 => Ok(LuaValue::Number(*(arg_ptr as *const f32) as f64)),
                TypeCode::Float64 => Ok(LuaValue::Number(*(arg_ptr as *const f64))),
                TypeCode::Pointer => {
                    let value = *(arg_ptr as *const *mut c_void);
                    if value.is_null() {
                        Ok(LuaValue::Nil)
                    } else {
                        Ok(LuaValue::LightUserData(LuaLightUserData(value)))
                    }
                }
            }
        }
    }

    fn pointer_from_value(&self, value: &LuaValue) -> LuaResult<*mut c_void> {
        match value {
            LuaValue::Nil => Ok(ptr::null_mut()),
            LuaValue::LightUserData(ptr) => Ok(ptr.0),
            LuaValue::Boolean(false) => Ok(ptr::null_mut()),
            LuaValue::Boolean(true) => Err(LuaError::runtime(
                "cannot convert boolean 'true' to pointer".to_string(),
            )),
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
                        "cannot convert table value to pointer".to_string(),
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
                "cannot convert value {other:?} to pointer",
            ))),
        }
    }

    fn write_result(
        &self,
        buffer: &mut [u8; CALLBACK_RESULT_SIZE],
        value: LuaValue,
    ) -> LuaResult<()> {
        buffer.fill(0);
        match self.signature().result().code() {
            TypeCode::Void => Ok(()),
            TypeCode::Int8 => {
                let v = types::clamp_signed(types::lua_value_to_i64(&value)?, 8)? as i8;
                buffer[..1].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::UInt8 => {
                let v = types::clamp_unsigned(types::lua_value_to_u64(&value)?, 8)? as u8;
                buffer[..1].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::Int16 => {
                let v = types::clamp_signed(types::lua_value_to_i64(&value)?, 16)? as i16;
                buffer[..2].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::UInt16 => {
                let v = types::clamp_unsigned(types::lua_value_to_u64(&value)?, 16)? as u16;
                buffer[..2].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::Int32 => {
                let v = types::clamp_signed(types::lua_value_to_i64(&value)?, 32)? as i32;
                buffer[..4].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::UInt32 => {
                let v = types::clamp_unsigned(types::lua_value_to_u64(&value)?, 32)? as u32;
                buffer[..4].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::Int64 => {
                let v = types::lua_value_to_i64(&value)?;
                buffer[..8].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::UInt64 => {
                let v = types::lua_value_to_u64(&value)?;
                buffer[..8].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::IntPtr => {
                let bits = usize::BITS;
                let value = types::clamp_signed(types::lua_value_to_i64(&value)?, bits)?;
                if bits == 64 {
                    buffer[..8].copy_from_slice(&value.to_ne_bytes());
                } else {
                    let narrowed = value as i32;
                    buffer[..4].copy_from_slice(&narrowed.to_ne_bytes());
                }
                Ok(())
            }
            TypeCode::UIntPtr => {
                let bits = usize::BITS;
                let value = types::clamp_unsigned(types::lua_value_to_u64(&value)?, bits)?;
                if bits == 64 {
                    buffer[..8].copy_from_slice(&value.to_ne_bytes());
                } else {
                    let narrowed = value as u32;
                    buffer[..4].copy_from_slice(&narrowed.to_ne_bytes());
                }
                Ok(())
            }
            TypeCode::Float32 => {
                let v = match value {
                    LuaValue::Number(n) => n as f32,
                    LuaValue::Integer(i) => i as f32,
                    LuaValue::Boolean(b) => {
                        if b {
                            1.0
                        } else {
                            0.0
                        }
                    }
                    other => {
                        return Err(LuaError::runtime(format!(
                            "expected numeric value for float result, got {other:?}"
                        )));
                    }
                };
                buffer[..4].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::Float64 => {
                let v = match value {
                    LuaValue::Number(n) => n,
                    LuaValue::Integer(i) => i as f64,
                    LuaValue::Boolean(b) => {
                        if b {
                            1.0
                        } else {
                            0.0
                        }
                    }
                    other => {
                        return Err(LuaError::runtime(format!(
                            "expected numeric value for double result, got {other:?}"
                        )));
                    }
                };
                buffer[..8].copy_from_slice(&v.to_ne_bytes());
                Ok(())
            }
            TypeCode::Pointer => {
                let ptr = self.pointer_from_value(&value)?;
                let bytes = (ptr as usize).to_ne_bytes();
                let size = std::mem::size_of::<*mut c_void>();
                buffer[..size].copy_from_slice(&bytes[..size]);
                Ok(())
            }
        }
    }

    fn invoke(
        &mut self,
        result: &mut [u8; CALLBACK_RESULT_SIZE],
        args: *const *const c_void,
    ) -> LuaResult<()> {
        let mut values = Vec::with_capacity(self.signature().args().len());
        for (index, ty) in self.signature().args().iter().enumerate() {
            let value = self.read_argument(args, index, ty)?;
            values.push(value);
        }
        let lua_args = LuaMultiValue::from_vec(values);
        let callback = self.get_function()?;
        let returned = callback.call::<LuaValue>(lua_args)?;
        self.write_result(result, returned)
    }

    fn report_error(&self, err: LuaError) {
        let message = format!("ffi: error in callback: {err}");
        let globals = self.lua.globals();
        if let Ok(warn) = globals.get::<LuaFunction>("warn") {
            let _ = warn.call::<()>(message.clone());
            return;
        }
        eprintln!("{message}");
    }
}

struct CallbackHandle {
    closure: Option<Closure<'static>>,
    data: *mut CallbackData,
}

impl CallbackHandle {
    fn new(
        lua: &Lua,
        signature: Signature,
        func: LuaFunction,
    ) -> LuaResult<(Self, LuaLightUserData)> {
        if signature.is_variadic() {
            return Err(LuaError::runtime(
                "TODO(@lune/ffi/callback): variadic callbacks not supported yet".to_string(),
            ));
        }

        let arg_types = signature.arg_types();
        let cif = signature.build_cif(&arg_types);
        let registry_key = lua.create_registry_value(func)?;
        let data = CallbackData::new(lua.clone(), signature, registry_key);
        let data_ptr = Box::into_raw(Box::new(data));
        let closure = Closure::new_mut(cif, callback_trampoline, unsafe { &mut *data_ptr });
        let code_ptr = closure.code_ptr();
        let raw_ptr = *code_ptr as *const () as *mut c_void;
        Ok((
            Self {
                closure: Some(closure),
                data: data_ptr,
            },
            LuaLightUserData(raw_ptr),
        ))
    }
}

impl Drop for CallbackHandle {
    fn drop(&mut self) {
        unsafe {
            if let Some(closure) = self.closure.take() {
                drop(closure);
            }
            if !self.data.is_null() {
                let mut data = Box::from_raw(self.data);
                if let Some(key) = data.function_key.take() {
                    if let Err(err) = data.lua.remove_registry_value(key) {
                        eprintln!("ffi: failed to remove callback registry key: {err}");
                    }
                }
            }
        }
    }
}

impl LuaUserData for CallbackHandle {}

unsafe extern "C" fn callback_trampoline(
    _cif: &libffi::low::ffi_cif,
    result: &mut [u8; CALLBACK_RESULT_SIZE],
    args: *const *const c_void,
    userdata: &mut CallbackData,
) {
    result.fill(0);
    if let Err(err) = userdata.invoke(result, args) {
        userdata.report_error(err);
    }
}

pub fn register(lua: &Lua, exports: &LuaTable) -> LuaResult<()> {
    let factory =
        lua.create_function(|lua, (signature_table, func): (LuaTable, LuaFunction)| {
            let signature = Signature::from_table(signature_table)?;
            let (handle, ptr) = CallbackHandle::new(lua, signature, func)?;
            let userdata = lua.create_userdata(handle)?;
            Ok(LuaMultiValue::from_vec(vec![
                LuaValue::LightUserData(ptr),
                LuaValue::UserData(userdata),
            ]))
        })?;

    exports.set("createCallback", factory)?;
    Ok(())
}
