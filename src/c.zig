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
    // Deliberately NOT defining CLAY_IMPLEMENTATION here -- Clay's internal
    // implementation types/functions (hash map internals, debug-view state)
    // use C patterns (bitfields, anonymous structs) that crashed or failed
    // Zig's translate-c when included via @cImport. Only the public header
    // declarations need translating (extern function signatures + public
    // structs, same as SDL3/Extism/sqlite3 above); the actual implementation
    // is compiled as real C via addCSourceFile in build.zig and linked in,
    // never passed through translate-c at all. See vendor/clay/clay_impl.c.
    //
    // Zig's translate-c also segfaults on clay.h's arm_neon.h SIMD include
    // on aarch64 -- sidestepped via Clay's own CLAY_DISABLE_SIMD escape
    // hatch (matched by the same define in clay_impl.c's actual compile).
    @cDefine("CLAY_DISABLE_SIMD", "1");
    @cInclude("clay.h");
});
