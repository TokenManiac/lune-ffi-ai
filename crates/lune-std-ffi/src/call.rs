use std::convert::TryFrom;
use std::ffi::{CString, c_void};
use std::ptr;

use libffi::middle::{Arg, Cif, CodePtr, Type};
use mlua::prelude::*;

use crate::signature::{CType, Signature};
use crate::types::{self, TypeCode};

#[derive(Debug)]
enum ArgValue {
    Int8(i8),
    UInt8(u8),
    Int16(i16),
    UInt16(u16),
    Int32(i32),
    UInt32(u32),
    Int64(i64),
    UInt64(u64),
    Float32(f32),
    Float64(f64),
    Pointer(*mut c_void),
}

impl ArgValue {
    fn as_arg(&self) -> Arg {
        match self {
            ArgValue::Int8(value) => Arg::new(value),
            ArgValue::UInt8(value) => Arg::new(value),
            ArgValue::Int16(value) => Arg::new(value),
            ArgValue::UInt16(value) => Arg::new(value),
            ArgValue::Int32(value) => Arg::new(value),
            ArgValue::UInt32(value) => Arg::new(value),
            ArgValue::Int64(value) => Arg::new(value),
            ArgValue::UInt64(value) => Arg::new(value),
            ArgValue::Float32(value) => Arg::new(value),
            ArgValue::Float64(value) => Arg::new(value),
            ArgValue::Pointer(value) => Arg::new(value),
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct CDataInfo {
    ptr: Option<*mut c_void>,
    type_code: Option<TypeCode>,
}

fn extract_cdata_info(table: &LuaTable) -> LuaResult<Option<CDataInfo>> {
    let marker = table.raw_get::<LuaValue>("__ffi_cdata")?;
    if !matches!(marker, LuaValue::Boolean(true)) {
        return Ok(None);
    }

    let ptr_value = table.raw_get::<LuaValue>("__ptr")?;
    let ptr = match ptr_value {
        LuaValue::LightUserData(ptr) => Some(ptr.0),
        LuaValue::Nil => None,
        other => {
            return Err(LuaError::runtime(format!(
                "cdata object missing native pointer (found {other:?})",
            )));
        }
    };

    let type_value = table.raw_get::<LuaValue>("__ctype")?;
    let type_code = match type_value {
        LuaValue::Nil => None,
        LuaValue::String(code) => {
            let normalized = types::normalize_code(code.to_str()?.as_ref());
            match TypeCode::from_code(&normalized) {
                Ok(code) => Some(code),
                Err(_) => None,
            }
        }
        LuaValue::Table(descriptor) => {
            let code_value = descriptor.raw_get::<LuaValue>("code")?;
            match code_value {
                LuaValue::String(code) => {
                    let normalized = types::normalize_code(code.to_str()?.as_ref());
                    match TypeCode::from_code(&normalized) {
                        Ok(code) => Some(code),
                        Err(_) => None,
                    }
                }
                LuaValue::Nil => None,
                other => {
                    return Err(LuaError::runtime(format!(
                        "cdata descriptor missing string code (found {other:?})",
                    )));
                }
            }
        }
        other => {
            return Err(LuaError::runtime(format!(
                "cdata object has invalid __ctype field (found {other:?})",
            )));
        }
    };

    Ok(Some(CDataInfo { ptr, type_code }))
}

fn extract_cdata_pointer(table: &LuaTable) -> LuaResult<Option<*mut c_void>> {
    let info = match extract_cdata_info(table)? {
        Some(info) => info,
        None => return Ok(None),
    };

    Ok(Some(info.ptr.unwrap_or(std::ptr::null_mut())))
}

fn convert_cdata_variadic_argument(
    info: CDataInfo,
    original_type: TypeCode,
) -> LuaResult<(ArgValue, TypeCode)> {
    let ptr = info.ptr.ok_or_else(|| {
        LuaError::runtime("cdata value missing native storage pointer".to_string())
    })?;

    unsafe {
        match original_type {
            TypeCode::Void => Err(LuaError::runtime(
                "void type cannot be used as a variadic argument".to_string(),
            )),
            TypeCode::Int8 => {
                let raw = ptr::read(ptr as *const i8);
                Ok((ArgValue::Int32(raw as i32), TypeCode::Int32))
            }
            TypeCode::UInt8 => {
                let raw = ptr::read(ptr as *const u8);
                Ok((ArgValue::Int32(raw as i32), TypeCode::Int32))
            }
            TypeCode::Int16 => {
                let raw = ptr::read(ptr as *const i16);
                Ok((ArgValue::Int32(raw as i32), TypeCode::Int32))
            }
            TypeCode::UInt16 => {
                let raw = ptr::read(ptr as *const u16);
                Ok((ArgValue::Int32(raw as i32), TypeCode::Int32))
            }
            TypeCode::Int32 => {
                let raw = ptr::read(ptr as *const i32);
                Ok((ArgValue::Int32(raw), TypeCode::Int32))
            }
            TypeCode::UInt32 => {
                let raw = ptr::read(ptr as *const u32);
                Ok((ArgValue::UInt32(raw), TypeCode::UInt32))
            }
            TypeCode::Int64 => {
                let raw = ptr::read(ptr as *const i64);
                Ok((ArgValue::Int64(raw), TypeCode::Int64))
            }
            TypeCode::UInt64 => {
                let raw = ptr::read(ptr as *const u64);
                Ok((ArgValue::UInt64(raw), TypeCode::UInt64))
            }
            TypeCode::IntPtr => {
                if cfg!(target_pointer_width = "64") {
                    let raw = ptr::read(ptr as *const i64);
                    Ok((ArgValue::Int64(raw), TypeCode::IntPtr))
                } else {
                    let raw = ptr::read(ptr as *const i32);
                    Ok((ArgValue::Int32(raw), TypeCode::IntPtr))
                }
            }
            TypeCode::UIntPtr => {
                if cfg!(target_pointer_width = "64") {
                    let raw = ptr::read(ptr as *const u64);
                    Ok((ArgValue::UInt64(raw), TypeCode::UIntPtr))
                } else {
                    let raw = ptr::read(ptr as *const u32);
                    Ok((ArgValue::UInt32(raw), TypeCode::UIntPtr))
                }
            }
            TypeCode::Float32 => {
                let raw = ptr::read(ptr as *const f32);
                Ok((ArgValue::Float64(raw as f64), TypeCode::Float64))
            }
            TypeCode::Float64 => {
                let raw = ptr::read(ptr as *const f64);
                Ok((ArgValue::Float64(raw), TypeCode::Float64))
            }
            TypeCode::Pointer => Ok((
                ArgValue::Pointer(ptr::read(ptr as *const *mut c_void)),
                TypeCode::Pointer,
            )),
        }
    }
}

fn convert_typed_argument(
    value: LuaValue,
    ty: &CType,
    string_refs: &mut Vec<CString>,
) -> LuaResult<(ArgValue, TypeCode)> {
    match ty.code() {
        TypeCode::Void => Err(LuaError::runtime(
            "void type cannot be used as a function argument".to_string(),
        )),
        TypeCode::Int8 => {
            let v = types::clamp_signed(types::lua_value_to_i64(&value)?, 8)? as i8;
            Ok((ArgValue::Int8(v), TypeCode::Int8))
        }
        TypeCode::UInt8 => {
            let v = types::clamp_unsigned(types::lua_value_to_u64(&value)?, 8)? as u8;
            Ok((ArgValue::UInt8(v), TypeCode::UInt8))
        }
        TypeCode::Int16 => {
            let v = types::clamp_signed(types::lua_value_to_i64(&value)?, 16)? as i16;
            Ok((ArgValue::Int16(v), TypeCode::Int16))
        }
        TypeCode::UInt16 => {
            let v = types::clamp_unsigned(types::lua_value_to_u64(&value)?, 16)? as u16;
            Ok((ArgValue::UInt16(v), TypeCode::UInt16))
        }
        TypeCode::Int32 => {
            let v = types::clamp_signed(types::lua_value_to_i64(&value)?, 32)? as i32;
            Ok((ArgValue::Int32(v), TypeCode::Int32))
        }
        TypeCode::UInt32 => {
            let v = types::clamp_unsigned(types::lua_value_to_u64(&value)?, 32)? as u32;
            Ok((ArgValue::UInt32(v), TypeCode::UInt32))
        }
        TypeCode::Int64 => Ok((
            ArgValue::Int64(types::lua_value_to_i64(&value)?),
            TypeCode::Int64,
        )),
        TypeCode::UInt64 => Ok((
            ArgValue::UInt64(types::lua_value_to_u64(&value)?),
            TypeCode::UInt64,
        )),
        TypeCode::IntPtr => {
            let bits = usize::BITS;
            let value = types::clamp_signed(types::lua_value_to_i64(&value)?, bits)?;
            if bits == 64 {
                Ok((ArgValue::Int64(value), TypeCode::IntPtr))
            } else {
                Ok((ArgValue::Int32(value as i32), TypeCode::IntPtr))
            }
        }
        TypeCode::UIntPtr => {
            let bits = usize::BITS;
            let value = types::clamp_unsigned(types::lua_value_to_u64(&value)?, bits)?;
            if bits == 64 {
                Ok((ArgValue::UInt64(value), TypeCode::UIntPtr))
            } else {
                Ok((ArgValue::UInt32(value as u32), TypeCode::UIntPtr))
            }
        }
        TypeCode::Float32 => match value {
            LuaValue::Number(n) => Ok((ArgValue::Float32(n as f32), TypeCode::Float32)),
            LuaValue::Integer(i) => Ok((ArgValue::Float32(i as f32), TypeCode::Float32)),
            LuaValue::Boolean(b) => Ok((
                ArgValue::Float32(if b { 1.0 } else { 0.0 }),
                TypeCode::Float32,
            )),
            other => Err(LuaError::runtime(format!(
                "expected numeric value for float argument, got {other:?}"
            ))),
        },
        TypeCode::Float64 => match value {
            LuaValue::Number(n) => Ok((ArgValue::Float64(n), TypeCode::Float64)),
            LuaValue::Integer(i) => Ok((ArgValue::Float64(i as f64), TypeCode::Float64)),
            LuaValue::Boolean(b) => Ok((
                ArgValue::Float64(if b { 1.0 } else { 0.0 }),
                TypeCode::Float64,
            )),
            other => Err(LuaError::runtime(format!(
                "expected numeric value for double argument, got {other:?}"
            ))),
        },
        TypeCode::Pointer => match value {
            LuaValue::Nil => Ok((ArgValue::Pointer(std::ptr::null_mut()), TypeCode::Pointer)),
            LuaValue::LightUserData(ptr) => Ok((ArgValue::Pointer(ptr.0), TypeCode::Pointer)),
            LuaValue::Table(table) => match extract_cdata_pointer(&table)? {
                Some(ptr) => Ok((ArgValue::Pointer(ptr), TypeCode::Pointer)),
                None => Err(LuaError::runtime(
                    "cannot convert table value to pointer argument".to_string(),
                )),
            },
            LuaValue::Integer(i) => Ok((
                ArgValue::Pointer(
                    usize::try_from(i)
                        .map_err(|_| LuaError::runtime("negative pointer value".to_string()))?
                        as *mut c_void,
                ),
                TypeCode::Pointer,
            )),
            LuaValue::Number(n) => {
                if !n.is_finite() {
                    return Err(LuaError::runtime(
                        "pointer value must be finite".to_string(),
                    ));
                }
                if n < 0.0 {
                    return Err(LuaError::runtime(
                        "pointer value must be non-negative".to_string(),
                    ));
                }
                if (n.trunc() - n).abs() > f64::EPSILON {
                    return Err(LuaError::runtime(
                        "pointer value must be integral".to_string(),
                    ));
                }
                Ok((
                    ArgValue::Pointer(n as usize as *mut c_void),
                    TypeCode::Pointer,
                ))
            }
            LuaValue::String(s) => {
                let owned = CString::new(s.as_bytes().as_ref()).map_err(|_| {
                    LuaError::runtime("string argument contains NUL byte".to_string())
                })?;
                let ptr = owned.as_ptr() as *mut c_void;
                string_refs.push(owned);
                Ok((ArgValue::Pointer(ptr), TypeCode::Pointer))
            }
            other => Err(LuaError::runtime(format!(
                "cannot convert value {other:?} to pointer argument"
            ))),
        },
    }
}

fn convert_variadic_argument(
    value: LuaValue,
    string_refs: &mut Vec<CString>,
) -> LuaResult<(ArgValue, TypeCode)> {
    match value {
        LuaValue::Nil => Ok((ArgValue::Pointer(std::ptr::null_mut()), TypeCode::Pointer)),
        LuaValue::LightUserData(ptr) => Ok((ArgValue::Pointer(ptr.0), TypeCode::Pointer)),
        LuaValue::Table(table) => {
            if let Some(info) = extract_cdata_info(&table)? {
                if let Some(type_code) = info.type_code {
                    if matches!(type_code, TypeCode::Pointer) {
                        let ptr = info.ptr.unwrap_or(std::ptr::null_mut());
                        return Ok((ArgValue::Pointer(ptr), TypeCode::Pointer));
                    }
                    return convert_cdata_variadic_argument(info, type_code);
                }

                if let Some(ptr) = info.ptr {
                    return Ok((ArgValue::Pointer(ptr), TypeCode::Pointer));
                }

                return Err(LuaError::runtime(
                    "cannot infer C type for variadic cdata argument".to_string(),
                ));
            }

            Err(LuaError::runtime(
                "cannot infer C type for variadic table argument".to_string(),
            ))
        }
        LuaValue::String(s) => {
            let owned = CString::new(s.as_bytes().as_ref())
                .map_err(|_| LuaError::runtime("string argument contains NUL byte".to_string()))?;
            let ptr = owned.as_ptr() as *mut c_void;
            string_refs.push(owned);
            Ok((ArgValue::Pointer(ptr), TypeCode::Pointer))
        }
        LuaValue::Boolean(b) => {
            let value = if b { 1 } else { 0 };
            Ok((ArgValue::Int32(value), TypeCode::Int32))
        }
        LuaValue::Integer(i) => {
            if cfg!(target_pointer_width = "64") {
                Ok((ArgValue::Int64(i), TypeCode::Int64))
            } else {
                let clamped = types::clamp_signed(i, 32)? as i32;
                Ok((ArgValue::Int32(clamped), TypeCode::Int32))
            }
        }
        LuaValue::Number(n) => {
            if !n.is_finite() {
                return Err(LuaError::runtime(
                    "numeric argument must be finite".to_string(),
                ));
            }
            Ok((ArgValue::Float64(n), TypeCode::Float64))
        }
        other => Err(LuaError::runtime(format!(
            "cannot infer C type for variadic argument {other:?}"
        ))),
    }
}

fn convert_argument(
    value: LuaValue,
    ty: Option<&CType>,
    string_refs: &mut Vec<CString>,
) -> LuaResult<(ArgValue, TypeCode)> {
    match ty {
        Some(ty) => convert_typed_argument(value, ty, string_refs),
        None => convert_variadic_argument(value, string_refs),
    }
}

fn collect_arguments(
    args_table: LuaTable,
    signature: &Signature,
) -> LuaResult<(Vec<ArgValue>, Vec<Type>, Vec<CString>)> {
    let explicit_n = args_table.get::<Option<u32>>("n")?.map(|n| n as usize);
    let arg_count = explicit_n.unwrap_or_else(|| args_table.raw_len() as usize);

    if signature.is_variadic() {
        if arg_count < signature.fixed_count() {
            return Err(LuaError::runtime(format!(
                "function expected at least {} argument(s) but received {arg_count}",
                signature.fixed_count()
            )));
        }
    } else {
        let expected = signature.args().len();
        if arg_count != expected {
            return Err(LuaError::runtime(format!(
                "function expected {expected} argument(s) but received {arg_count}"
            )));
        }
    }

    let mut values = Vec::with_capacity(arg_count);
    let mut arg_types = Vec::with_capacity(arg_count);
    let mut string_refs = Vec::new();

    for index in 0..arg_count {
        let value = args_table.raw_get::<LuaValue>(index as i64 + 1)?;
        let type_hint = signature.args().get(index);

        if index < signature.fixed_count() {
            let ty = type_hint.ok_or_else(|| {
                LuaError::runtime(format!(
                    "missing type information for fixed argument {}",
                    index + 1
                ))
            })?;

            let (arg, _) = convert_argument(value, Some(ty), &mut string_refs)?;
            arg_types.push(ty.to_libffi_type());
            values.push(arg);
            continue;
        }

        if !signature.is_variadic() {
            let ty = type_hint.ok_or_else(|| {
                LuaError::runtime(format!(
                    "missing type information for argument {}",
                    index + 1
                ))
            })?;
            let (arg, _) = convert_argument(value, Some(ty), &mut string_refs)?;
            arg_types.push(ty.to_libffi_type());
            values.push(arg);
            continue;
        }

        let (arg, inferred) = convert_argument(value, type_hint, &mut string_refs)?;
        let ffi_type = match type_hint {
            Some(ty) => ty.to_libffi_type(),
            None => CType { code: inferred }.to_libffi_type(),
        };
        arg_types.push(ffi_type);
        values.push(arg);
    }

    Ok((values, arg_types, string_refs))
}

fn call_with_signature(
    signature: &Signature,
    func: LuaLightUserData,
    cif: Cif,
    args: &[Arg],
) -> LuaResult<LuaValue> {
    let code_ptr = CodePtr::from_ptr(func.0 as *const c_void);

    unsafe {
        match signature.result().code() {
            TypeCode::Void => {
                cif.call::<()>(code_ptr, args);
                Ok(LuaValue::Nil)
            }
            TypeCode::Int8 => {
                let value: i8 = cif.call(code_ptr, args);
                Ok(LuaValue::Integer(value.into()))
            }
            TypeCode::UInt8 => {
                let value: u8 = cif.call(code_ptr, args);
                Ok(LuaValue::Integer((value as i64).into()))
            }
            TypeCode::Int16 => {
                let value: i16 = cif.call(code_ptr, args);
                Ok(LuaValue::Integer(value.into()))
            }
            TypeCode::UInt16 => {
                let value: u16 = cif.call(code_ptr, args);
                Ok(LuaValue::Integer((value as i64).into()))
            }
            TypeCode::Int32 => {
                let value: i32 = cif.call(code_ptr, args);
                Ok(LuaValue::Integer(value.into()))
            }
            TypeCode::UInt32 => {
                let value: u32 = cif.call(code_ptr, args);
                Ok(LuaValue::Integer((value as i64).into()))
            }
            TypeCode::Int64 => {
                let value: i64 = cif.call(code_ptr, args);
                Ok(LuaValue::Integer(value))
            }
            TypeCode::UInt64 => {
                let value: u64 = cif.call(code_ptr, args);
                if value <= i64::MAX as u64 {
                    Ok(LuaValue::Integer(value as i64))
                } else {
                    Ok(LuaValue::Number(value as f64))
                }
            }
            TypeCode::IntPtr => {
                if cfg!(target_pointer_width = "64") {
                    let value: i64 = cif.call(code_ptr, args);
                    Ok(LuaValue::Integer(value))
                } else {
                    let value: i32 = cif.call(code_ptr, args);
                    Ok(LuaValue::Integer(value.into()))
                }
            }
            TypeCode::UIntPtr => {
                if cfg!(target_pointer_width = "64") {
                    let value: u64 = cif.call(code_ptr, args);
                    if value <= i64::MAX as u64 {
                        Ok(LuaValue::Integer(value as i64))
                    } else {
                        Ok(LuaValue::Number(value as f64))
                    }
                } else {
                    let value: u32 = cif.call(code_ptr, args);
                    Ok(LuaValue::Integer((value as i64).into()))
                }
            }
            TypeCode::Float32 => {
                let value: f32 = cif.call(code_ptr, args);
                Ok(LuaValue::Number(value as f64))
            }
            TypeCode::Float64 => {
                let value: f64 = cif.call(code_ptr, args);
                Ok(LuaValue::Number(value))
            }
            TypeCode::Pointer => {
                let value: *mut c_void = cif.call(code_ptr, args);
                if value.is_null() {
                    Ok(LuaValue::Nil)
                } else {
                    Ok(LuaValue::LightUserData(LuaLightUserData(value)))
                }
            }
        }
    }
}

pub fn call(
    _lua: &Lua,
    func: LuaLightUserData,
    signature_table: LuaTable,
    args_table: LuaTable,
) -> LuaResult<LuaValue> {
    let signature = Signature::from_table(signature_table)?;
    let (arg_values, arg_types, _owned_strings) = collect_arguments(args_table, &signature)?;
    let arg_refs: Vec<Arg> = arg_values.iter().map(ArgValue::as_arg).collect();
    let cif = signature.build_cif(&arg_types);
    call_with_signature(&signature, func, cif, &arg_refs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;
    use std::os::raw::{c_char, c_void};

    struct RawBox<T>(*mut T);

    impl<T> RawBox<T> {
        fn new(value: T) -> Self {
            RawBox(Box::into_raw(Box::new(value)))
        }

        fn ptr(&self) -> *mut T {
            self.0
        }
    }

    impl<T> Drop for RawBox<T> {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    drop(Box::from_raw(self.0));
                }
                self.0 = std::ptr::null_mut();
            }
        }
    }

    unsafe extern "C" {
        fn luneffi_test_add_ints(a: i32, b: i32) -> i32;
        fn luneffi_test_variadic_sum(count: i32, ...) -> i32;
        fn luneffi_test_variadic_format(
            buffer: *mut c_char,
            size: usize,
            fmt: *const c_char,
            ...
        ) -> i32;
    }

    fn make_signature(
        lua: &Lua,
        result: &str,
        args: &[&str],
        variadic: bool,
        fixed: usize,
    ) -> LuaResult<LuaTable> {
        let signature = lua.create_table()?;
        signature.set("result", result)?;

        let args_table = lua.create_table()?;
        for (index, code) in args.iter().enumerate() {
            args_table.set(index + 1, *code)?;
        }
        signature.set("args", args_table)?;

        if variadic {
            signature.set("variadic", true)?;
            signature.set("fixedCount", fixed as u32)?;
        }

        Ok(signature)
    }

    fn pack_args(lua: &Lua, values: Vec<LuaValue>) -> LuaResult<LuaTable> {
        let len = values.len();
        let args = lua.create_table()?;
        for (index, value) in values.into_iter().enumerate() {
            args.raw_set((index + 1) as i64, value)?;
        }
        args.set("n", len)?;
        Ok(args)
    }

    fn make_cdata_table(lua: &Lua, code: &str, ptr: *mut c_void) -> LuaResult<LuaTable> {
        let table = lua.create_table()?;
        table.raw_set("__ffi_cdata", LuaValue::Boolean(true))?;
        table.raw_set("__ptr", LuaValue::LightUserData(LuaLightUserData(ptr)))?;

        let descriptor = lua.create_table()?;
        descriptor.set("code", code)?;
        descriptor.set("kind", "primitive")?;
        table.raw_set("__ctype", LuaValue::Table(descriptor))?;

        Ok(table)
    }

    #[test]
    fn call_simple_add() -> LuaResult<()> {
        let lua = Lua::new();
        let signature = make_signature(&lua, "int32", &["int32", "int32"], false, 2)?;
        let args = pack_args(&lua, vec![LuaValue::Integer(12), LuaValue::Integer(30)])?;
        let func = LuaLightUserData(luneffi_test_add_ints as *const () as *mut c_void);
        let result = call(&lua, func, signature, args)?;
        match result {
            LuaValue::Integer(value) => assert_eq!(value, 42),
            other => panic!("unexpected result: {other:?}"),
        }
        Ok(())
    }

    #[test]
    fn call_variadic_sum_infers_arguments() -> LuaResult<()> {
        let lua = Lua::new();
        let signature = make_signature(&lua, "int32", &["int32"], true, 1)?;
        let args = pack_args(
            &lua,
            vec![
                LuaValue::Integer(3),
                LuaValue::Integer(10),
                LuaValue::Integer(20),
                LuaValue::Integer(5),
            ],
        )?;
        let func = LuaLightUserData(luneffi_test_variadic_sum as *const () as *mut c_void);
        let result = call(&lua, func, signature, args)?;
        match result {
            LuaValue::Integer(value) => assert_eq!(value, 35),
            other => panic!("unexpected result: {other:?}"),
        }
        Ok(())
    }

    #[test]
    fn call_variadic_format_handles_strings() -> LuaResult<()> {
        let lua = Lua::new();
        let signature = make_signature(&lua, "int32", &["pointer", "size_t", "pointer"], true, 3)?;

        let mut buffer: [c_char; 64] = [0; 64];
        let format = lua.create_string("%d + %d = %d")?;

        let args = pack_args(
            &lua,
            vec![
                LuaValue::LightUserData(LuaLightUserData(buffer.as_mut_ptr() as *mut c_void)),
                LuaValue::Integer(buffer.len() as i64),
                LuaValue::String(format),
                LuaValue::Integer(4),
                LuaValue::Integer(7),
                LuaValue::Integer(11),
            ],
        )?;

        let func = LuaLightUserData(luneffi_test_variadic_format as *const () as *mut c_void);
        let result = call(&lua, func, signature, args)?;
        let written = match result {
            LuaValue::Integer(value) => value,
            other => panic!("unexpected result: {other:?}"),
        };
        assert!(written >= 0);

        let c_str = unsafe { CStr::from_ptr(buffer.as_ptr()) };
        assert_eq!(c_str.to_str().unwrap(), "4 + 7 = 11");
        Ok(())
    }

    #[test]
    fn call_variadic_uses_cdata_type_information() -> LuaResult<()> {
        let lua = Lua::new();
        let signature = make_signature(&lua, "int32", &["pointer", "size_t", "pointer"], true, 3)?;

        let mut buffer: [c_char; 128] = [0; 128];
        let format = lua.create_string("%lld %.2f")?;

        let big_value_raw: i64 = 1_234_567_890_123;
        let float_value_raw: f32 = 3.25;
        let big_value = RawBox::new(big_value_raw);
        let float_value = RawBox::new(float_value_raw);

        let int_cdata = make_cdata_table(&lua, "int64", big_value.ptr() as *mut c_void)?;
        let float_cdata = make_cdata_table(&lua, "float", float_value.ptr() as *mut c_void)?;

        let args = pack_args(
            &lua,
            vec![
                LuaValue::LightUserData(LuaLightUserData(buffer.as_mut_ptr() as *mut c_void)),
                LuaValue::Integer(buffer.len() as i64),
                LuaValue::String(format),
                LuaValue::Table(int_cdata),
                LuaValue::Table(float_cdata),
            ],
        )?;

        let func = LuaLightUserData(luneffi_test_variadic_format as *const () as *mut c_void);
        let result = call(&lua, func, signature, args)?;
        let written = match result {
            LuaValue::Integer(value) => value,
            other => panic!("unexpected result: {other:?}"),
        };
        assert!(written > 0);

        let c_str = unsafe { CStr::from_ptr(buffer.as_ptr()) };
        assert_eq!(
            c_str.to_str().unwrap(),
            format!("{big_value_raw} {float_value_raw:.2}"),
        );
        Ok(())
    }
}
