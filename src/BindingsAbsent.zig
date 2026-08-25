//! The default counterpart to a real, `natyv bind`-generated
//! `BindingsGenerated.zig` (Stage 2.2 of
//! ~/.claude/plans/lexical-wishing-penguin.md) -- used for every normal
//! `zig build`/`zig build run` invocation (`-Dhas-bindings` unset or
//! false), so a real dev build never needs any app's generated bindings
//! to exist on disk at all. Mirrors `src/assets/EmbeddedWasmAbsent.zig`'s
//! own exact role for `-Dembed-app-wasm`.
//!
//! `registerInto` takes `[]?*anyopaque`, not `[]?*const c.ExtismFunction`,
//! **on purpose** -- `Bindings` is a separately-`addImport`ed module
//! (build.zig swaps which file backs it, the same way `EmbeddedWasm`
//! does), so its own `c.zig` is a distinct translate-c instantiation from
//! `Runtime.zig`'s -- two `@cImport`s over the same header always produce
//! two incompatible Zig types (confirmed repeatedly earlier in this same
//! arc, see `Reflect.zig`'s own doc comment). Since `ExtismFunction` is
//! opaque on both sides and never actually dereferenced by natyv itself
//! (only handed back to Extism's own C API), a plain `@ptrCast` between
//! the two nominal types is completely safe -- confirmed directly against
//! Zig 0.16's real slice-pointer-cast semantics -- and sidesteps the
//! entire problem without needing to promote `c.zig` to a shared named
//! module across every one of the ~20 existing files that already reach
//! it via an ordinary relative import.
pub const host_function_count = 0;

pub fn registerInto(funcs_out: []?*anyopaque) usize {
    _ = funcs_out;
    return 0;
}
