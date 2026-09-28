//! Real device logic behind the `hid_*` host functions -- deliberately
//! separate from `capabilities/Hid.zig`'s Extism ABI glue, the same split
//! `Tcp.zig`/`capabilities/Tcp.zig` already establishes: this file knows
//! allowlists and SDL's device list, and nothing about guest memory.
//!
//! Wraps SDL3's bundled hidapi (`SDL_hid_*`) -- raw, vendor-defined reports
//! only. SDL's `SDL_Joystick`/`SDL_Gamepad` layer is a different API for a
//! different purpose and isn't touched here. See `natyv-hid-capability`
//! memory for the full design.
//!
//! **The allowlist binds to what the OS reports, never to what the guest
//! claims.** `hid_open` takes a path, but a path is only opened if a fresh
//! enumeration right now lists it for an allowed vendor+product pair -- the
//! same posture `Tcp.matchAllowedSocket`'s exact host:port match takes.
//! Enumeration itself is filtered the same way, so a guest never learns
//! which keyboards and mice are plugged into the machine.
//!
//! Split so the filtering is testable without hardware: `collectAllowed`/
//! `listHasAllowedPath` take SDL's linked list as a parameter, and the tests
//! below build that list by hand. `enumerateAllowed`/`openAllowed` are the
//! thin wrappers that fetch the real one.
//!
//! **Requires `SDL_HINT_HIDAPI_ENUMERATE_ONLY_CONTROLLERS=0`** set before
//! `SDL_hid_init` (`main.zig` does this). SDL's default is `1`, which drops
//! every device whose usage isn't joystick/gamepad -- a macropad reporting
//! on a vendor usage page would simply never appear.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const Config = @import("Config");
const json_util = @import("json_util.zig");

/// Exact vendor+product match against `conf.natyv.json`'s
/// `hid.allowed_devices` -- no wildcards, mirroring `Tcp.matchAllowedSocket`.
pub fn matchAllowedDevice(allowed: []const Config.AllowedDevice, vendor_id: u16, product_id: u16) ?Config.AllowedDevice {
    for (allowed) |entry| {
        if (entry.vendor_id.value == vendor_id and entry.product_id.value == product_id) return entry;
    }
    return null;
}

/// A path longer than this is skipped rather than truncated -- a truncated
/// path opens nothing. Real ones are far shorter (`/dev/hidraw3` on Linux,
/// `DevSrvsID:4294969123` on macOS, ~150 bytes for a Windows device
/// interface path).
pub const max_path_len = 512;
/// Serial, product, and manufacturer strings are display text, so unlike a
/// path these are truncated (at a UTF-8 boundary) rather than skipped.
pub const max_string_len = 128;
/// Bounds `hid_enumerate`'s reply. The allowlist limits *which* devices are
/// visible, not how many interfaces a matching composite device exposes.
pub const max_enumerated = 32;

