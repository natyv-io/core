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
    // SDL_ttf's public header only exposes opaque types (TTF_Font*,
    // TTF_Text*, TTF_TextEngine*, ...) -- FreeType's own headers never need
    // @cImport-ing at all, since FreeType is consumed entirely inside the
    // vendored SDL_ttf.c/FreeType .c sources (compiled as real C via
    // addCSourceFiles in build.zig), never crossing into this Zig-visible
    // header. See vendor/sdl_ttf/ and vendor/freetype/.
    @cInclude("SDL3_ttf/SDL_ttf.h");
    // stb_image, vendored the same way as Clay (single-header, declarations
    // translated here, real implementation compiled as C via addCSourceFile
    // in build.zig -- see vendor/stb/stb_image_impl.c). STBI_NO_STDIO must
    // match the same define there so the declaration and implementation
    // agree on which symbols exist (natyv only ever decodes in-memory
    // @embedFile'd bytes via stbi_load_from_memory, never a filesystem path).
    @cDefine("STBI_NO_STDIO", "1");
    @cInclude("stb_image.h");
});
