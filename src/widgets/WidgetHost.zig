//! Owns the live set of widgets a guest has created via
//! natyv_create_button/natyv_create_textfield, and the host functions that
//! let a guest create/read/write/destroy them. This is what makes the guest
//! -- not the host -- the author of the app's UI: main.zig's render loop
//! knows nothing about any particular app, it just draws whatever is
//! registered here.
//!
//! Thread safety: entries are written by host-function callbacks (running
//! on the worker thread, nested inside Runtime.call's extism_plugin_call)
//! and read/written every frame by the render loop (main thread, e.g. live
//! text-field editing). Both sides lock `mutex` (an `Io.Mutex`) around any
//! access -- but a host-function callback is a raw `callconv(.c)` function
//! called by the C ABI, which has no way to carry an `Io` parameter. Since
//! only one plugin call is ever in flight at a time, and every host
//! function invoked during that call runs synchronously nested inside it on
//! the same thread, `Runtime.call` stashes the `io` it was given into
//! `current_io` immediately before calling into the guest -- safe because
//! nothing else can read or write that field while a call is in progress.
//!
//! Wire contract (JSON both directions):
//!   natyv_create_button    in: {"x":f,"y":f,"w":f,"h":f,"label":"..."}
//!   natyv_create_textfield in: {"x":f,"y":f,"w":f,"h":f,"placeholder":"..."}
//!     both out: {"widget_id":N} | {"error":"..."}
//!   natyv_set_text  in: {"widget_id":N,"text":"..."}   out: {} | {"error":..}
//!   natyv_get_text  in: {"widget_id":N}                out: {"text":"..."} | {"error":..}
//!   natyv_destroy_widget in: {"widget_id":N}           out: {} | {"error":..}

const std = @import("std");
const Io = std.Io;
const c = @import("../c.zig").c;
const host_fn_util = @import("../host_fn_util.zig");
const json_util = @import("../json_util.zig");
const Button = @import("Button.zig");
const TextField = @import("TextField.zig");
const Label = @import("Label.zig");

const Self = @This();

pub const max_widgets = 64;
pub const host_function_count = 6;

pub const WidgetKind = enum { button, textfield, label };
pub const Widget = union(WidgetKind) {
    button: Button,
    textfield: TextField,
    label: Label,
};
pub const Slot = struct { id: u32, widget: Widget };

allocator: std.mem.Allocator,
mutex: Io.Mutex = .init,
slots: [max_widgets]?Slot = [_]?Slot{null} ** max_widgets,
next_id: u32 = 1,
/// See file doc comment -- set by Runtime.call around every guest call,
/// unset after. Only ever read from inside a host function callback, which
/// by construction only ever runs nested inside that same call.
current_io: ?Io = null,

pub const EnabledKinds = struct {
    button: bool = true,
    textfield: bool = true,
    label: bool = true,
};

/// Registers only the create-functions for widget kinds `enabled` declares
/// (an app's conf.natyv.json) -- a guest that was never granted a kind gets
/// a normal "unknown import" failure from Extism if it tries to use it,
/// same class of enforcement as `allowed_hosts` for network access.
/// `natyv_set_text`/`natyv_get_text`/`natyv_destroy_widget` are generic
/// utility ops over whatever widgets already exist, so they're always
/// registered regardless -- there's nothing to gate: a guest can't get a
/// widget_id to call them with unless it already had permission to create
/// that widget in the first place.
pub fn registerInto(self: *Self, funcs_out: []?*const c.ExtismFunction, enabled: EnabledKinds) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    var n: usize = 0;
    if (enabled.button) {
        funcs_out[n] = c.extism_function_new("natyv_create_button", &in_types[0], 1, &out_types[0], 1, createButtonHostFn, self, null);
        n += 1;
    }
    if (enabled.textfield) {
        funcs_out[n] = c.extism_function_new("natyv_create_textfield", &in_types[0], 1, &out_types[0], 1, createTextFieldHostFn, self, null);
        n += 1;
    }
    if (enabled.label) {
        funcs_out[n] = c.extism_function_new("natyv_create_label", &in_types[0], 1, &out_types[0], 1, createLabelHostFn, self, null);
        n += 1;
    }
    funcs_out[n] = c.extism_function_new("natyv_set_text", &in_types[0], 1, &out_types[0], 1, setTextHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_get_text", &in_types[0], 1, &out_types[0], 1, getTextHostFn, self, null);
    n += 1;
    funcs_out[n] = c.extism_function_new("natyv_destroy_widget", &in_types[0], 1, &out_types[0], 1, destroyWidgetHostFn, self, null);
    n += 1;
    return n;
}

fn io(self: *Self) Io {
    return self.current_io orelse unreachable; // see file doc comment: invariant enforced by Runtime.call
}

