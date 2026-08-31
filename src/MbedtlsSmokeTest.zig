//! Real vendoring/build/link smoke test for `allyourcodebase/mbedtls`
//! (pinned commit `55f2af1`, wraps upstream Mbed-TLS 3.6.6) -- confirmed
//! yesterday as the TLS backend for the planned TCP/TLS host function (see
//! `natyv-tcp-tls-host-function` memory), but the wrapper itself is thin
//! (16 commits, 5 stars) so it needed a real link+call test before being
//! trusted, same discipline already applied to every other dependency this
//! project vendors (SDL3, Extism).
//!
//! Deliberately a standalone file with its own isolated `@cImport`, not
//! folded into the shared `c.zig` boundary yet -- today's job is proving
//! the fetch/link mechanics work at all, not deciding how the eventual real
//! TLS backend code will reference mbedTLS types. That's real, separate
//! design work for when the backend interface (connect/upgrade/read/write/
//! close) actually gets built.

const std = @import("std");

const c = @cImport({
    @cInclude("mbedtls/version.h");
});

test "mbedtls actually links and reports the exact pinned version" {
    var buf: [32]u8 = undefined;
    c.mbedtls_version_get_string(&buf);
    const version = std.mem.sliceTo(&buf, 0);
    try std.testing.expectEqualStrings("3.6.6", version);
}