pub fn Text(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const Path = Text(max_path_len);
pub const String = Text(max_string_len);

pub const DeviceInfo = struct {
    path: Path = .{},
    vendor_id: u16,
    product_id: u16,
    /// Which interface of a composite device this is -- each shows up as its
    /// own entry with its own path. `-1` when the OS doesn't say.
    interface_number: i32,
    usage_page: u16,
    usage: u16,
    serial: String = .{},
    product: String = .{},
    manufacturer: String = .{},
};

/// Copies every allowed device in `head`'s list into `out`, returning how
/// many were written. Stops at `out.len` -- see `max_enumerated`.
pub fn collectAllowed(allowed: []const Config.AllowedDevice, head: ?*const c.SDL_hid_device_info, out: []DeviceInfo) usize {
    var n: usize = 0;
    var node = head;
    while (node) |dev| : (node = dev.next) {
        if (n == out.len) break;
        if (matchAllowedDevice(allowed, dev.vendor_id, dev.product_id) == null) continue;
        const path = std.mem.span(dev.path orelse continue);
        if (path.len > max_path_len) continue;

        out[n] = .{
            .vendor_id = dev.vendor_id,
            .product_id = dev.product_id,
            .interface_number = dev.interface_number,
            .usage_page = dev.usage_page,
            .usage = dev.usage,
        };
        @memcpy(out[n].path.buf[0..path.len], path);
        out[n].path.len = path.len;
        out[n].serial.len = wideToUtf8(dev.serial_number, &out[n].serial.buf).len;
        out[n].product.len = wideToUtf8(dev.product_string, &out[n].product.buf).len;
        out[n].manufacturer.len = wideToUtf8(dev.manufacturer_string, &out[n].manufacturer.buf).len;
        n += 1;
    }
    return n;
}

/// Whether `path` names an allowed device in `head`'s list -- the check
/// `openAllowed` runs before handing a guest-supplied path to SDL.
pub fn listHasAllowedPath(allowed: []const Config.AllowedDevice, head: ?*const c.SDL_hid_device_info, path: []const u8) bool {
    var node = head;
    while (node) |dev| : (node = dev.next) {
        const dev_path = std.mem.span(dev.path orelse continue);
        if (std.mem.eql(u8, dev_path, path) and matchAllowedDevice(allowed, dev.vendor_id, dev.product_id) != null) return true;
    }
    return false;
}

pub fn enumerateAllowed(allowed: []const Config.AllowedDevice, out: []DeviceInfo) usize {
    const head = c.SDL_hid_enumerate(0, 0);
    defer c.SDL_hid_free_enumeration(head);
    return collectAllowed(allowed, head, out);
}

/// `hid_enumerate`'s response body. Field names follow hidapi's own
/// (`serial_number`, `product_string`, ...) so a guest porting hidapi code
/// recognises them. Every string goes through `json_util.writeString` --
/// these come from the device's own descriptors, not from us.
pub fn writeDevicesJson(out: *std.ArrayList(u8), allocator: std.mem.Allocator, devices: []const DeviceInfo) !void {
    try out.appendSlice(allocator, "{\"devices\":[");
    for (devices, 0..) |d, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"path\":");
        try json_util.writeString(out, allocator, d.path.slice());
        try out.print(allocator, ",\"vendor_id\":{d},\"product_id\":{d},\"interface_number\":{d},\"usage_page\":{d},\"usage\":{d},\"serial_number\":", .{ d.vendor_id, d.product_id, d.interface_number, d.usage_page, d.usage });
        try json_util.writeString(out, allocator, d.serial.slice());
        try out.appendSlice(allocator, ",\"product_string\":");
        try json_util.writeString(out, allocator, d.product.slice());
        try out.appendSlice(allocator, ",\"manufacturer_string\":");
        try json_util.writeString(out, allocator, d.manufacturer.slice());
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}");
}

pub const OpenError = error{
    /// Not a connected device on the allowlist -- unplugged, never allowed,
    /// or a path the guest made up. Deliberately one error: a guest only
    /// ever sees allowed devices, so telling these apart would tell it
    /// nothing it's entitled to.
    NotAllowed,
    /// The OS refused, and the reason is one the user can fix. See
    /// `permissionHint` for the per-platform wording.
    PermissionDenied,
    OpenFailed,
};

pub fn openAllowed(allowed: []const Config.AllowedDevice, path: []const u8) OpenError!*c.SDL_hid_device {
    if (path.len > max_path_len) return error.NotAllowed;
    {
        const head = c.SDL_hid_enumerate(0, 0);
        defer c.SDL_hid_free_enumeration(head);
        if (!listHasAllowedPath(allowed, head, path)) return error.NotAllowed;
    }
    var path_z: [max_path_len + 1]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    if (c.SDL_hid_open_path(&path_z)) |dev| return dev;
    return if (permissionDenied(path_z[0..path.len :0])) error.PermissionDenied else error.OpenFailed;
}