fn insertLocked(self: *Self, widget: Widget) ?u32 {
    for (&self.slots) |*slot| {
        if (slot.* == null) {
            const id = self.next_id;
            self.next_id += 1;
            slot.* = .{ .id = id, .widget = widget };
            return id;
        }
    }
    return null;
}

fn findLocked(self: *Self, id: u32) ?*Slot {
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            if (s.id == id) return s;
        }
    }
    return null;
}

/// Copies the live widget set into `out` (id + widget snapshot) for the
/// render loop to draw/hit-test without holding the lock across SDL calls --
/// same pattern as the original prototype's `snapshotBooks`.
pub fn snapshot(self: *Self, call_io: Io, out: []Slot) usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    var n: usize = 0;
    for (self.slots) |slot| {
        if (n >= out.len) break;
        if (slot) |s| {
            out[n] = s;
            n += 1;
        }
    }
    return n;
}

pub fn appendTextTo(self: *Self, call_io: Io, id: u32, s: []const u8) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .textfield) slot.widget.textfield.appendText(s);
    }
}

pub fn backspaceOn(self: *Self, call_io: Io, id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .textfield) slot.widget.textfield.backspace();
    }
}

pub fn setFocused(self: *Self, call_io: Io, id: ?u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            if (s.widget == .textfield) s.widget.textfield.focused = (id != null and s.id == id.?);
        }
    }
}

pub fn flashButton(self: *Self, call_io: Io, id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .button) slot.widget.button.flash();
    }
}

const CreateButtonRequest = struct { x: f32, y: f32, w: f32, h: f32, label: []const u8 };
const CreateTextFieldRequest = struct { x: f32, y: f32, w: f32, h: f32, placeholder: []const u8 = "" };
const WidgetIdRequest = struct { widget_id: u32 };
const CreateLabelRequest = struct { x: f32, y: f32, w: f32 = 0, h: f32 = 20, text: []const u8 = "" };
const SetTextRequest = struct { widget_id: u32, text: []const u8 };

// Returns the owning `std.json.Parsed(T)`, not just `T` -- `T`'s string
// fields point into the parse arena `Parsed` owns, so the caller must keep
// it alive (via its own `defer parsed.deinit()`) for as long as it uses
// `.value`. An earlier version of this helper deinited the arena itself and
// returned a bare `T`, which handed back a struct full of dangling slices
// the instant the function returned -- caught via a real segfault inside a
// host function callback, not by inspection.
//
// `.allocate = .alloc_always` is required, not cosmetic: parseFromSlice's
// default (`.alloc_if_needed`) returns string fields as slices directly
// into `input_bytes` whenever no escaping is needed (e.g. a plain label
// like "Click me") -- and `input_bytes` is freed by this function before it
// even returns, which reproduced the exact same segfault independently of
// the `parsed.deinit()` ordering above. Forcing an always-copy decouples
// parsed string lifetimes from `input_bytes` entirely.
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

fn createButtonHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateButtonRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const button = Button.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.label);

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .button = button });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

fn createTextFieldHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateTextFieldRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const field = TextField.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.placeholder);

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .textfield = field });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

fn createLabelHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateLabelRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const label = Label.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.text);

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .label = label });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

fn setTextHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(SetTextRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    self.mutex.lockUncancelable(self.io());
    defer self.mutex.unlock(self.io());
    const slot = self.findLocked(req.widget_id) orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "no such widget {d}", .{req.widget_id});
        return;
    };
    switch (slot.widget) {
        .button => |*b| b.setLabel(req.text),
        .textfield => |*t| t.setText(req.text),
        .label => |*l| l.setText(req.text),
    }
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{}");
}

fn getTextHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(WidgetIdRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    self.mutex.lockUncancelable(self.io());
    defer self.mutex.unlock(self.io());
    const slot = self.findLocked(req.widget_id) orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "no such widget {d}", .{req.widget_id});
        return;
    };
    const text: []const u8 = switch (slot.widget) {
        .button => |b| b.label(),
        .textfield => |t| t.text(),
        .label => |l| l.text(),
    };

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var out: std.ArrayList(u8) = .empty;
    const ok = blk: {
        out.appendSlice(arena_allocator, "{\"text\":") catch break :blk false;
        json_util.writeString(&out, arena_allocator, text) catch break :blk false;
        out.append(arena_allocator, '}') catch break :blk false;
        break :blk true;
    };
    if (!ok) {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
        return;
    }
    host_fn_util.writeGuestBytes(plugin, &outputs[0], out.items);
}

fn destroyWidgetHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(WidgetIdRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    self.mutex.lockUncancelable(self.io());
    defer self.mutex.unlock(self.io());
    for (&self.slots) |*slot| {
        if (slot.*) |s| {
            if (s.id == req.widget_id) {
                slot.* = null;
                host_fn_util.writeGuestBytes(plugin, &outputs[0], "{}");
                return;
            }
        }
    }
    host_fn_util.writeErrorJson(plugin, &outputs[0], "no such widget {d}", .{req.widget_id});
}
