const std = @import("std");

// Explicit manual override for Extism's install prefix -- `null` (the
// normal case) means "use the default: a real, per-target Extism static
// library fetched via Zig's own package manager" (see
// `extismDependencyName`/`linkNatyvDeps` below). This override exists for a
// dev who wants to point at a manually-installed Extism (e.g. testing an
// unreleased build) instead of the fetched, hash-pinned default.
fn extismPrefixOverride(b: *std.Build) ?[]const u8 {
    if (b.option([]const u8, "extism-prefix", "Path to the Extism install prefix (dir containing include/ and lib/) -- overrides the default fetched-package Extism")) |p| return p;
    if (b.graph.environ_map.get("NATYV_EXTISM_PREFIX")) |p| return p;
    return null;
}

// Maps a real build target to the matching per-target Extism dependency
// name declared in build.zig.zon (one real entry per target Extism's own
// v1.30.0 GitHub release publishes a prebuilt static lib for). Musl
// variants are deliberately not supported yet (demand-driven).
fn extismDependencyName(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .aarch64 => "extism_aarch64_macos",
            .x86_64 => "extism_x86_64_macos",
            else => std.process.fatal("natyv-core: no vendored Extism build for macos/{s}", .{@tagName(target.cpu.arch)}),
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => "extism_x86_64_linux_gnu",
            .aarch64 => "extism_aarch64_linux_gnu",
            else => std.process.fatal("natyv-core: no vendored Extism build for linux/{s}", .{@tagName(target.cpu.arch)}),
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => "extism_x86_64_windows_gnu",
            else => std.process.fatal("natyv-core: no vendored Extism build for windows/{s}", .{@tagName(target.cpu.arch)}),
        },
        else => std.process.fatal("natyv-core: no vendored Extism build for {s}", .{@tagName(target.os.tag)}),
    };
}

// Resolves both real Extism paths (header dir + static lib) a given target
// needs, from either an explicit override or the fetched default. `null`
// means a lazy dependency hasn't been fetched yet this pass; the build
// runner reruns configure once the fetch completes, matching Zig's
// standard `lazyDependency` idiom.
const ExtismPaths = struct { include: std.Build.LazyPath, lib: std.Build.LazyPath };
fn resolveExtism(b: *std.Build, target: std.Target, extism_prefix: ?[]const u8) ?ExtismPaths {
    if (extism_prefix) |prefix| {
        return .{
            .include = .{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) },
            .lib = .{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", "libextism.a" }) },
        };
    }
    const dep = b.lazyDependency(extismDependencyName(target), .{}) orelse return null;
    return .{ .include = dep.path("."), .lib = dep.path("libextism.a") };
}

// Links real Extism (+ whatever per-target unwind runtime its prebuilt
// static lib needs) into `module`.
fn linkExtism(b: *std.Build, module: *std.Build.Module, extism_prefix: ?[]const u8) void {
    module.link_libc = true;

    const target = module.resolved_target.?.result;
    if (resolveExtism(b, target, extism_prefix)) |extism| {
        module.addIncludePath(extism.include);
        module.addObjectFile(extism.lib);
    }

    // Windows-only Rust-runtime system libs, needed because Extism's real
    // prebuilt windows-gnu static lib is a genuine Rust std binary.
    if (target.os.tag == .windows) {
        module.linkSystemLibrary("ws2_32", .{});
        module.linkSystemLibrary("userenv", .{});
        module.linkSystemLibrary("bcrypt", .{});
        if (b.lazyDependency("llvm_mingw", .{})) |mingw_dep| {
            module.addObjectFile(mingw_dep.path("x86_64-w64-mingw32/lib/libunwind.a"));
        }
        module.addCSourceFile(.{ .file = b.path("vendor/mingw_compat/cfguard_dummy.c"), .flags = &.{} });
    }
    // Extism's real prebuilt linux-gnu static lib is, like windows-gnu's,
    // a genuine Rust std/GCC-targeted binary needing the real Itanium
    // `_Unwind_*`/`__register_frame` C++-ABI unwind API.
    if (target.os.tag == .linux) {
        module.linkSystemLibrary("unwind", .{});
    }
}

