use std::ffi::c_void;

use mlua::prelude::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TypeCode {
    Void,
    Int8,
    UInt8,
    Int16,
    UInt16,
    Int32,
    UInt32,
    Int64,
    UInt64,
    IntPtr,
    UIntPtr,
    Float32,
    Float64,
    Pointer,
}

impl TypeCode {
    pub fn from_code(code: &str) -> LuaResult<Self> {
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
            "long" => {
                if cfg!(target_pointer_width = "64") && !cfg!(target_os = "windows") {
                    Ok(TypeCode::Int64)
                } else {
                    Ok(TypeCode::Int32)
                }
            }
            "unsigned long" => {
                if cfg!(target_pointer_width = "64") && !cfg!(target_os = "windows") {
                    Ok(TypeCode::UInt64)
                } else {
                    Ok(TypeCode::UInt32)
                }
            }
            "size_t" | "uintptr_t" => Ok(TypeCode::UIntPtr),
            "ssize_t" | "intptr_t" | "ptrdiff_t" => Ok(TypeCode::IntPtr),
            "float" => Ok(TypeCode::Float32),
            "double" => Ok(TypeCode::Float64),
            "pointer" | "void*" => Ok(TypeCode::Pointer),
            other => Err(LuaError::runtime(format!(
                "Unsupported primitive type code '{other}'"
            ))),
        }
    }

    pub fn size_of(self) -> usize {
        match self {
            TypeCode::Void => 0,
            TypeCode::Int8 | TypeCode::UInt8 => std::mem::size_of::<i8>(),
            TypeCode::Int16 | TypeCode::UInt16 => std::mem::size_of::<i16>(),
            TypeCode::Int32 | TypeCode::UInt32 => std::mem::size_of::<i32>(),
            TypeCode::Int64 | TypeCode::UInt64 => std::mem::size_of::<i64>(),
            TypeCode::IntPtr | TypeCode::UIntPtr | TypeCode::Pointer => {
                std::mem::size_of::<*mut c_void>()
            }
            TypeCode::Float32 => std::mem::size_of::<f32>(),
            TypeCode::Float64 => std::mem::size_of::<f64>(),
        }
    }

    pub fn align_of(self) -> usize {
        match self {
            TypeCode::Void => 1,
            TypeCode::Int8 | TypeCode::UInt8 => std::mem::align_of::<i8>(),
            TypeCode::Int16 | TypeCode::UInt16 => std::mem::align_of::<i16>(),
            TypeCode::Int32 | TypeCode::UInt32 => std::mem::align_of::<i32>(),
            TypeCode::Int64 | TypeCode::UInt64 => std::mem::align_of::<i64>(),
            TypeCode::IntPtr | TypeCode::UIntPtr | TypeCode::Pointer => {
                std::mem::align_of::<*mut c_void>()
            }
            TypeCode::Float32 => std::mem::align_of::<f32>(),
            TypeCode::Float64 => std::mem::align_of::<f64>(),
        }
    }
}

pub fn normalize_code(code: &str) -> String {
    code.trim().to_ascii_lowercase()
}

pub fn lua_value_to_i64(value: &LuaValue) -> LuaResult<i64> {
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

pub fn lua_value_to_u64(value: &LuaValue) -> LuaResult<u64> {
    let signed = lua_value_to_i64(value)?;
    if signed < 0 {
        return Err(LuaError::runtime(
            "negative value provided for unsigned argument".to_string(),
        ));
    }
    Ok(signed as u64)
}

pub fn clamp_signed(value: i64, bits: u32) -> LuaResult<i64> {
    let min = -(1i64 << (bits - 1));
    let max = (1i64 << (bits - 1)) - 1;
    if value < min || value > max {
        return Err(LuaError::runtime(format!(
            "signed argument out of range for {bits}-bit integer"
        )));
    }
    Ok(value)
}

pub fn clamp_unsigned(value: u64, bits: u32) -> LuaResult<u64> {
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
