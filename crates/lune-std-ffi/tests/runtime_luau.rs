use std::fs;
use std::path::{Path, PathBuf};

use mlua::prelude::*;

fn register_script_module(lua: &Lua, preload: &LuaTable, name: &str, path: &Path) -> LuaResult<()> {
    let source = fs::read_to_string(path)
        .map_err(|err| LuaError::external(format!("failed to read {path:?}: {err}")))?;
    let chunk_name = path.display().to_string();
    let loader = lua.create_function(move |lua, ()| {
        lua.load(&source).set_name(&chunk_name).call::<LuaValue>(())
    })?;
    preload.set(name, loader)
}

#[test]
fn runtime_spec_passes() -> LuaResult<()> {
    let lua = Lua::new();
    let module = lune_std_ffi::module(lua.clone())?;

    let preload = lua.create_table()?;

    let module_key = lua.create_registry_value(module)?;
    let module_loader = lua.create_function(move |lua, ()| {
        let module: LuaTable = lua.registry_value(&module_key)?;
        Ok(module)
    })?;
    preload.set("@lune/ffi", module_loader)?;

    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..");
    register_script_module(
        &lua,
        &preload,
        "./cdef_spec",
        &repo_root.join("packages/ffi/tests/cdef_spec.luau"),
    )?;
    register_script_module(
        &lua,
        &preload,
        "./runtime_spec",
        &repo_root.join("packages/ffi/tests/runtime_spec.luau"),
    )?;

    lua.load(
        r#"
local preload = ...
local loaded = {}

function require(name)
    if loaded[name] ~= nil then
        return loaded[name]
    end

    local loader = preload[name]
    if loader == nil then
        error(string.format("module '%s' not found", tostring(name)), 2)
    end

    local result = loader()
    loaded[name] = result
    return result
end
"#,
    )
    .set_name("ffi/test_bootstrap")
    .call::<()>(preload.clone())?;

    let runner_path = repo_root
        .join("packages")
        .join("ffi")
        .join("tests")
        .join("_runner.luau");
    let script = fs::read_to_string(&runner_path)
        .map_err(|err| LuaError::external(format!("failed to read {runner_path:?}: {err}")))?;

    lua.load(&script)
        .set_name("packages/ffi/tests/_runner.luau")
        .exec()?;

    lua.gc_stop();
    std::mem::forget(lua);
    Ok(())
}
