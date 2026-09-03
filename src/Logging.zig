//! Guest-facing logging (2026-09-03): natyv-core needs zero new host
//! *functions* for this -- Extism's own `extism:host/env log_*` imports
//! are already available to every plugin for free (confirmed directly in
//! the vendored `go-pdk`: `pdk.Log(level, msg)` already calls
//! `extism:host/env log_info`/`log_debug`/etc., no natyv-core wiring
//! needed on the guest-import side at all). This file's only real job is
//! telling libextism *where those lines actually go*, controlled by
//! `conf.natyv.json`'s `logging` field -- see `Config.zig`'s own doc
//! comment on that field for its real semantics (`null` disables logging
//! entirely; `"stdout"`/`"stderr"`; anything else is a filename resolved
//! via `SDL_GetPrefPath`, same convention `sqlite.filename` already uses).
//!
//! Uses `extism_log_custom` + a periodic `extism_log_drain` poll (`drain`,
//! called once per frame from `main.zig`'s own loop) rather than the
//! simpler `extism_log_file`, specifically so the destination isn't
//! limited to a single file -- stdout/stderr are real, equally-supported
//! options, and a future destination only needs a new case in
//! `handleLine` below, not a different Extism-side mechanism. The real
//! cost of this choice: `extism_log_custom` only *buffers* lines
//! internally, nothing reaches `dest` until something calls
//! `extism_log_drain` -- `drain()` is that periodic call.
//!
//! Global, process-wide state is unavoidable here: `ExtismLogDrainFunctionType`
//! (`void (*)(const char*, ExtismSize)`) carries no userdata/context
//! pointer at all, so the drain callback can't close over anything --
//! `dest`/`g_io` have to live as file-level globals instead.
//!
//! Level filtering is deliberately NOT a config-driven concept here:
//! `init` always subscribes Extism at its most permissive level
//! ("trace"), and which level a given call actually logs at is entirely a
//! guest-code decision (see `sdk/go`'s own `Info`/`Warn`/etc. wrappers).
//! `handleLine` gets every line regardless of level and, today, just
//! passes it straight through to `dest` -- a future handler that wants to
//! act differently per level (color-code stdout, route errors to a
//! second sink) can parse the level directly out of `data` there (Extism
//! formats it into the line's own text), without any config/host-function
//! changes anywhere else.

const std = @import("std");
const c = @import("c.zig").c;

const Dest = union(enum) {
    stdout,
    stderr,
    /// `offset` is tracked manually and written via `writePositionalAll`
    /// rather than relying on the file's own cursor / an append-mode open
    /// flag -- confirmed directly that `std.Io.Dir.CreateFileOptions` has
    /// no append flag in this Zig version, and positional writes are the
    /// one unambiguously-correct way to append across separate process
    /// launches regardless of what a streaming write's own positioning
    /// semantics turn out to be.
    file: struct { handle: std.Io.File, offset: u64 },
};

var dest: ?Dest = null;
var g_io: std.Io = undefined;

/// Called once, early in `main.zig`, after `SDL_Init` (a real file
/// destination needs `SDL_GetPrefPath`, which does). A no-op when
/// `logging` is `null` -- `extism_log_custom` is never even called, so
/// Extism drops the guest's log calls itself; `drain` becomes a
/// permanent no-op.
pub fn init(io: std.Io, logging: ?[]const u8, app_name: [:0]const u8) !void {
    const target = logging orelse return;
    g_io = io;

    if (std.mem.eql(u8, target, "stdout")) {
        dest = .stdout;
    } else if (std.mem.eql(u8, target, "stderr")) {
        dest = .stderr;
    } else {
        const pref_path_c = c.SDL_GetPrefPath("natyv", app_name.ptr) orelse {
            std.debug.print("[Logging] SDL_GetPrefPath failed: {s}\n", .{c.SDL_GetError()});
            return error.PrefPathFailed;
        };
        defer c.SDL_free(pref_path_c);
        const pref_path = std.mem.span(pref_path_c);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ pref_path, target }) catch {
            std.debug.print("[Logging] log path too long\n", .{});
            return error.PathTooLong;
        };
        const file = try std.Io.Dir.cwd().createFile(io, full_path, .{ .truncate = false });
        errdefer file.close(io);
        const size = (try file.stat(io)).size;
        dest = .{ .file = .{ .handle = file, .offset = size } };
    }

    if (!c.extism_log_custom("trace")) return error.ExtismLogSetupFailed;
}

/// Called once per frame from `main.zig`'s own loop -- cheap no-op when
/// logging is disabled (the common case). Extism only buffers lines
/// internally until this runs; nothing reaches `dest` without it.
pub fn drain() void {
    if (dest == null) return;
    c.extism_log_drain(handleLine);
}

/// Flushes anything still buffered and closes a real file destination --
/// call once, at shutdown. A no-op for stdout/stderr (nothing to close)
/// or when logging was never enabled.
pub fn deinit() void {
    if (dest == null) return;
    drain();
    if (dest.? == .file) dest.?.file.handle.close(g_io);
    dest = null;
}

fn handleLine(data: [*c]const u8, size: c.ExtismSize) callconv(.c) void {
    const line = data[0..size];
    switch (dest.?) {
        .stdout => std.Io.File.stdout().writeStreamingAll(g_io, line) catch {},
        .stderr => std.Io.File.stderr().writeStreamingAll(g_io, line) catch {},
        .file => |f| {
            f.handle.writePositionalAll(g_io, line, f.offset) catch return;
            dest.?.file.offset += line.len;
        },
    }
}
