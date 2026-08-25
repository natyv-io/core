//! `Bindings`' own private `@cImport` of Extism's C API -- deliberately
//! NOT a relative import of the shared `src/c.zig` (see that file's own
//! doc comment on why a second `@cImport` of the same header is normally
//! avoided in this codebase). A real, previously-unnoticed blocker found
//! while building Stage 2.2's own end-to-end proof (a real zlib binding,
//! ~/.claude/plans/lexical-wishing-penguin.md): `src/BindingsGenerated.zig`
//! is compiled as a genuinely separate Zig module (the `-Dhas-bindings`
//! file-swap mechanism in `build.zig`, so a normal dev build never needs
//! it to exist), and Zig hard-errors ("file exists in modules 'root' and
//! 'Bindings'") the moment two different modules both reach the same
//! physical file -- `src/c.zig` is already part of the real natyv-core
//! `root` module (via `WidgetHost.zig`/`WidgetHostFunctions.zig`/
//! `Sqlite.zig`'s own relative imports of it), so `Bindings`' generated
//! code can never relatively import it too. Promoting `c.zig` itself to a
//! shared named module was considered and rejected as too large for this
//! stage (it's relatively imported by ~20 existing files); this file is
//! the much smaller fix -- Extism's own C ABI types
//! (`ExtismCurrentPlugin`/`ExtismVal`/`ExtismFunction`/etc.) are stable,
//! external, and never need to cross between this module and `root`'s own
//! `c.zig` instance directly. The one place that could have mattered --
//! `Runtime.zig`'s host-function array -- already sidesteps the "two
//! `@cImport`s of the same header produce incompatible types" problem via
//! `[]?*anyopaque` + `@ptrCast` (`ExtismFunction` is opaque on both sides
//! and never dereferenced by natyv itself, only handed back to Extism's
//! own C API), so a second, independent instantiation here is safe.
pub const c = @cImport({
    @cInclude("extism.h");
});
