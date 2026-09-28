//! Guest-facing system tray host functions over `../TrayRegistry.zig`.
//!
//! Thin by design, exactly like `Persist.zig`: parse JSON, call one registry
//! method, format JSON back. Every real decision -- id allocation, queue
//! ordering, the checkbox mirror -- lives in the registry, and every real
//! SDL call happens on the main thread in `main.zig`'s drain. Neither
//! happens here.
//!
//! **Not a gated capability.** `sqlite` and `network` are opt-in through
//! `conf.natyv.json` because they reach outside the process. A tray reaches
//! no further than a window does, and natyv's own precedent already draws
//! that line: widgets register unconditionally, and so do the native file
//! dialogs, which hand a guest real filesystem paths. Gating a tray would be
//! inconsistent with both.
//!
//! Wire contract (JSON both directions; every call answers `{}` or
//! `{"error":"..."}` unless noted):
//!   natyv_tray_create:            in  {"tooltip":"..."}
//!                                 out {"id":N}
//!   natyv_tray_destroy:           in  {"id":N}
//!   natyv_tray_set_tooltip:       in  {"id":N,"tooltip":"..."}
//!   natyv_tray_insert_entry:      in  {"parent_id":N,"pos":-1,"kind":"button"
//!                                      |"checkbox"|"submenu"|"separator",
//!                                      "label":"...","checked":false,"enabled":true}
//!                                 out {"id":N}
//!   natyv_tray_remove_entry:      in  {"id":N}
//!   natyv_tray_set_entry_label:   in  {"id":N,"label":"..."}
//!   natyv_tray_set_entry_checked: in  {"id":N,"checked":bool}
//!   natyv_tray_set_entry_enabled: in  {"id":N,"enabled":bool}
//!   natyv_tray_entry_checked:     in  {"id":N}
//!                                 out {"checked":bool}
//!
//! `parent_id` is a tray id for a top-level entry, or a `submenu` entry's id
//! for a nested one -- there is no separate menu id on the wire. SDL does
//! have a distinct `SDL_TrayMenu`, but a tray's root menu is 1:1 with the
//! tray and a submenu is 1:1 with the entry that owns it, so a third id
//! space would name nothing a caller does not already have a handle for.
//!
//! An id comes back before the tray or entry actually exists -- see
//! `TrayRegistry`'s header on why, and why that is the same contract
//! `natyv_clay_create_window` already offers.

const std = @import("std");
const c = @import("../c.zig").c;
const host_fn_util = @import("../host_fn_util.zig");
const TrayRegistry = @import("../TrayRegistry.zig");
const WidgetHost = @import("../widgets/WidgetHost.zig");

const Self = @This();

pub const host_function_count = 9;

allocator: std.mem.Allocator,
registry: *TrayRegistry,
/// Borrowed, not owned -- used for `reserveId` (so tray ids share the widget
/// id space) and for the `current_io` a host function runs under, which only
/// `WidgetHost` tracks.
widgets: *WidgetHost,

pub fn init(allocator: std.mem.Allocator, registry: *TrayRegistry, widgets: *WidgetHost) Self {
    return .{ .allocator = allocator, .registry = registry, .widgets = widgets };
}

pub fn registerInto(self: *Self, funcs_out: []?*const c.ExtismFunction) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const names = [host_function_count][]const u8{
        "natyv_tray_create",
        "natyv_tray_destroy",
        "natyv_tray_set_tooltip",
        "natyv_tray_insert_entry",
        "natyv_tray_remove_entry",
        "natyv_tray_set_entry_label",
        "natyv_tray_set_entry_checked",
        "natyv_tray_set_entry_enabled",
        "natyv_tray_entry_checked",
    };
    const fns = [host_function_count]*const fn (?*c.ExtismCurrentPlugin, [*c]const c.ExtismVal, c.ExtismSize, [*c]c.ExtismVal, c.ExtismSize, ?*anyopaque) callconv(.c) void{
        createHostFn,
        destroyHostFn,
        setTooltipHostFn,
        insertEntryHostFn,
        removeEntryHostFn,
        setEntryLabelHostFn,
        setEntryCheckedHostFn,
        setEntryEnabledHostFn,
        entryCheckedHostFn,
    };
    inline for (names, fns, 0..) |name, f, i| {
        funcs_out[i] = c.extism_function_new(name.ptr, &in_types[0], 1, &out_types[0], 1, f, self, null);
    }
    return host_function_count;
}

// -- Request shapes --

const CreateRequest = struct { tooltip: []const u8 = "" };
const IdRequest = struct { id: u32 };
const SetTooltipRequest = struct { id: u32, tooltip: []const u8 = "" };
const InsertEntryRequest = struct {
    parent_id: u32,
    pos: i32 = -1,
    kind: []const u8 = "button",
    label: []const u8 = "",
    checked: bool = false,
    enabled: bool = true,
};
const SetLabelRequest = struct { id: u32, label: []const u8 = "" };
const SetCheckedRequest = struct { id: u32, checked: bool };
const SetEnabledRequest = struct { id: u32, enabled: bool };

