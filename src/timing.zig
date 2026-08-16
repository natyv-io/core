const c = @import("c.zig").c;

/// Plain elapsed-time instrumentation (frame timing, dispatch latency
/// logging) -- not a blocking or cancelable operation, so it doesn't need to
/// route through std.Io the way sleeping/blocking calls elsewhere now do.
pub fn nowMs() i64 {
    return @intCast(c.SDL_GetTicks());
}
