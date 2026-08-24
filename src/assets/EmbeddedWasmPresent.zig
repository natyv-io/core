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

pub const bytes: []const u8 = @embedFile("embedded_app.wasm");
