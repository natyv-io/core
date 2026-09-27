//! HID capability: registers `hid_enumerate`/`hid_open`/`hid_write`/
//! `hid_close` as Extism host functions. Allowlist and SDL device-list logic
//! lives in `Hid.zig`, open devices and their reader threads in
//! `HidRegistry.zig` -- this file is only the guest-memory/JSON ABI glue,
//! the same split `capabilities/Tcp.zig` makes.
//!
//! Wire contract (JSON both directions, base64 for report bytes, matching
//! `tcp_*`):
//!   hid_enumerate: in {}                              out {"devices":[{path, vendor_id, product_id, interface_number, usage_page, usage, serial_number, product_string, manufacturer_string}, ...]}
//!   hid_open:      in {"path":"..."}                  out {"handle":N} | {"error":"..."}
//!   hid_write:     in {"handle":N,"data":"<base64>"}  out {"ok":true} | {"error":"..."}
//!   hid_close:     in {"handle":N}                    out {"ok":true}
//!
//! There is no `hid_read`. Input reports arrive as `.hid_report` events
//! addressed to the handle (`{"data":"<base64>"}`, plus `"dropped":N` after
//! a backlog overflow), and an unplug as one `.hid_disconnected` (`{}`) --
//! see `HidRegistry.zig`'s header for why.
//!
//! `hid_open` on a path that's already open returns the existing handle
//! rather than a second one. That's what lets a resumed guest reclaim its
//! devices after a recycle (see `Runtime.recycle`), and it means a guest
//! can't open one device twice and race two readers against it.

const std = @import("std");
const c = @import("../c.zig").c;
const host_fn_util = @import("../host_fn_util.zig");
const Config = @import("Config");
const Hid = @import("../Hid.zig");
const HidRegistry = @import("../HidRegistry.zig");
const EventQueue = @import("../EventQueue.zig");
const WidgetHost = @import("../widgets/WidgetHost.zig");

const Self = @This();

pub const host_function_count = 4;

/// Largest `hid_write` payload: a full report plus the leading report-id
/// byte hidapi expects (0 for a device without numbered reports).
const max_write_len = HidRegistry.report_buf_len + 1;

allocator: std.mem.Allocator,
allowed: []const Config.AllowedDevice,
registry: HidRegistry,
/// Borrowed, not owned -- used for `reserveId` (handles share the widget id
/// space, see `HidRegistry.zig`'s header) and for the `current_io` a host
/// function runs under. Fixed up in `Runtime.loadPlugin`, same two-phase
/// requirement `Runtime.tray` documents.
widgets: *WidgetHost,

pub fn init(allocator: std.mem.Allocator, allowed: []const Config.AllowedDevice, queue: *EventQueue) Self {
    return .{
        .allocator = allocator,
        .allowed = allowed,
        .registry = .init(queue, &HidRegistry.sdl_backend),
        .widgets = undefined,
    };
}

pub fn registerInto(self: *Self, funcs_out: []?*const c.ExtismFunction) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const names = [host_function_count][]const u8{ "hid_enumerate", "hid_open", "hid_write", "hid_close" };
    const fns = [host_function_count]*const fn (?*c.ExtismCurrentPlugin, [*c]const c.ExtismVal, c.ExtismSize, [*c]c.ExtismVal, c.ExtismSize, ?*anyopaque) callconv(.c) void{
        enumerateHostFn,
        openHostFn,
        writeHostFn,
        closeHostFn,
    };
    inline for (names, fns, 0..) |name, f, i| {
        funcs_out[i] = c.extism_function_new(name.ptr, &in_types[0], 1, &out_types[0], 1, f, self, null);
    }
    return host_function_count;
}

const OpenRequest = struct { path: []const u8 };
const HandleRequest = struct { handle: u32 };
const WriteRequest = struct { handle: u32, data: []const u8 };

