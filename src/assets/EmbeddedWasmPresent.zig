//! `.ntx` tooling Stage 7's `natyv build` bundling step: this file only
//! ever gets compiled when `zig build -Dembed-app-wasm=true` is passed
//! (see build.zig's conditional `embedded_wasm_mod`) -- `natyv build`
//! copies the dev's freshly-compiled guest wasm to
//! `embedded_app.wasm` (this same directory) immediately before invoking
//! that build. A real, ordinary Zig source file's `@embedFile` call is
//! evaluated unconditionally the moment it's analyzed, so keeping this in
//! its own file (swapped in for `EmbeddedWasmAbsent.zig` entirely by
//! build.zig, rather than a runtime/comptime `if` inside one shared file)
//! is what lets a normal dev build never need `embedded_app.wasm` to
//! exist at all.
//!
//! `config_bytes` (added 2026-08-26, the app-icon work): a real, distinct
//! `.app` bundle has no reliable notion of "current working directory" at
//! all -- Finder/Launch Services never sets it to the bundle's own
//! directory, confirmed the hard way when the first real macOS `.app`
//! built by this project's own new bundling step failed to launch (its
//! previously-cwd-relative `conf.natyv.json` read hit `FileNotFound`).
//! Embedding the app's own config the same way `bytes` above already
//! embeds its wasm makes a bundled binary genuinely self-contained
//! regardless of launch method (Finder double-click, Dock, `open`, a
//! bare Terminal invocation from any directory) -- `Bundle.zig` copies
//! the dev's real `conf.natyv.json` to `embedded_config.json` (this same
//! directory) in the same step it already copies the wasm.

pub const bytes: []const u8 = @embedFile("embedded_app.wasm");
pub const config_bytes: []const u8 = @embedFile("embedded_config.json");
