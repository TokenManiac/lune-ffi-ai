#![allow(clippy::cargo_common_metadata)]

use mlua::prelude::*;

mod call;
mod native;
mod types;

const MODULE_SOURCE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../packages/ffi/src/init.luau"
));
const TYPEDEFS: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/types.d.luau"));

#[must_use]
pub fn typedefs() -> String {
    TYPEDEFS.to_string()
}

pub fn module(lua: Lua) -> LuaResult<LuaTable> {
    let native = native::create(&lua)?;
    let chunk = lua.load(MODULE_SOURCE).set_name("@lune/ffi/init");
    chunk.call::<LuaTable>(native)
}