/// SDL doesn't forward hidapi's own error text (`SDL_hid_open_path` returns
/// null without calling `SDL_SetError`), so the reason has to be asked of
/// the OS directly.
///
/// - macOS: reading a keyboard-class device needs Input Monitoring, and
///   `IOHIDCheckAccess` reports whether this process has it. A device on a
///   vendor usage page (a typical macropad) doesn't need it at all, so a
///   failure there with access granted is a real open failure, not this.
/// - Linux: `/dev/hidraw*` is root-only unless a udev rule says otherwise,
///   and `access` answers exactly that for the path SDL just tried.
/// - Windows: user-mode HID access isn't permission-gated.
fn permissionDenied(path: [:0]const u8) bool {
    switch (builtin.os.tag) {
        .macos => return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted,
        .linux => return std.c.access(path, std.c.R_OK | std.c.W_OK) != 0,
        else => return false,
    }
}

/// What to tell the user about `error.PermissionDenied` on this platform.
pub const permission_hint = switch (builtin.os.tag) {
    .macos => "grant this app Input Monitoring in System Settings > Privacy & Security",
    .linux => "no read/write access to the device node; a udev rule for this device is needed",
    else => "the operating system refused access to the device",
};

/// SDL's last error, made safe to drop into `host_fn_util.writeErrorJson`
/// (which doesn't escape): `"`, `\` and control characters become spaces,
/// and it's cut to fit `buf`. hidapi's own reason for a failed open/write
/// (e.g. IOKit's "unsupported function" for a wrong report id) is the only
/// clue a guest gets, so it's worth passing through. Callers should
/// `SDL_ClearError` before the failing call so a stale message isn't blamed.
pub fn sdlErrorDetail(buf: []u8) []const u8 {
    const detail = jsonSafe(std.mem.span(c.SDL_GetError()), buf);
    return if (detail.len == 0) "no detail from SDL" else detail;
}

fn jsonSafe(src: []const u8, buf: []u8) []const u8 {
    const n = @min(src.len, buf.len);
    for (src[0..n], buf[0..n]) |ch, *out| {
        out.* = if (ch == '"' or ch == '\\' or ch < 0x20 or ch == 0x7f) ' ' else ch;
    }
    return buf[0..n];
}

// IOKit/hidsystem/IOHIDLib.h (macOS 10.15+). IOKit is already linked for
// SDL's own hidapi backend, so this adds no new dependency.
extern "c" fn IOHIDCheckAccess(request_type: u32) u32;
const kIOHIDRequestTypeListenEvent: u32 = 1;
const kIOHIDAccessTypeGranted: u32 = 0;

/// hidapi hands back `wchar_t` strings: UTF-32 on macOS/Linux, UTF-16 on
/// Windows. Writes UTF-8 into `buf`, stopping at the last whole code point
/// that fits, with U+FFFD for anything malformed.
pub fn wideToUtf8(w: [*c]const c.wchar_t, buf: []u8) []const u8 {
    if (w == null) return buf[0..0];
    var len: usize = 0;
    var i: usize = 0;
    while (w[i] != 0) : (i += 1) {
        var cp: u21 = std.unicode.replacement_character;
        if (@sizeOf(c.wchar_t) == 4) {
            // `wchar_t` is signed on macOS and unsigned on Linux; either way
            // it's 32 bits, and a negative one is just an invalid code point.
            const unit: u32 = @bitCast(w[i]);
            if (unit <= 0x10FFFF and !(unit >= 0xD800 and unit <= 0xDFFF)) cp = @intCast(unit);
        } else {
            const unit: u16 = @intCast(w[i]);
            if (std.unicode.utf16IsHighSurrogate(unit) and std.unicode.utf16IsLowSurrogate(@intCast(w[i + 1]))) {
                cp = std.unicode.utf16DecodeSurrogatePair(&.{ unit, @intCast(w[i + 1]) }) catch unreachable;
                i += 1;
            } else if (!std.unicode.utf16IsHighSurrogate(unit) and !std.unicode.utf16IsLowSurrogate(unit)) {
                cp = unit;
            }
        }
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch unreachable;
        if (len + n > buf.len) break;
        @memcpy(buf[len..][0..n], enc[0..n]);
        len += n;
    }
    return buf[0..len];
}