fn linkNatyvDeps(b: *std.Build, module: *std.Build.Module, extism_prefix: ?[]const u8, sqlite_enabled: bool) void {
    // SDL3, vendored via `allyourcodebase/SDL3` (real upstream source,
    // compiled -- and statically linked by default -- via Zig's own C
    // toolchain) rather than Homebrew's dynamic dylib.
    const sdl_dep = b.dependency("sdl", .{
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
    });
    module.linkLibrary(sdl_dep.artifact("SDL3"));

    linkExtism(b, module, extism_prefix);

    // mbedTLS (real vendored Mbed-TLS 3.6.6 via `allyourcodebase/mbedtls`,
    // pinned to a specific commit since the wrapper has no tagged releases
    // -- see MbedtlsSmokeTest.zig's own doc comment) -- backs the real TLS
    // handshake wrapper in Tls.zig, which TcpRegistry.zig now imports
    // unconditionally (a `Connection` can always potentially hold an active
    // TLS session), so this is a real, always-needed link for natyv-core
    // itself now, not just a standalone smoke test.
    const mbedtls_dep = b.dependency("mbedtls", .{
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
    });
    module.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    module.link_libc = true;

    // Vendored SQLite (the real, official amalgamation -- sqlite3.c/.h,
    // public domain). The header is always on the include path
    // (declarations alone need no linking), but the real implementation is
    // only compiled in when `sqlite_enabled` -- real build-time capability
    // stripping, matching `Runtime.zig`'s own comptime-gated calls.
    module.addIncludePath(b.path("vendor/sqlite3"));
    if (sqlite_enabled) {
        module.addCSourceFile(.{ .file = b.path("vendor/sqlite3/sqlite3.c"), .flags = &.{} });
    }

    // Clay is vendored (single C99 header, zlib license) -- declarations
    // translated via @cImport in src/c.zig, real implementation compiled
    // as C via vendor/clay/clay_impl.c.
    module.addIncludePath(b.path("vendor/clay"));
    module.addCSourceFile(.{
        .file = b.path("vendor/clay/clay_impl.c"),
        .flags = &.{},
    });

    // stb_image (public domain, single header) -- used for texture-fill
    // image decoding (PNG/JPEG/BMP/etc.). STBI_NO_STDIO (see
    // vendor/stb/stb_image_impl.c): natyv only ever decodes already-
    // embedded in-memory bytes, never a filesystem path at runtime.
    module.addIncludePath(b.path("vendor/stb"));
    module.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_image_impl.c"),
        .flags = &.{},
    });

    // FreeType, vendored and compiled as real C (never @cImport-ed -- see
    // src/c.zig). Hand-pruned to the modules natyv actually needs.
    module.addIncludePath(b.path("vendor/freetype/include"));
    module.addCSourceFiles(.{
        .root = b.path("vendor/freetype"),
        .files = &.{
            "src/autofit/autofit.c",
            "src/base/ftbase.c",
            "src/base/ftinit.c",
            "src/base/ftdebug.c",
            "src/base/ftsystem.c",
            "src/base/ftbitmap.c",
            "src/base/ftglyph.c",
            "src/base/ftstroke.c",
            "src/base/ftbbox.c",
            "src/base/ftsynth.c",
            "src/base/ftmm.c",
            "src/cff/cff.c",
            "src/psaux/psaux.c",
            "src/psnames/psnames.c",
            "src/pshinter/pshinter.c",
            "src/sfnt/sfnt.c",
            "src/smooth/smooth.c",
            "src/truetype/truetype.c",
        },
        .flags = &.{"-DFT2_BUILD_LIBRARY"},
    });

    // SDL_ttf, vendored the same way, compiled against the FreeType above.
    module.addIncludePath(b.path("vendor/sdl_ttf/include"));
    module.addCSourceFiles(.{
        .root = b.path("vendor/sdl_ttf"),
        .files = &.{
            "src/SDL_ttf.c",
            "src/SDL_hashtable.c",
            "src/SDL_hashtable_ttf.c",
            "src/SDL_renderer_textengine.c",
        },
        .flags = &.{
            "-DBUILD_SDL",
            "-DSDL_BUILD_MAJOR_VERSION=3",
            "-DSDL_BUILD_MINOR_VERSION=2",
            "-DSDL_BUILD_MICRO_VERSION=2",
        },
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const extism_prefix = extismPrefixOverride(b);

    // `Config` comes from natyv-io/shared now, not a local file -- both
    // natyv-core (this repo) and natyv-cli need the exact same
    // conf.natyv.json schema/parser, so it lives in one place both depend
    // on instead of each carrying a copy. `src/main.zig` reaches it via
    // the named import `Config` below (was a plain relative
    // `@import("Config.zig")` before the natyv-io repo split).
    const shared_dep = b.dependency("shared", .{ .target = target, .optimize = optimize });
    const config_mod = shared_dep.module("Config");

    // `natyv build`'s own bundling step (`-Dembed-app-wasm=true`): when
    // true, `src/main.zig` uses `EmbeddedWasmPresent.zig`'s
    // `@embedFile("embedded_app.wasm")` instead of loading `app_wasm` from
    // disk at runtime -- `natyv build` (natyv-io/cli) copies the dev's
    // freshly compiled guest wasm to `src/assets/embedded_app.wasm`
    // immediately before invoking this build.
    const embed_app_wasm = b.option(bool, "embed-app-wasm", "Embed src/assets/embedded_app.wasm into natyv-core at compile time instead of loading app_wasm from disk at runtime (set by `natyv build`, never by hand)") orelse false;
    // Real build-time-stripping: an app that never sets
    // `conf.natyv.json`'s `sqlite.enabled` shouldn't pay for sqlite3's own
    // real compiled size at all. Defaults true so a bare local `zig
    // build`/`zig build test` keeps behaving exactly as before.
    const sqlite_enabled = b.option(bool, "sqlite", "Compile in vendored SQLite support (default true for local dev/testing; `natyv build` passes this explicitly based on the app's own conf.natyv.json sqlite.enabled, so a real app that never uses SQLite doesn't pay for its compiled size)") orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "embed_app_wasm", embed_app_wasm);
    build_options.addOption(bool, "sqlite_enabled", sqlite_enabled);

    const embedded_wasm_mod = b.createModule(.{
        .root_source_file = b.path(if (embed_app_wasm) "src/assets/EmbeddedWasmPresent.zig" else "src/assets/EmbeddedWasmAbsent.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Texture-fill styling system: identical file-swap choreography to
    // `-Dembed-app-wasm` above -- `natyv prepare`'s asset-staging pass
    // (natyv-io/cli) writes a real `src/assets/TextureAssetsGenerated.zig`
    // whenever the app's stylesheet referenced at least one `texture`.
    const has_textures = b.option(bool, "has-textures", "Use src/assets/TextureAssetsGenerated.zig (written by `natyv prepare`) instead of the empty TextureAssetsAbsent.zig stub (set by `natyv build`, never by hand)") orelse false;
    const texture_assets_mod = b.createModule(.{
        .root_source_file = b.path(if (has_textures) "src/assets/TextureAssetsGenerated.zig" else "src/assets/TextureAssetsAbsent.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Binding generator: the identical file-swap choreography as
    // `-Dembed-app-wasm` above, just for a real Zig *source* file. `natyv
    // build` (natyv-io/cli) writes a real `src/BindingsGenerated.zig`
    // immediately before invoking this build whenever the app declared any
    // `bindings` entries.
    const has_bindings = b.option(bool, "has-bindings", "Use src/BindingsGenerated.zig (written by `natyv build`) instead of the empty BindingsAbsent.zig stub (set by `natyv build`, never by hand)") orelse false;
    const bindings_mod = b.createModule(.{
        .root_source_file = b.path(if (has_bindings) "src/BindingsGenerated.zig" else "src/BindingsAbsent.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `src/BindingsGenerated.zig`'s per-entry `@cInclude`s and real library
    // symbol calls need the exact same include/library paths and linker
    // flags natyv-io/cli's own scratch reflector compile already resolved
    // per `bindings` entry -- `natyv build` passes them through
    // comma-joined. Only `bindings_mod` needs these, since nothing else in
    // natyv-core touches a dev's arbitrary bound library.
    const binding_include_dirs = b.option([]const u8, "binding-include-dirs", "Comma-separated include dirs for src/BindingsGenerated.zig's @cInclude calls (set by `natyv build`, never by hand)") orelse "";
    const binding_lib_dirs = b.option([]const u8, "binding-lib-dirs", "Comma-separated library search paths for src/BindingsGenerated.zig's bound functions (set by `natyv build`, never by hand)") orelse "";
    const binding_link = b.option([]const u8, "binding-link", "Comma-separated system libraries to link for src/BindingsGenerated.zig's bound functions (set by `natyv build`, never by hand)") orelse "";
    bindings_mod.link_libc = true;
    // Needed unconditionally (not just when `has_bindings`) for
    // `src/bindgen/BindingsC.zig`'s own private `@cInclude("extism.h")` to
    // resolve -- the empty `BindingsAbsent.zig` stub doesn't reach it, but
    // adding the path regardless is simpler than conditioning on
    // `has_bindings` for a no-cost, always-correct include path.
    if (resolveExtism(b, bindings_mod.resolved_target.?.result, extism_prefix)) |extism| {
        bindings_mod.addIncludePath(extism.include);
    }
    var binding_include_dirs_it = std.mem.splitScalar(u8, binding_include_dirs, ',');
    while (binding_include_dirs_it.next()) |dir| {
        if (dir.len == 0) continue;
        bindings_mod.addIncludePath(.{ .cwd_relative = dir });
    }
    var binding_lib_dirs_it = std.mem.splitScalar(u8, binding_lib_dirs, ',');
    while (binding_lib_dirs_it.next()) |dir| {
        if (dir.len == 0) continue;
        bindings_mod.addLibraryPath(.{ .cwd_relative = dir });
    }
    var binding_link_it = std.mem.splitScalar(u8, binding_link, ',');
    while (binding_link_it.next()) |lib| {
        if (lib.len == 0) continue;
        bindings_mod.linkSystemLibrary(lib, .{});
    }

    // Stage 2.5 of the binding generator arc: a `-zig`-mode `bindings`
    // entry links via the fetched package's own build.zig instead of raw
    // include/lib flags. `natyv bind` (natyv-io/cli) already ran a real
    // `zig fetch --save=<name> <url>` against this exact source tree
    // before this build starts -- `b.dependency` panics if that hasn't
    // happened.
    const binding_zig_deps = b.option([]const u8, "binding-zig-deps", "Comma-separated name:artifact pairs for zig-package bindings fetched via `natyv get -zig=` (set by `natyv build`, never by hand)") orelse "";
    var binding_zig_deps_it = std.mem.splitScalar(u8, binding_zig_deps, ',');
    while (binding_zig_deps_it.next()) |pair| {
        if (pair.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, pair, ':') orelse continue;
        const dep_name = pair[0..colon];
        const artifact_name = pair[colon + 1 ..];
        const zig_dep = b.dependency(dep_name, .{ .target = target, .optimize = optimize });
        bindings_mod.linkLibrary(zig_dep.artifact(artifact_name));
    }

    // Stage 2.6 of the binding generator arc: a locally-vendored
    // `bindings` entry's tier-1 default compiles a real, flat list of
    // already-absolute `.c` file paths directly -- natyv-io/cli's own
    // `Bind.zig` already fetched and permanently vendored the real source
    // and resolved each `vendor_files` entry to an absolute path before
    // this build ever runs.
    const binding_vendor_c_files = b.option([]const u8, "binding-vendor-c-files", "Comma-separated absolute .c file paths for locally-vendored bindings (set by `natyv build`, never by hand)") orelse "";
    var binding_vendor_c_files_it = std.mem.splitScalar(u8, binding_vendor_c_files, ',');
    while (binding_vendor_c_files_it.next()) |file| {
        if (file.len == 0) continue;
        bindings_mod.addCSourceFile(.{ .file = .{ .cwd_relative = file }, .flags = &.{} });
    }

    // The app runtime -- what a compiled app actually ships as, and what
    // `natyv build` bundles a dev's compiled guest wasm into as one
    // self-contained distributable binary.
    const exe = b.addExecutable(.{
        .name = "natyv-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkNatyvDeps(b, exe.root_module, extism_prefix, sqlite_enabled);
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("Config", config_mod);
    exe.root_module.addImport("EmbeddedWasm", embedded_wasm_mod);
    exe.root_module.addImport("Bindings", bindings_mod);
    exe.root_module.addImport("TextureAssets", texture_assets_mod);

    // Windows icon embedding (`Config.icon`): natyv-io/cli's
    // `WindowsIcon.zig` generates a real `.ico` + a small `.rc`
    // referencing it *before* this build ever runs, then `natyv build`
    // passes the `.rc`'s absolute path here. `addWin32ResourceFile` is
    // safe to call unconditionally on every target -- Zig's own
    // std.Build ignores it outright for any non-PE/COFF target.
    if (b.option([]const u8, "windows-icon-rc", "Absolute path to a generated .rc file to embed as the exe's icon resource (set by `natyv build`, never by hand)")) |rc_path| {
        exe.root_module.addWin32ResourceFile(.{ .file = .{ .cwd_relative = rc_path } });
    }

    // A dedicated `install-core` step rather than the plain
    // `b.installArtifact(exe)` sugar -- `natyv build`'s own bundling step
    // needs to install *only* natyv-core into a fresh `--prefix`.
    const install_core = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_core.step);
    const install_core_step = b.step("install-core", "Install natyv-core -- used by `natyv build`'s own bundling step");
    install_core_step.dependOn(&install_core.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run natyv-core (the app runtime) directly, for local dev/testing");
    run_step.dependOn(&run_cmd.step);

    const manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/Manifest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_manifest_tests = b.addRunArtifact(manifest_tests);

    const sqlite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/Sqlite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkNatyvDeps(b, sqlite_tests.root_module, extism_prefix, sqlite_enabled);
    const run_sqlite_tests = b.addRunArtifact(sqlite_tests);

    const windowmanager_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/WindowManager.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkNatyvDeps(b, windowmanager_tests.root_module, extism_prefix, sqlite_enabled);
    const run_windowmanager_tests = b.addRunArtifact(windowmanager_tests);

    const runtime_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/Runtime.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkNatyvDeps(b, runtime_tests.root_module, extism_prefix, sqlite_enabled);
    runtime_tests.root_module.addImport("Config", config_mod);
    runtime_tests.root_module.addImport("Bindings", bindings_mod);
    runtime_tests.root_module.addImport("EmbeddedWasm", embedded_wasm_mod);
    runtime_tests.root_module.addOptions("build_options", build_options);
    const run_runtime_tests = b.addRunArtifact(runtime_tests);
    run_runtime_tests.setCwd(b.path("."));

    // `src/RuntimeTest.zig` (real-guest round-trip tests against compiled
    // example .wasm files) is deliberately NOT wired into this repo's own
    // `test` step -- those examples live in natyv-io/natyv, not here, so
    // this file's tests can't run standalone post-split. Kept as a real,
    // tracked source file (full history preserved) for a future
    // natyv-io/integration-tests-style repo to pull in alongside real wasm
    // fixtures, per Quinn's own call (2026-08-29) when this gap was found.

    const private_ranges_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/PrivateRanges.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_private_ranges_tests = b.addRunArtifact(private_ranges_tests);

    const mbedtls_dep = b.dependency("mbedtls", .{
        .target = target,
        .optimize = optimize,
    });

    const tcp_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/TcpRegistry.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tcp_registry_tests.root_module.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    tcp_registry_tests.root_module.addImport("Config", config_mod);
    const run_tcp_registry_tests = b.addRunArtifact(tcp_registry_tests);

    const mbedtls_smoke_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/MbedtlsSmokeTest.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mbedtls_smoke_tests.root_module.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    const run_mbedtls_smoke_tests = b.addRunArtifact(mbedtls_smoke_tests);

    const tcp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/Tcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tcp_tests.root_module.addImport("Config", config_mod);
    const run_tcp_tests = b.addRunArtifact(tcp_tests);

    const tls_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/Tls.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tls_tests.root_module.linkLibrary(mbedtls_dep.artifact("mbedtls"));
    const run_tls_tests = b.addRunArtifact(tls_tests);

    const persist_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/PersistStore.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_persist_tests = b.addRunArtifact(persist_tests);

    const drawbatcher_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/DrawBatcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkNatyvDeps(b, drawbatcher_tests.root_module, extism_prefix, sqlite_enabled);
    const run_drawbatcher_tests = b.addRunArtifact(drawbatcher_tests);

    const scrollclip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ScrollClip.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkNatyvDeps(b, scrollclip_tests.root_module, extism_prefix, sqlite_enabled);
    const run_scrollclip_tests = b.addRunArtifact(scrollclip_tests);

    const scrollbar_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ScrollBar.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkNatyvDeps(b, scrollbar_tests.root_module, extism_prefix, sqlite_enabled);
    const run_scrollbar_tests = b.addRunArtifact(scrollbar_tests);

    const eventqueue_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/EventQueue.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkNatyvDeps(b, eventqueue_tests.root_module, extism_prefix, sqlite_enabled);
    const run_eventqueue_tests = b.addRunArtifact(eventqueue_tests);

    const floatingorder_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/FloatingOrder.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkNatyvDeps(b, floatingorder_tests.root_module, extism_prefix, sqlite_enabled);
    const run_floatingorder_tests = b.addRunArtifact(floatingorder_tests);

    const bindgen_handle_table_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bindgen/HandleTable.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_bindgen_handle_table_tests = b.addRunArtifact(bindgen_handle_table_tests);

    // Drift-protection: `BindingsHostFnUtil.zig`/`host_fn_util.zig` are
    // deliberate, hand-kept-in-sync duplicates (`Bindings` is a genuinely
    // separate Zig module from natyv-core's own `root` module and can't
    // relatively reach back into files `root` already claims) -- this
    // test asserts they stay byte-for-byte identical.
    const bindings_host_fn_util_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bindgen/BindingsHostFnUtil.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (resolveExtism(b, bindings_host_fn_util_tests.root_module.resolved_target.?.result, extism_prefix)) |extism| {
        bindings_host_fn_util_tests.root_module.addIncludePath(extism.include);
    }
    const run_bindings_host_fn_util_tests = b.addRunArtifact(bindings_host_fn_util_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_manifest_tests.step);
    test_step.dependOn(&run_sqlite_tests.step);
    test_step.dependOn(&run_windowmanager_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_private_ranges_tests.step);
    test_step.dependOn(&run_tcp_registry_tests.step);
    test_step.dependOn(&run_mbedtls_smoke_tests.step);
    test_step.dependOn(&run_tcp_tests.step);
    test_step.dependOn(&run_tls_tests.step);
    test_step.dependOn(&run_persist_tests.step);
    test_step.dependOn(&run_drawbatcher_tests.step);
    test_step.dependOn(&run_scrollclip_tests.step);
    test_step.dependOn(&run_scrollbar_tests.step);
    test_step.dependOn(&run_eventqueue_tests.step);
    test_step.dependOn(&run_floatingorder_tests.step);
    test_step.dependOn(&run_bindgen_handle_table_tests.step);
    test_step.dependOn(&run_bindings_host_fn_util_tests.step);
}
