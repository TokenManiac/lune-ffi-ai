use std::convert::TryFrom;
use std::ffi::c_void;

use cfg_if::cfg_if;
use libffi::middle::{self, Arg, Cif, CodePtr, Type};
use mlua::prelude::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TypeCode {
    Void,
    Int8,
    UInt8,
    Int16,
    UInt16,
    Int32,
    UInt32,
    Int64,
    UInt64,
    Float32,
    Float64,
    Pointer,
}

impl TypeCode {
    fn from_code(code: &str) -> LuaResult<Self> {
        match code {
            "void" => Ok(TypeCode::Void),
            "int8" | "sint8" => Ok(TypeCode::Int8),
            "uint8" => Ok(TypeCode::UInt8),
            "int16" | "sint16" => Ok(TypeCode::Int16),
            "uint16" => Ok(TypeCode::UInt16),
            "int32" | "sint32" | "int" => Ok(TypeCode::Int32),
            "uint32" | "unsigned int" => Ok(TypeCode::UInt32),
            "int64" | "sint64" | "long long" => Ok(TypeCode::Int64),
            "uint64" | "unsigned long long" => Ok(TypeCode::UInt64),
            "float" => Ok(TypeCode::Float32),
            "double" => Ok(TypeCode::Float64),
            "pointer" | "void*" => Ok(TypeCode::Pointer),
            other => Err(LuaError::runtime(format!(
                "Unsupported primitive type code '{other}'"
            ))),
        }
    }

    fn to_libffi_type(self) -> Type {
        match self {
            TypeCode::Void => Type::void(),
            TypeCode::Int8 => Type::i8(),
            TypeCode::UInt8 => Type::u8(),
            TypeCode::Int16 => Type::i16(),
            TypeCode::UInt16 => Type::u16(),
            TypeCode::Int32 => Type::i32(),
            TypeCode::UInt32 => Type::u32(),
            TypeCode::Int64 => Type::i64(),
            TypeCode::UInt64 => Type::u64(),
            TypeCode::Float32 => Type::f32(),
            TypeCode::Float64 => Type::f64(),
            TypeCode::Pointer => Type::pointer(),
        }
    }
}

#[derive(Clone, Debug)]
struct CType {
    code: TypeCode,
}

impl CType {
    fn from_lua(value: LuaValue) -> LuaResult<Self> {
        match value {
            LuaValue::String(code) => {
                let normalized = code.to_str()?.trim().to_ascii_lowercase();
                let ty = TypeCode::from_code(&normalized)?;
                Ok(Self { code: ty })
            }
            LuaValue::Table(table) => {
                let code: String = table.get("code").map_err(|_| {
                    LuaError::runtime("Type descriptor missing 'code' field".to_string())
                })?;
                let normalized = code.trim().to_ascii_lowercase();
                let ty = TypeCode::from_code(&normalized)?;
                Ok(Self { code: ty })
            }
            other => Err(LuaError::runtime(format!(
                "Invalid type descriptor (expected table or string, got {other:?})"
            ))),
        }
    }

    fn to_libffi_type(&self) -> Type {
        self.code.to_libffi_type()
    }
}

#[derive(Clone, Copy, Debug)]
enum AbiChoice {
    Explicit(middle::FfiAbi),
    Default,
}

impl AbiChoice {
    fn from_option(value: Option<String>) -> LuaResult<Self> {
        match value.as_deref() {
            None | Some("cdecl") | Some("default") => Ok(AbiChoice::Default),
            Some("sysv") => {
                cfg_if! {
                    if #[cfg(all(target_arch = "x86_64", unix))] {
                        Ok(AbiChoice::Explicit(libffi::raw::ffi_abi_FFI_UNIX64))
                    } else if #[cfg(any(
                        target_arch = "x86",
                        target_arch = "arm",
                        target_arch = "aarch64",
                        target_arch = "powerpc",
                    ))] {
                        Ok(AbiChoice::Explicit(libffi::raw::ffi_abi_FFI_SYSV))
                    } else if #[cfg(all(target_os = "windows", target_arch = "x86_64"))] {
                        Ok(AbiChoice::Explicit(libffi::raw::ffi_abi_FFI_WIN64))
                    } else {
                        Err(LuaError::runtime("ABI 'sysv' not supported on this target".to_string()))
                    }
                }
            }
            Some("stdcall") => {
                cfg_if! {
                    if #[cfg(any(target_arch = "x86"))] {
                        Ok(AbiChoice::Explicit(libffi::raw::ffi_abi_FFI_STDCALL))
                    } else {
                        Err(LuaError::runtime("ABI 'stdcall' requires x86 architecture".to_string()))
                    }
                }
            }
            Some("ms_abi") | Some("ms_cdecl") => {
                cfg_if! {
                    if #[cfg(all(target_os = "windows", target_arch = "x86"))] {
                        Ok(AbiChoice::Explicit(libffi::raw::ffi_abi_FFI_MS_CDECL))
                    } else if #[cfg(all(target_os = "windows", target_arch = "x86_64"))] {
                        Ok(AbiChoice::Explicit(libffi::raw::ffi_abi_FFI_WIN64))
                    } else {
                        Err(LuaError::runtime("ABI 'ms_abi' only available on Windows targets".to_string()))
                    }
                }
            }
            Some("win64") => {
                cfg_if! {
                    if #[cfg(target_os = "windows")] {
                        Ok(AbiChoice::Explicit(libffi::raw::ffi_abi_FFI_WIN64))
                    } else {
                        Err(LuaError::runtime("ABI 'win64' only available on Windows targets".to_string()))
                    }
                }
            }
            Some(other) => Err(LuaError::runtime(format!("Unsupported ABI '{other}'"))),
        }
    }
}