// --- Tests: SDL's device list built by hand, so no hardware is needed. ---

fn wide(comptime s: []const u8) [s.len:0]c.wchar_t {
    var out: [s.len:0]c.wchar_t = @splat(0);
    for (s, 0..) |ch, i| out[i] = ch;
    return out;
}

fn testDevice(path: [*:0]const u8, vendor_id: u16, product_id: u16, next: ?*c.SDL_hid_device_info) c.SDL_hid_device_info {
    var dev = std.mem.zeroes(c.SDL_hid_device_info);
    dev.path = @constCast(path);
    dev.vendor_id = vendor_id;
    dev.product_id = product_id;
    dev.interface_number = -1;
    dev.next = next;
    return dev;
}

const test_allowed = [_]Config.AllowedDevice{
    .{ .vendor_id = .{ .value = 0x1234 }, .product_id = .{ .value = 0x5678 } },
};

test "matchAllowedDevice: exact vendor+product match, no wildcards" {
    const allowed = [_]Config.AllowedDevice{
        .{ .vendor_id = .{ .value = 0x1234 }, .product_id = .{ .value = 0x5678 } },
        .{ .vendor_id = .{ .value = 0x05AC }, .product_id = .{ .value = 0x0342 } },
    };
    try std.testing.expect(matchAllowedDevice(&allowed, 0x1234, 0x5678) != null);
    try std.testing.expect(matchAllowedDevice(&allowed, 0x05AC, 0x0342) != null);
    try std.testing.expect(matchAllowedDevice(&allowed, 0x1234, 0x0342) == null); // right vendor, other entry's product
    try std.testing.expect(matchAllowedDevice(&allowed, 0x9999, 0x5678) == null); // wrong vendor
    try std.testing.expect(matchAllowedDevice(&allowed, 0, 0) == null); // zero isn't a wildcard
    try std.testing.expect(matchAllowedDevice(&.{}, 0x1234, 0x5678) == null); // nothing allowed
}