/// `.allocate = .alloc_always` is required, not cosmetic -- see
/// `WidgetHostFunctions.parseRequest`'s own doc comment for the real
/// segfault the default `.alloc_if_needed` produced: it returns string
/// fields as slices into `input_bytes`, which is freed before this returns.
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

fn parseKind(s: []const u8) ?TrayRegistry.EntryKind {
    if (std.mem.eql(u8, s, "button")) return .button;
    if (std.mem.eql(u8, s, "checkbox")) return .checkbox;
    if (std.mem.eql(u8, s, "submenu")) return .submenu;
    if (std.mem.eql(u8, s, "separator")) return .separator;
    return null;
}

fn writeOk(plugin: ?*c.ExtismCurrentPlugin, out_val: *allowzero c.ExtismVal) void {
    host_fn_util.writeGuestBytes(plugin, out_val, "{}");
}

fn writeId(plugin: ?*c.ExtismCurrentPlugin, out_val: *allowzero c.ExtismVal, id: u32) void {
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, out_val, json);
}

// -- Host functions --

fn createHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();

    const io = self.widgets.io();
    const id = self.widgets.reserveId(io);
    self.registry.createTray(io, id, parsed.value.tooltip) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_create: {s}", .{@errorName(err)});
        return;
    };
    writeId(plugin, &outputs[0], id);
}

fn destroyHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(IdRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();

    self.registry.destroyTray(self.widgets.io(), parsed.value.id) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_destroy: {s}", .{@errorName(err)});
        return;
    };
    writeOk(plugin, &outputs[0]);
}

fn setTooltipHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(SetTooltipRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();

    self.registry.setTooltip(self.widgets.io(), parsed.value.id, parsed.value.tooltip) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_set_tooltip: {s}", .{@errorName(err)});
        return;
    };
    writeOk(plugin, &outputs[0]);
}

fn insertEntryHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(InsertEntryRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const kind = parseKind(req.kind) orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_insert_entry: unknown kind '{s}'", .{req.kind});
        return;
    };

    const io = self.widgets.io();
    const id = self.widgets.reserveId(io);
    self.registry.insertEntry(io, id, req.parent_id, req.pos, kind, req.label, req.checked, req.enabled) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_insert_entry: {s}", .{@errorName(err)});
        return;
    };
    writeId(plugin, &outputs[0], id);
}

fn removeEntryHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(IdRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();

    self.registry.removeEntry(self.widgets.io(), parsed.value.id) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_remove_entry: {s}", .{@errorName(err)});
        return;
    };
    writeOk(plugin, &outputs[0]);
}

fn setEntryLabelHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(SetLabelRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();

    self.registry.setEntryLabel(self.widgets.io(), parsed.value.id, parsed.value.label) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_set_entry_label: {s}", .{@errorName(err)});
        return;
    };
    writeOk(plugin, &outputs[0]);
}

fn setEntryCheckedHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(SetCheckedRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();

    self.registry.setEntryChecked(self.widgets.io(), parsed.value.id, parsed.value.checked) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_set_entry_checked: {s}", .{@errorName(err)});
        return;
    };
    writeOk(plugin, &outputs[0]);
}

fn setEntryEnabledHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(SetEnabledRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();

    self.registry.setEntryEnabled(self.widgets.io(), parsed.value.id, parsed.value.enabled) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_set_entry_enabled: {s}", .{@errorName(err)});
        return;
    };
    writeOk(plugin, &outputs[0]);
}

fn entryCheckedHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(IdRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();

    const checked = self.registry.entryChecked(self.widgets.io(), parsed.value.id) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "natyv_tray_entry_checked: {s}", .{@errorName(err)});
        return;
    };
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"checked\":{}}}", .{checked}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

test "parseKind accepts exactly SDL's own entry kinds plus separator" {
    try std.testing.expectEqual(TrayRegistry.EntryKind.button, parseKind("button").?);
    try std.testing.expectEqual(TrayRegistry.EntryKind.checkbox, parseKind("checkbox").?);
    try std.testing.expectEqual(TrayRegistry.EntryKind.submenu, parseKind("submenu").?);
    try std.testing.expectEqual(TrayRegistry.EntryKind.separator, parseKind("separator").?);
    // An unknown kind is a real error rather than a silent fallback to
    // button -- a typo'd kind should surface at the call, not produce a
    // menu entry that looks almost right.
    try std.testing.expect(parseKind("radio") == null);
    try std.testing.expect(parseKind("") == null);
}
