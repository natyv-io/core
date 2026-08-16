// Compiles Clay's actual implementation as real C (via Zig's bundled clang,
// through build.zig's addCSourceFile) rather than through Zig's translate-c
// -- see the comment in src/c.zig for why the implementation specifically
// can't go through @cImport. This file's only job is to define
// CLAY_IMPLEMENTATION exactly once and include clay.h; all the real code
// lives in the vendored header.
#define CLAY_IMPLEMENTATION
#define CLAY_DISABLE_SIMD
#include "clay.h"