test "collectAllowed: only allowlisted devices come back, every interface of one included" {
    var keyboard = testDevice("/dev/hidraw0", 0x05AC, 0x0342, null);
    var iface1 = testDevice("/dev/hidraw2", 0x1234, 0x5678, &keyboard);
    iface1.interface_number = 1;
    iface1.usage_page = 0xFF00;
    var iface0 = testDevice("/dev/hidraw1", 0x1234, 0x5678, &iface1);
    iface0.interface_number = 0;
    const serial = wide("SN-001");
    iface0.serial_number = @constCast(&serial);

    var out: [max_enumerated]DeviceInfo = undefined;
    const n = collectAllowed(&test_allowed, &iface0, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("/dev/hidraw1", out[0].path.slice());
    try std.testing.expectEqualStrings("SN-001", out[0].serial.slice());
    try std.testing.expectEqualStrings("", out[0].product.slice()); // null string -> empty
    try std.testing.expectEqual(@as(i32, 1), out[1].interface_number);
    try std.testing.expectEqual(@as(u16, 0xFF00), out[1].usage_page);
}

test "collectAllowed: stops at the output bound, skips an over-long or missing path" {
    var long_path: [max_path_len + 2:0]u8 = @splat('p');
    var too_long = testDevice(&long_path, 0x1234, 0x5678, null);
    var no_path = testDevice("x", 0x1234, 0x5678, &too_long);
    no_path.path = null;
    var b = testDevice("/dev/hidraw2", 0x1234, 0x5678, &no_path);
    var a = testDevice("/dev/hidraw1", 0x1234, 0x5678, &b);

    var out: [4]DeviceInfo = undefined;
    try std.testing.expectEqual(@as(usize, 2), collectAllowed(&test_allowed, &a, &out));
    try std.testing.expectEqual(@as(usize, 1), collectAllowed(&test_allowed, &a, out[0..1]));
    try std.testing.expectEqual(@as(usize, 0), collectAllowed(&test_allowed, null, &out));
}

test "listHasAllowedPath: the path must be listed *and* belong to an allowed device" {
    var keyboard = testDevice("/dev/hidraw0", 0x05AC, 0x0342, null);
    var pad = testDevice("/dev/hidraw1", 0x1234, 0x5678, &keyboard);

    try std.testing.expect(listHasAllowedPath(&test_allowed, &pad, "/dev/hidraw1"));
    try std.testing.expect(!listHasAllowedPath(&test_allowed, &pad, "/dev/hidraw0")); // listed, not allowed
    try std.testing.expect(!listHasAllowedPath(&test_allowed, &pad, "/dev/hidraw9")); // not listed
    try std.testing.expect(!listHasAllowedPath(&test_allowed, &pad, "/dev/hidraw")); // prefix isn't a match
    try std.testing.expect(!listHasAllowedPath(&test_allowed, null, "/dev/hidraw1"));
}

test "wideToUtf8: converts, truncates at a code point boundary, replaces bad units" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Macro Pad", wideToUtf8(&wide("Macro Pad"), &buf));
    try std.testing.expectEqualStrings("", wideToUtf8(null, &buf));

    // "é" is two bytes in UTF-8, so a 3-byte buffer holds "aé" and no more,
    // and a 2-byte one stops before splitting it.
    const accented = [_:0]c.wchar_t{ 'a', 0xE9, 'b' };
    var small: [3]u8 = undefined;
    try std.testing.expectEqualStrings("a\u{E9}", wideToUtf8(&accented, &small));
    try std.testing.expectEqualStrings("a", wideToUtf8(&accented, small[0..2]));

    if (@sizeOf(c.wchar_t) == 4) {
        const bad = [_:0]c.wchar_t{ 'x', 0xD800, 0x110000, @bitCast(@as(u32, 0xFFFFFFFF)) };
        try std.testing.expectEqualStrings("x\u{FFFD}\u{FFFD}\u{FFFD}", wideToUtf8(&bad, &buf));
        const astral = [_:0]c.wchar_t{0x1F3B9};
        try std.testing.expectEqualStrings("\u{1F3B9}", wideToUtf8(&astral, &buf));
    }
}

test "writeDevicesJson: every field present, descriptor strings escaped" {
    const allocator = std.testing.allocator;
    var d: DeviceInfo = .{ .vendor_id = 0x1234, .product_id = 0x5678, .interface_number = 1, .usage_page = 0xFF60, .usage = 0x61 };
    const path = "IOService:/a\"b";
    @memcpy(d.path.buf[0..path.len], path);
    d.path.len = path.len;
    const product = "Pad\\One";
    @memcpy(d.product.buf[0..product.len], product);
    d.product.len = product.len;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try writeDevicesJson(&out, allocator, &.{ d, d });

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.items, .{});
    defer parsed.deinit();
    const devices = parsed.value.object.get("devices").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), devices.len);
    const first = devices[0].object;
    try std.testing.expectEqualStrings(path, first.get("path").?.string);
    try std.testing.expectEqualStrings(product, first.get("product_string").?.string);
    try std.testing.expectEqualStrings("", first.get("serial_number").?.string);
    try std.testing.expectEqual(@as(i64, 0x1234), first.get("vendor_id").?.integer);
    try std.testing.expectEqual(@as(i64, 0xFF60), first.get("usage_page").?.integer);
    try std.testing.expectEqual(@as(i64, 1), first.get("interface_number").?.integer);
}

test "writeDevicesJson: no devices is an empty list" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try writeDevicesJson(&out, allocator, &.{});
    try std.testing.expectEqualStrings("{\"devices\":[]}", out.items);
}

test "jsonSafe: quotes, backslashes and control characters become spaces; truncates" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a b c d e", jsonSafe("a\"b\\c\nd\x7fe", &buf));
    var small: [4]u8 = undefined;
    try std.testing.expectEqualStrings("(0xE", jsonSafe("(0xE00002C7) unsupported", &small));
    try std.testing.expectEqualStrings("", jsonSafe("", &buf));
}