#[derive(Debug)]
struct Signature {
    abi: AbiChoice,
    result: CType,
    args: Vec<CType>,
    variadic: bool,
    fixed_count: usize,
}

impl Signature {
    fn from_table(table: LuaTable) -> LuaResult<Self> {
        let abi = AbiChoice::from_option(table.get::<Option<String>>("abi")?)?;
        let result_value: LuaValue = table.get("result")?;
        let result = CType::from_lua(result_value)?;

        let args_table: LuaTable = table.get("args")?;
        let mut args = Vec::with_capacity(args_table.raw_len() as usize);
        for value in args_table.sequence_values::<LuaValue>() {
            let value = value?;
            args.push(CType::from_lua(value)?);
        }

        let variadic = table.get::<Option<bool>>("variadic")?.unwrap_or(false);
        let fixed_count = table
            .get::<Option<u32>>("fixedCount")?
            .map_or(args.len(), |n| n as usize);

        if fixed_count > args.len() {
            return Err(LuaError::runtime(format!(
                "Invalid signature: fixedCount ({fixed_count}) exceeds number of arguments ({})",
                args.len()
            )));
        }

        Ok(Signature {
            abi,
            result,
            args,
            variadic,
            fixed_count,
        })
    }
}

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

fn lua_value_to_i64(value: &LuaValue) -> LuaResult<i64> {
    match value {
        LuaValue::Integer(i) => Ok(*i),
        LuaValue::Number(n) => {
            if !n.is_finite() {
                return Err(LuaError::runtime(
                    "numeric argument must be finite".to_string(),
                ));
            }
            let truncated = n.trunc();
            if (truncated - n).abs() > f64::EPSILON {
                return Err(LuaError::runtime(
                    "numeric argument must be integral".to_string(),
                ));
            }
            Ok(truncated as i64)
        }
        LuaValue::Boolean(b) => Ok(if *b { 1 } else { 0 }),
        other => Err(LuaError::runtime(format!(
            "expected numeric value, got {other:?}"
        ))),
    }
}

fn lua_value_to_u64(value: &LuaValue) -> LuaResult<u64> {
    let signed = lua_value_to_i64(value)?;
    if signed < 0 {
        return Err(LuaError::runtime(
            "negative value provided for unsigned argument".to_string(),
        ));
    }
    Ok(signed as u64)
}

fn clamp_signed(value: i64, bits: u32) -> LuaResult<i64> {
    let min = -(1i64 << (bits - 1));
    let max = (1i64 << (bits - 1)) - 1;
    if value < min || value > max {
        return Err(LuaError::runtime(format!(
            "signed argument out of range for {bits}-bit integer"
        )));
    }
    Ok(value)
}

fn clamp_unsigned(value: u64, bits: u32) -> LuaResult<u64> {
    let max = if bits == 64 {
        u64::MAX
    } else {
        (1u64 << bits) - 1
    };
    if value > max {
        return Err(LuaError::runtime(format!(
            "unsigned argument out of range for {bits}-bit integer"
        )));
    }
    Ok(value)
}

