// Compiles stb_image's actual implementation as real C (via Zig's bundled
// clang, through build.zig's addCSourceFile) rather than through Zig's
// translate-c -- mirrors vendor/clay/clay_impl.c exactly, same reasoning:
// only the public declarations need translating (src/c.zig's @cImport),
// the real implementation is compiled separately and linked in.
//
// STBI_NO_STDIO: natyv only ever decodes already-embedded (`@embedFile`d)
// in-memory bytes via stbi_load_from_memory, never a filesystem path at
// runtime -- matches natyv's own closed-input-surface convention (never
// accept a raw path from untrusted guest input) and trims the filename-
// based STDIO code path entirely. Must match the same define in src/c.zig's
// @cImport so the declaration and implementation agree on which symbols
// exist.
#define STBI_NO_STDIO
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
