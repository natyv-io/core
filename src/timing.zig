const std = @import("std");
const c = @import("c.zig").c;

/// Plain elapsed-time instrumentation (frame timing, dispatch latency
/// logging) -- not a blocking or cancelable operation, so it doesn't need to
/// route through std.Io the way sleeping/blocking calls elsewhere now do.
pub fn nowMs() i64 {
    return @intCast(c.SDL_GetTicks());
}

/// Startup-phase tracing, off unless `NATYV_STARTUP_TRACE` is set in the
/// environment (any value). A runtime env var rather than a build option
/// deliberately: the situation you actually want this in is "a real,
/// already-bundled `.app` starts slowly on someone's machine," where
/// rebuilding with a `-D` flag isn't available. Costs one env lookup at
/// startup when off.
///
/// File-level mutable state for the same reason `Logging.zig`'s `dest`
/// is: `Runtime.loadPlugin` also traces, and threading a bool through its
/// signature (and every call site) to carry a diagnostic would be worse
/// than the global.
pub var trace_enabled: bool = false;

/// `nowMs` above is SDL_GetTicks, whole-millisecond resolution -- too
/// coarse to separate a 2ms phase from a 20ms one, which is exactly the
/// distinction startup tracing exists to make.
pub fn traceStart() u64 {
    return c.SDL_GetPerformanceCounter();
}

pub fn traceMs(start: u64) f64 {
    const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());
    const ticks: f64 = @floatFromInt(c.SDL_GetPerformanceCounter() - start);
    return ticks / freq * 1000.0;
}

/// One aligned `[trace] <label> : <n> ms` line, or nothing when tracing is
/// off. Deliberately goes to stderr rather than through `Logging`: the
/// first phase traced (SDL_Init) runs before `Logging.init` exists.
pub fn tracePhase(label: []const u8, start: u64) void {
    if (!trace_enabled) return;
    std.debug.print("[trace] {s:<38}: {d:.2} ms\n", .{ label, traceMs(start) });
}

/// A free-form trace line (headers, sizes, separators), same gating.
pub fn traceNote(comptime fmt: []const u8, args: anytype) void {
    if (!trace_enabled) return;
    std.debug.print("[trace] " ++ fmt, args);
}
