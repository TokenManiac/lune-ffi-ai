use std::fs;
use std::path::{Path, PathBuf};

use mlua::prelude::*;

fn build_example_library(repo_root: &Path) -> LuaResult<PathBuf> {
    let example_source = repo_root
        .join("packages")
        .join("ffi")
        .join("examples")
        .join("native")
        .join("example.c");

    let build_dir = repo_root.join("target").join("ffi-example");
    fs::create_dir_all(&build_dir).map_err(|err| {
        LuaError::external(format!(
            "failed to create ffi example build directory {build_dir:?}: {err}"
        ))
    })?;

    let mut build = cc::Build::new();
    build.file(&example_source);
    build.flag_if_supported("-fPIC");
    build.opt_level(0);
    let target = option_env!("TARGET")
        .map(str::to_owned)
        .or_else(|| std::env::var("TARGET").ok())
        .or_else(|| option_env!("HOST").map(str::to_owned))
        .or_else(|| std::env::var("HOST").ok())
        .unwrap_or_else(|| {
            let arch = std::env::consts::ARCH;
            if cfg!(target_os = "windows") {
                format!("{arch}-pc-windows-msvc")
            } else if cfg!(target_os = "macos") {
                format!("{arch}-apple-darwin")
            } else if cfg!(target_os = "linux") {
                format!("{arch}-unknown-linux-gnu")
            } else {
                arch.to_string()
            }
        });
    build.target(&target);
    unsafe {
        std::env::set_var("TARGET", &target);
        std::env::set_var("OPT_LEVEL", "0");
        std::env::set_var("HOST", &target);
    }

    let objects = build.compile_intermediates();
    let compiler = build.get_compiler();

    let lib_name = if cfg!(target_os = "windows") {
        "example.dll"
    } else if cfg!(target_os = "macos") {
        "libexample.dylib"
    } else {
        "libexample.so"
    };

    let lib_path = build_dir.join(lib_name);
    if lib_path.exists() {
        fs::remove_file(&lib_path).map_err(|err| {
            LuaError::external(format!(
                "failed to remove previous ffi example library {lib_path:?}: {err}"
            ))
        })?;
    }

    let mut cmd = compiler.to_command();

    if compiler.is_like_msvc() {
        for object in &objects {
            cmd.arg(object);
        }
        cmd.arg("/LD");
        cmd.arg(format!("/Fe{}", lib_path.display()));
    } else {
        if cfg!(target_os = "macos") {
            cmd.arg("-dynamiclib");
        } else {
            cmd.arg("-shared");
        }
        cmd.arg("-o");
        cmd.arg(&lib_path);
        for object in &objects {
            cmd.arg(object);
        }
    }

    let command_display = format!("{cmd:?}");
    let status = cmd.status().map_err(|err| {
        LuaError::external(format!(
            "failed to invoke compiler for ffi example library ({command_display}): {err}"
        ))
    })?;

    if !status.success() {
        return Err(LuaError::external(format!(
            "ffi example library build failed with status {status} using {command_display}"
        )));
    }

    Ok(lib_path)
}

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
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..");
    let example_library = build_example_library(&repo_root)?;

    let lua = Lua::new();
    let module = lune_std_ffi::module(lua.clone())?;

    let preload = lua.create_table()?;

    let module_key = lua.create_registry_value(module)?;
    let module_loader = lua.create_function(move |lua, ()| {
        let module: LuaTable = lua.registry_value(&module_key)?;
        Ok(module)
    })?;
    preload.set("@lune/ffi", module_loader)?;

    lua.globals().set(
        "FFI_EXAMPLE_LIBRARY_PATH",
        example_library.to_string_lossy().to_string(),
    )?;

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
    register_script_module(
        &lua,
        &preload,
        "./example_spec",
        &repo_root.join("packages/ffi/tests/example_spec.luau"),
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

    Ok(())
}