/// `.alloc_always` for the same reason `capabilities/Tray.zig`'s copy
/// spells out: string fields must not borrow `input_bytes`.
fn parseRequest(comptime T: type, self: *Self, plugin: ?*c.ExtismCurrentPlugin, in_val: *allowzero const c.ExtismVal, out_val: *allowzero c.ExtismVal) ?std.json.Parsed(T) {
    const input_bytes = host_fn_util.readGuestBytes(self.allocator, plugin, in_val) catch {
        host_fn_util.writeErrorJson(plugin, out_val, "out of memory reading input", .{});
        return null;
    };
    defer self.allocator.free(input_bytes);

    return std.json.parseFromSlice(T, self.allocator, input_bytes, .{ .allocate = .alloc_always }) catch |err| {
        host_fn_util.writeErrorJson(plugin, out_val, "bad request: {}", .{err});
        return null;
    };
}

fn writeHandle(plugin: ?*c.ExtismCurrentPlugin, out_val: *allowzero c.ExtismVal, id: u32) void {
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"handle\":{d}}}", .{id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, out_val, json);
}

fn enumerateHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = inputs;
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));

    var devices: [Hid.max_enumerated]Hid.DeviceInfo = undefined;
    const n = Hid.enumerateAllowed(self.allowed, &devices);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    Hid.writeDevicesJson(&out, self.allocator, devices[0..n]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
        return;
    };
    host_fn_util.writeGuestBytes(plugin, &outputs[0], out.items);
}

fn openHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(OpenRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const path = parsed.value.path;

    if (self.registry.claimByPath(path)) |id| {
        writeHandle(plugin, &outputs[0], id);
        return;
    }
    // Checked before opening, not just left to `insert`, so a guest at the
    // cap can't make the host open and immediately close a device.
    if (self.registry.openCount() >= HidRegistry.max_devices) {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "too many open devices (max {d})", .{HidRegistry.max_devices});
        return;
    }

    _ = c.SDL_ClearError();
    const dev = Hid.openAllowed(self.allowed, path) catch |err| {
        var detail_buf: [160]u8 = undefined;
        switch (err) {
            error.NotAllowed => host_fn_util.writeErrorJson(plugin, &outputs[0], "not an allowed, connected device", .{}),
            error.PermissionDenied => host_fn_util.writeErrorJson(plugin, &outputs[0], "permission denied: {s}", .{Hid.permission_hint}),
            error.OpenFailed => host_fn_util.writeErrorJson(plugin, &outputs[0], "open failed: {s}", .{Hid.sdlErrorDetail(&detail_buf)}),
        }
        return;
    };

    const io = self.widgets.io();
    const id = self.widgets.reserveId(io);
    self.registry.insert(io, id, dev, path) catch |err| {
        switch (err) {
            error.TooManyDevices => host_fn_util.writeErrorJson(plugin, &outputs[0], "too many open devices (max {d})", .{HidRegistry.max_devices}),
            error.ThreadSpawnFailed => host_fn_util.writeErrorJson(plugin, &outputs[0], "could not start the device reader", .{}),
        }
        return;
    };
    writeHandle(plugin, &outputs[0], id);
}

fn writeHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(WriteRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(req.data) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "invalid base64", .{});
        return;
    };
    if (decoded_len == 0 or decoded_len > max_write_len) {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "report must be 1 to {d} bytes", .{max_write_len});
        return;
    }
    var buf: [max_write_len]u8 = undefined;
    decoder.decode(buf[0..decoded_len], req.data) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "invalid base64", .{});
        return;
    };

    _ = c.SDL_ClearError();
    self.registry.write(req.handle, buf[0..decoded_len]) catch |err| {
        var detail_buf: [160]u8 = undefined;
        switch (err) {
            error.NoSuchDevice => host_fn_util.writeErrorJson(plugin, &outputs[0], "unknown handle {d}", .{req.handle}),
            error.Disconnected => host_fn_util.writeErrorJson(plugin, &outputs[0], "device disconnected", .{}),
            error.WriteFailed => host_fn_util.writeErrorJson(plugin, &outputs[0], "write failed: {s}", .{Hid.sdlErrorDetail(&detail_buf)}),
        }
        return;
    };
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{\"ok\":true}");
}

fn closeHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(HandleRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    self.registry.close(self.widgets.io(), parsed.value.handle);
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{\"ok\":true}");
}
