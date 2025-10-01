use std::fs;
use std::io::{self, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use mlua::prelude::*;

fn detect_target_triple() -> String {
    option_env!("TARGET")
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
        })
}

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
    let target = detect_target_triple();
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

fn build_libcpr_library(repo_root: &Path) -> LuaResult<PathBuf> {
    let source_dir = repo_root
        .join("packages")
        .join("ffi")
        .join("examples")
        .join("native")
        .join("libcpr");
    let vendor_dir = source_dir.join("vendor");

    let build_dir = repo_root.join("target").join("ffi-libcpr");
    fs::create_dir_all(&build_dir).map_err(|err| {
        LuaError::external(format!(
            "failed to create libcpr build directory {build_dir:?}: {err}"
        ))
    })?;

    let curl_lib = pkg_config::Config::new()
        .cargo_metadata(false)
        .probe("libcurl")
        .map_err(|err| {
            LuaError::external(format!("failed to locate libcurl with pkg-config: {err}"))
        })?;

    let mut build = cc::Build::new();
    build.cpp(true);
    build.flag_if_supported("-std=c++17");
    build.flag_if_supported("-fPIC");
    build.opt_level(0);
    build.include(vendor_dir.join("include"));
    build.include(vendor_dir.join("cpr"));
    for include in &curl_lib.include_paths {
        build.include(include);
    }

    build.file(source_dir.join("libcpr_ffi.cpp"));

    let cpr_sources = [
        "accept_encoding.cpp",
        "async.cpp",
        "auth.cpp",
        "callback.cpp",
        "cert_info.cpp",
        "connection_pool.cpp",
        "cookies.cpp",
        "cprtypes.cpp",
        "curl_container.cpp",
        "curlholder.cpp",
        "curlmultiholder.cpp",
        "error.cpp",
        "file.cpp",
        "interceptor.cpp",
        "multipart.cpp",
        "multiperform.cpp",
        "parameters.cpp",
        "payload.cpp",
        "proxies.cpp",
        "proxyauth.cpp",
        "redirect.cpp",
        "response.cpp",
        "session.cpp",
        "ssl_ctx.cpp",
        "threadpool.cpp",
        "timeout.cpp",
        "unix_socket.cpp",
        "util.cpp",
    ];

    for source in &cpr_sources {
        build.file(vendor_dir.join("cpr").join(source));
    }

    let target = detect_target_triple();
    build.target(&target);
    unsafe {
        std::env::set_var("TARGET", &target);
        std::env::set_var("OPT_LEVEL", "0");
        std::env::set_var("HOST", &target);
    }

    let objects = build.compile_intermediates();
    let compiler = build.get_compiler();

    let lib_name = if cfg!(target_os = "windows") {
        "cpr_ffi.dll"
    } else if cfg!(target_os = "macos") {
        "libcpr_ffi.dylib"
    } else {
        "libcpr_ffi.so"
    };

    let lib_path = build_dir.join(lib_name);
    if lib_path.exists() {
        fs::remove_file(&lib_path).map_err(|err| {
            LuaError::external(format!(
                "failed to remove previous libcpr library {lib_path:?}: {err}"
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
        for link_path in &curl_lib.link_paths {
            cmd.arg(format!("/LIBPATH:{}", link_path.display()));
        }
        for lib in &curl_lib.libs {
            cmd.arg(format!("{lib}.lib"));
        }
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
        for link_path in &curl_lib.link_paths {
            cmd.arg("-L");
            cmd.arg(link_path);
        }
        for lib in &curl_lib.libs {
            cmd.arg(format!("-l{lib}"));
        }
        for framework_path in &curl_lib.framework_paths {
            cmd.arg("-F");
            cmd.arg(framework_path);
        }
        for framework in &curl_lib.frameworks {
            cmd.arg("-framework");
            cmd.arg(framework);
        }
    }

    let command_display = format!("{cmd:?}");
    let status = cmd.status().map_err(|err| {
        LuaError::external(format!(
            "failed to invoke compiler for libcpr library ({command_display}): {err}"
        ))
    })?;

    if !status.success() {
        return Err(LuaError::external(format!(
            "libcpr library build failed with status {status} using {command_display}"
        )));
    }

    Ok(lib_path)
}

fn spawn_libcpr_test_server() -> LuaResult<(String, String, thread::JoinHandle<()>)> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|err| LuaError::external(format!("failed to bind libcpr test server: {err}")))?;
    listener.set_nonblocking(true).map_err(|err| {
        LuaError::external(format!("failed to configure libcpr test server: {err}"))
    })?;

    let address = listener.local_addr().map_err(|err| {
        LuaError::external(format!("failed to read libcpr test server address: {err}"))
    })?;

    let body = "Hello from libcpr";
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let response_bytes = response.into_bytes();

    let handle = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut served = 0;
        while served < 2 {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let mut buffer = [0u8; 1024];
                    let _ = stream.read(&mut buffer);
                    let _ = stream.write_all(&response_bytes);
                    let _ = stream.flush();
                    served += 1;
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        break;
                    }
                    thread::sleep(Duration::from_millis(50));
                }
                Err(_) => break,
            }
        }
    });

    Ok((format!("http://{address}"), body.to_string(), handle))
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
    let libcpr_library = build_libcpr_library(&repo_root)?;
    let (libcpr_url, libcpr_body, libcpr_server) = spawn_libcpr_test_server()?;

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
    lua.globals().set(
        "FFI_LIBCPR_LIBRARY_PATH",
        libcpr_library.to_string_lossy().to_string(),
    )?;
    lua.globals()
        .set("FFI_LIBCPR_TEST_URL", libcpr_url.clone())?;
    lua.globals()
        .set("FFI_LIBCPR_EXPECTED_BODY", libcpr_body.clone())?;
    lua.globals().set(
        "LIBCPR_LIBRARY_PATH",
        libcpr_library.to_string_lossy().to_string(),
    )?;
    lua.globals()
        .set("LIBCPR_EXAMPLE_URL", libcpr_url.clone())?;

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
    register_script_module(
        &lua,
        &preload,
        "./libcpr_spec",
        &repo_root.join("packages/ffi/tests/libcpr_spec.luau"),
    )?;
    register_script_module(
        &lua,
        &preload,
        "../examples/libcpr_get",
        &repo_root.join("packages/ffi/examples/libcpr_get.luau"),
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

    let exec_result = lua
        .load(&script)
        .set_name("packages/ffi/tests/_runner.luau")
        .exec();

    libcpr_server
        .join()
        .map_err(|err| LuaError::external(format!("libcpr test server panicked: {err:?}")))?;

    exec_result?;

    Ok(())
}
