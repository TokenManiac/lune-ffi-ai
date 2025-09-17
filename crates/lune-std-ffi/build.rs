use std::env;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("manifest dir"));
    let native_dir = manifest_dir
        .join("..").join("..")
        .join("packages").join("ffi").join("native");

    println!("cargo:rerun-if-changed={}", native_dir.join("luneffi_loader.h").display());
    println!("cargo:rerun-if-changed={}", native_dir.join("luneffi_loader_posix.c").display());
    println!("cargo:rerun-if-changed={}", native_dir.join("luneffi_loader_windows.c").display());

    let mut build = cc::Build::new();
    build.include(&native_dir);

    if cfg!(target_os = "windows") {
        build.file(native_dir.join("luneffi_loader_windows.c"));
        build.define("UNICODE", None);
        build.define("_UNICODE", None);
    } else {
        build.file(native_dir.join("luneffi_loader_posix.c"));
        build.flag_if_supported("-fvisibility=hidden");
        build.flag_if_supported("-fno-common");
    }

    build.compile("luneffi_loader");
}
