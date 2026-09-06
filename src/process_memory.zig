const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Current resident set size of this process, in bytes -- the same number
/// `ps`/Activity Monitor/Task Manager report, not a guest-side heap
/// estimate. Backs the recycle mechanism's real memory-threshold trigger
/// (see Dispatch.zig) -- cheap enough (a single syscall or a small
/// kernel-generated file read) to call on every dispatch.
///
/// `builtin.os.tag` is comptime-known -- natyv-core is always compiled
/// per-target, never one binary that runs anywhere and detects itself at
/// runtime (see core/CLAUDE.md's cross-compilation notes) -- so this switch
/// is resolved during semantic analysis, not at runtime: whichever branches
/// don't match the platform actually being compiled are never even
/// type-checked, exactly like `std/c.zig`'s own `getrusage`/`rusage`
/// switches on `native_os`.
pub fn residentSetSizeBytes(io: Io) !u64 {
    return switch (builtin.os.tag) {
        .macos => macosRss(),
        .linux => linuxRss(io),
        .windows => windowsRss(),
        else => error.UnsupportedPlatform,
    };
}

/// Real, live-verified (2026-09-06): a scratch program confirmed
/// `resident_size` matches a real +100MB allocation almost exactly.
fn macosRss() !u64 {
    var info: std.c.mach_task_basic_info = undefined;
    var count: std.c.mach_msg_type_number_t = std.c.MACH.TASK.BASIC.INFO_COUNT;
    const result = std.c.task_info(
        std.c.mach_task_self(),
        std.c.MACH.TASK.BASIC.INFO,
        @ptrCast(&info),
        &count,
    );
    if (result != 0) return error.TaskInfoFailed;
    return info.resident_size;
}

/// VmRSS is already reported in kB by the kernel -- no page-size lookup
/// needed. Deliberately not getrusage()'s ru_maxrss: that field is a peak
/// high-water mark on Linux, never decreasing even after a real recycle
/// actually frees memory -- comparing a threshold against it would recycle
/// once and then look permanently "still over threshold" on every dispatch
/// after, thrashing forever.
fn linuxRss(io: Io) !u64 {
    var buf: [4096]u8 = undefined;
    const file = try Io.Dir.openFileAbsolute(io, "/proc/self/status", .{});
    defer file.close(io);
    const len = try file.readStreaming(io, &.{&buf});
    const contents = buf[0..len];

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            var it = std.mem.tokenizeAny(u8, line["VmRSS:".len..], " \t");
            const kb_str = it.next() orelse return error.VmRssParseFailed;
            const kb = try std.fmt.parseInt(u64, kb_str, 10);
            return kb * 1024;
        }
    }
    return error.VmRssNotFound;
}

/// Reuses the exact NtQueryInformationProcess/PROCESS.VM_COUNTERS mechanism
/// std's own std.process.Child already uses internally for a spawned
/// child's resource-usage statistics (std/Io/Threaded.zig's
/// childCleanupWindows) -- queried here against this process's own handle
/// instead of a child's, so this needs no new extern declaration of its own.
fn windowsRss() !u64 {
    const windows = std.os.windows;
    var vmc: windows.PROCESS.VM_COUNTERS = undefined;
    const status = windows.ntdll.NtQueryInformationProcess(
        windows.GetCurrentProcess(),
        .VmCounters,
        &vmc,
        @sizeOf(windows.PROCESS.VM_COUNTERS),
        null,
    );
    if (status != .SUCCESS) return error.NtQueryInformationProcessFailed;
    return vmc.WorkingSetSize;
}

test "residentSetSizeBytes: reports a plausible value that rises after real memory pressure" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const before = try residentSetSizeBytes(io);
    try std.testing.expect(before > 0);

    const chunk = try std.heap.page_allocator.alloc(u8, 50 * 1024 * 1024);
    defer std.heap.page_allocator.free(chunk);
    for (chunk, 0..) |*b, i| b.* = @truncate(i);

    const after = try residentSetSizeBytes(io);
    try std.testing.expect(after > before);
}
