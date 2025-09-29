use cfg_if::cfg_if;
use libffi::middle::{self, Cif, Type};
use mlua::prelude::*;

use crate::types::{self, TypeCode};

#[derive(Clone, Debug)]
pub struct CType {
    pub(crate) code: TypeCode,
}

impl CType {
    pub(crate) fn from_lua(value: LuaValue) -> LuaResult<Self> {
        match value {
            LuaValue::String(code) => {
                let normalized = types::normalize_code(code.to_str()?.as_ref());
                let ty = TypeCode::from_code(&normalized)?;
                Ok(Self { code: ty })
            }
            LuaValue::Table(table) => {
                let code: String = table.get("code").map_err(|_| {
                    LuaError::runtime("Type descriptor missing 'code' field".to_string())
                })?;
                let normalized = types::normalize_code(&code);
                let ty = TypeCode::from_code(&normalized)?;
                Ok(Self { code: ty })
            }
            other => Err(LuaError::runtime(format!(
                "Invalid type descriptor (expected table or string, got {other:?})"
            ))),
        }
    }

    pub(crate) fn to_libffi_type(&self) -> Type {
        match self.code {
            TypeCode::Void => Type::void(),
            TypeCode::Int8 => Type::i8(),
            TypeCode::UInt8 => Type::u8(),
            TypeCode::Int16 => Type::i16(),
            TypeCode::UInt16 => Type::u16(),
            TypeCode::Int32 => Type::i32(),
            TypeCode::UInt32 => Type::u32(),
            TypeCode::Int64 => Type::i64(),
            TypeCode::UInt64 => Type::u64(),
            TypeCode::IntPtr => {
                if cfg!(target_pointer_width = "64") {
                    Type::i64()
                } else {
                    Type::i32()
                }
            }
            TypeCode::UIntPtr => {
                if cfg!(target_pointer_width = "64") {
                    Type::u64()
                } else {
                    Type::u32()
                }
            }
            TypeCode::Float32 => Type::f32(),
            TypeCode::Float64 => Type::f64(),
            TypeCode::Pointer => Type::pointer(),
        }
    }

    pub(crate) fn code(&self) -> TypeCode {
        self.code
    }
}

#[derive(Clone, Copy, Debug)]
pub enum AbiChoice {
    Explicit(middle::FfiAbi),
    Default,
}

impl AbiChoice {
    pub(crate) fn from_option(value: Option<String>) -> LuaResult<Self> {
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

    pub(crate) fn explicit(self) -> Option<middle::FfiAbi> {
        match self {
            AbiChoice::Explicit(abi) => Some(abi),
            AbiChoice::Default => None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Signature {
    pub(crate) abi: AbiChoice,
    pub(crate) result: CType,
    pub(crate) args: Vec<CType>,
    pub(crate) variadic: bool,
    pub(crate) fixed_count: usize,
}

impl Signature {
    pub(crate) fn from_table(table: LuaTable) -> LuaResult<Self> {
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

        if !variadic && fixed_count != args.len() {
            return Err(LuaError::runtime(
                "Invalid signature: fixedCount must equal number of arguments for non-variadic functions"
                    .to_string(),
            ));
        }

        Ok(Signature {
            abi,
            result,
            args,
            variadic,
            fixed_count,
        })
    }

    pub(crate) fn args(&self) -> &[CType] {
        &self.args
    }

    pub(crate) fn result(&self) -> &CType {
        &self.result
    }

    pub(crate) fn is_variadic(&self) -> bool {
        self.variadic
    }

    pub(crate) fn fixed_count(&self) -> usize {
        self.fixed_count
    }

    pub(crate) fn arg_types(&self) -> Vec<Type> {
        self.args.iter().map(CType::to_libffi_type).collect()
    }

    pub(crate) fn build_cif(&self, arg_types: &[Type]) -> Cif {
        let result_type = self.result.to_libffi_type();

        let mut cif = if self.variadic {
            Cif::new_variadic(arg_types.iter().cloned(), self.fixed_count, result_type)
        } else {
            Cif::new(arg_types.iter().cloned(), result_type)
        };

        if let Some(explicit) = self.abi.explicit() {
            cif.set_abi(explicit);
        }

        cif
    }
}