fn convert_argument(
    value: LuaValue,
    ty: &CType,
    string_refs: &mut Vec<LuaString>,
) -> LuaResult<ArgValue> {
    match ty.code {
        TypeCode::Void => Err(LuaError::runtime(
            "void type cannot be used as a function argument".to_string(),
        )),
        TypeCode::Int8 => {
            let v = clamp_signed(lua_value_to_i64(&value)?, 8)? as i8;
            Ok(ArgValue::Int8(v))
        }
        TypeCode::UInt8 => {
            let v = clamp_unsigned(lua_value_to_u64(&value)?, 8)? as u8;
            Ok(ArgValue::UInt8(v))
        }
        TypeCode::Int16 => {
            let v = clamp_signed(lua_value_to_i64(&value)?, 16)? as i16;
            Ok(ArgValue::Int16(v))
        }
        TypeCode::UInt16 => {
            let v = clamp_unsigned(lua_value_to_u64(&value)?, 16)? as u16;
            Ok(ArgValue::UInt16(v))
        }
        TypeCode::Int32 => {
            let v = clamp_signed(lua_value_to_i64(&value)?, 32)? as i32;
            Ok(ArgValue::Int32(v))
        }
        TypeCode::UInt32 => {
            let v = clamp_unsigned(lua_value_to_u64(&value)?, 32)? as u32;
            Ok(ArgValue::UInt32(v))
        }
        TypeCode::Int64 => Ok(ArgValue::Int64(lua_value_to_i64(&value)?)),
        TypeCode::UInt64 => Ok(ArgValue::UInt64(lua_value_to_u64(&value)?)),
        TypeCode::Float32 => match value {
            LuaValue::Number(n) => Ok(ArgValue::Float32(n as f32)),
            LuaValue::Integer(i) => Ok(ArgValue::Float32(i as f32)),
            LuaValue::Boolean(b) => Ok(ArgValue::Float32(if b { 1.0 } else { 0.0 })),
            other => Err(LuaError::runtime(format!(
                "expected numeric value for float argument, got {other:?}"
            ))),
        },
        TypeCode::Float64 => match value {
            LuaValue::Number(n) => Ok(ArgValue::Float64(n)),
            LuaValue::Integer(i) => Ok(ArgValue::Float64(i as f64)),
            LuaValue::Boolean(b) => Ok(ArgValue::Float64(if b { 1.0 } else { 0.0 })),
            other => Err(LuaError::runtime(format!(
                "expected numeric value for double argument, got {other:?}"
            ))),
        },
        TypeCode::Pointer => match value {
            LuaValue::Nil => Ok(ArgValue::Pointer(std::ptr::null_mut())),
            LuaValue::LightUserData(ptr) => Ok(ArgValue::Pointer(ptr.0)),
            LuaValue::Integer(i) => Ok(ArgValue::Pointer(
                usize::try_from(i)
                    .map_err(|_| LuaError::runtime("negative pointer value".to_string()))?
                    as *mut c_void,
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
                Ok(ArgValue::Pointer(n as usize as *mut c_void))
            }
            LuaValue::String(s) => {
                let bytes = s.as_bytes();
                let ptr = bytes.as_ptr() as *mut c_void;
                string_refs.push(s);
                Ok(ArgValue::Pointer(ptr))
            }
            other => Err(LuaError::runtime(format!(
                "cannot convert value {other:?} to pointer argument"
            ))),
        },
    }
}

fn collect_arguments(
    args_table: LuaTable,
    signature: &Signature,
) -> LuaResult<(Vec<ArgValue>, Vec<LuaString>)> {
    let declared_count = signature.args.len();
    let explicit_n = args_table.get::<Option<u32>>("n")?.map(|n| n as usize);
    let arg_count = explicit_n.unwrap_or_else(|| args_table.raw_len() as usize);

    if arg_count != declared_count {
        return Err(LuaError::runtime(format!(
            "function expected {declared_count} argument(s) but received {arg_count}"
        )));
    }

    let mut values = Vec::with_capacity(arg_count);
    let mut string_refs = Vec::new();

    for (index, ty) in signature.args.iter().enumerate() {
        let value = args_table.raw_get::<LuaValue>(index as i64 + 1)?;
        let arg = convert_argument(value, ty, &mut string_refs)?;
        values.push(arg);
    }

    Ok((values, string_refs))
}

fn build_cif(signature: &Signature) -> Cif {
    let arg_types: Vec<Type> = signature.args.iter().map(CType::to_libffi_type).collect();
    let result_type = signature.result.to_libffi_type();

    let mut cif = if signature.variadic {
        Cif::new_variadic(
            arg_types.clone().into_iter(),
            signature.fixed_count,
            result_type,
        )
    } else {
        Cif::new(arg_types.into_iter(), result_type)
    };

    if let AbiChoice::Explicit(abi) = signature.abi {
        cif.set_abi(abi);
    }

    cif
}

fn call_with_signature(
    signature: &Signature,
    func: LuaLightUserData,
    cif: Cif,
    args: &[Arg],
) -> LuaResult<LuaValue> {
    let code_ptr = CodePtr::from_ptr(func.0 as *const c_void);

    unsafe {
        match signature.result.code {
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
    let (arg_values, _string_refs) = collect_arguments(args_table, &signature)?;
    let arg_refs: Vec<Arg> = arg_values.iter().map(ArgValue::as_arg).collect();
    let cif = build_cif(&signature);
    call_with_signature(&signature, func, cif, &arg_refs)
}
