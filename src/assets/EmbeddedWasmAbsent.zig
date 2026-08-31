//! The default counterpart to `EmbeddedWasmPresent.zig` -- used for every
//! normal `zig build`/`zig build run` invocation (`-Dembed-app-wasm` unset
//! or false), so a real dev build never needs `embedded_app.wasm` to
//! exist on disk at all.

pub const bytes: []const u8 = &.{};
pub const config_bytes: []const u8 = &.{};
pub const ca_certs_bytes: []const u8 = &.{};
