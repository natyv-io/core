/// Single shared @cImport boundary. Every file that needs SDL or Extism C
/// types imports this file rather than declaring its own @cImport -- Zig
/// treats each @cImport call site as a distinct type, so two independent
/// imports of the same header would produce incompatible types for what's
/// conceptually the same struct. Mirrors the pattern used by the Extism Zig
/// SDK's own ffi.zig.
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("extism.h");
    @cInclude("sqlite3.h");
});
