//! The Extism host-function wire layer for `WidgetHost` -- every
//! `natyv_create_*`/`natyv_clay_create_*` callback (one per widget kind),
//! the generic `natyv_set_text`/`natyv_get_text`/`natyv_set_checked`/
//! `natyv_get_checked`/`natyv_set_value`/`natyv_get_value`/
//! `natyv_destroy_widget` callbacks, their JSON request structs, and the
//! small helpers only they need (`parseRequest`, `toClayStyle`,
//! `toSizingAxis`, `insertClayWidget`). Split out of `WidgetHost.zig`
//! purely to keep that file's own length down to the real registry logic
//! (insert/snapshot/focus/destroy/scroll-generation bookkeeping) -- this
//! file is pure per-widget-kind boilerplate, not a separate concern in its
//! own right. `WidgetHost.zig`'s `registerInto`/`registerClayInto` are the
//! only callers that reach into this file (by name, to hand each
//! function's pointer to `extism_function_new`) -- see their own doc
//! comments.
//!
//! This file and `WidgetHost.zig` `@import` each other (this file needs
//! `WidgetHost`'s registry-internal helpers -- `insertLocked`,
//! `insertLockedWithLayoutValidated`, `findLocked`,
//! `queueWidgetTextDestroysLocked`, `io` -- all promoted from private to
//! `pub` for exactly this; `WidgetHost.zig` needs this file's callback
//! function pointers). Zig resolves `@import` lazily per-declaration, so a
//! two-file mutual import like this is fine as long as no single
//! declaration's evaluation recurses into itself -- confirmed empirically
//! here (`zig build`/`zig build test` both pass with this exact cycle).

const std = @import("std");
const c = @import("../c.zig").c;
const host_fn_util = @import("../host_fn_util.zig");
const timing = @import("../timing.zig");
const json_util = @import("../json_util.zig");
const Button = @import("Button.zig");
const TextField = @import("TextField.zig");
const TextArea = @import("TextArea.zig");
const Label = @import("Label.zig");
const Container = @import("Container.zig");
const Checkbox = @import("Checkbox.zig");
const Toggle = @import("Toggle.zig");
const RadioButton = @import("RadioButton.zig");
const ProgressBar = @import("ProgressBar.zig");
const Slider = @import("Slider.zig");
const Divider = @import("Divider.zig");
const Badge = @import("Badge.zig");
const NumericStepper = @import("NumericStepper.zig");
const SegmentedControl = @import("SegmentedControl.zig");
const Tabs = @import("Tabs.zig");

const WidgetHost = @import("WidgetHost.zig");
const Self = WidgetHost;
const Widget = WidgetHost.Widget;
const ClayStyle = WidgetHost.ClayStyle;

const CreateButtonRequest = struct { x: f32, y: f32, w: f32, h: f32, label: []const u8 };
const CreateTextFieldRequest = struct { x: f32, y: f32, w: f32, h: f32, placeholder: []const u8 = "" };
const CreateTextAreaRequest = struct { x: f32, y: f32, w: f32, h: f32, placeholder: []const u8 = "" };
const CreateDividerRequest = struct { x: f32, y: f32, w: f32, h: f32 };
// W14: `tone`'s JSON string parses directly into `Badge.Tone` -- its tags
// ("primary", "success", etc.) already are the wire names, unlike Clay's
// own C-enum-value-vs-JSON-string split (see ClayDirectionRequest above),
// so no separate wire-format enum is needed here.
const CreateBadgeRequest = struct { x: f32, y: f32, w: f32, h: f32, tone: Badge.Tone = .neutral, label: []const u8 = "" };
const WidgetIdRequest = struct { widget_id: u32 };
const CreateLabelRequest = struct { x: f32, y: f32, w: f32 = 0, h: f32 = 20, text: []const u8 = "" };
const SetTextRequest = struct { widget_id: u32, text: []const u8 };
const CreateCheckboxRequest = struct { x: f32, y: f32, w: f32, h: f32, label: []const u8 = "", checked: bool = false };
const CreateToggleRequest = struct { x: f32, y: f32, w: f32, h: f32, label: []const u8 = "", checked: bool = false };
const CreateRadioButtonRequest = struct { x: f32, y: f32, w: f32, h: f32, label: []const u8 = "", group_id: u32, checked: bool = false };
const CreateProgressBarRequest = struct { x: f32, y: f32, w: f32, h: f32, value: f32 = 0 };
const CreateSliderRequest = struct { x: f32, y: f32, w: f32, h: f32, value: f32 = 0 };
// W17: `wrap` defaults false (clamp) -- the picker's hour/minute use case
// opts in explicitly, matching `NumericStepper.wrap`'s own default.
const CreateNumericStepperRequest = struct { x: f32, y: f32, w: f32, h: f32, value: i32 = 0, min: i32 = 0, max: i32 = 100, step: i32 = 1, wrap: bool = false };
const CreateSegmentedControlRequest = struct { x: f32, y: f32, w: f32, h: f32, segments: []const []const u8 = &.{}, selected_index: usize = 0 };
const SetCheckedRequest = struct { widget_id: u32, checked: bool };
const SetValueRequest = struct { widget_id: u32, value: f32 };

// L3: wire-format mirrors of Clay's real C types (Clay_SizingAxis,
// Clay_Padding, Clay_LayoutDirection, Clay_ChildAlignment -- see clay.h)
// with JSON-friendly enum tags instead of Clay's C enum constants.
// `toClayStyle` below converts one of these into a real `ClayStyle` (which
// *does* use Clay's actual C types directly, since that's what gets
// redeclared to Clay every frame starting in L4).
const ClaySizingType = enum { fit, grow, fixed, percent };
const ClaySizingAxisRequest = struct {
    type: ClaySizingType = .fit,
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),
    percent: f32 = 0,
};
const ClaySizingRequest = struct {
    width: ClaySizingAxisRequest = .{},
    height: ClaySizingAxisRequest = .{},
};
const ClayPaddingRequest = struct { left: u16 = 0, right: u16 = 0, top: u16 = 0, bottom: u16 = 0 };
const ClayDirectionRequest = enum { left_to_right, top_to_bottom };
const ClayAlignXRequest = enum { left, right, center };
const ClayAlignYRequest = enum { top, bottom, center };
const ClayAlignmentRequest = struct { x: ClayAlignXRequest = .left, y: ClayAlignYRequest = .top };

const ClayLayoutRequest = struct {
    parent_id: ?u32 = null,
    sizing: ClaySizingRequest = .{},
    padding: ClayPaddingRequest = .{},
    child_gap: u16 = 0,
    direction: ClayDirectionRequest = .left_to_right,
    child_alignment: ClayAlignmentRequest = .{},
    scroll_vertical: bool = false,
    scroll_horizontal: bool = false,
    floating: bool = false,
    modal: bool = false,
    toast: bool = false,
    /// W19: see `ClayStyle.visible`'s doc comment. Defaults `true`, same as
    /// the real style field it feeds -- most callers never set this; it
    /// exists on the wire mainly so `createClayTabPanelHostFn` can start a
    /// freshly-created panel hidden/shown correctly without a follow-up
    /// `setActiveTab` call (see that function -- it computes the real value
    /// itself and overwrites whatever a guest happened to request here,
    /// since panel visibility is host-owned, not guest-declared).
    visible: bool = true,
};
const ClayContainerRequest = struct { layout: ClayLayoutRequest = .{}, background: bool = false, duration_ms: u32 = 0 };
const ClayButtonRequest = struct { layout: ClayLayoutRequest = .{}, label: []const u8 };
const ClayTextFieldRequest = struct { layout: ClayLayoutRequest = .{}, placeholder: []const u8 = "" };
const ClayTextAreaRequest = struct { layout: ClayLayoutRequest = .{}, placeholder: []const u8 = "" };
const ClayDividerRequest = struct { layout: ClayLayoutRequest = .{} };
const ClayBadgeRequest = struct { layout: ClayLayoutRequest = .{}, tone: Badge.Tone = .neutral, label: []const u8 = "" };
const ClayLabelRequest = struct { layout: ClayLayoutRequest = .{}, text: []const u8 = "" };
const ClayCheckboxRequest = struct { layout: ClayLayoutRequest = .{}, label: []const u8 = "", checked: bool = false };
const ClayToggleRequest = struct { layout: ClayLayoutRequest = .{}, label: []const u8 = "", checked: bool = false };
const ClayRadioButtonRequest = struct { layout: ClayLayoutRequest = .{}, label: []const u8 = "", group_id: u32, checked: bool = false };
const ClayProgressBarRequest = struct { layout: ClayLayoutRequest = .{}, value: f32 = 0 };
const ClaySliderRequest = struct { layout: ClayLayoutRequest = .{}, value: f32 = 0 };
const ClayNumericStepperRequest = struct { layout: ClayLayoutRequest = .{}, value: i32 = 0, min: i32 = 0, max: i32 = 100, step: i32 = 1, wrap: bool = false };
const ClaySegmentedControlRequest = struct { layout: ClayLayoutRequest = .{}, segments: []const []const u8 = &.{}, selected_index: usize = 0 };
const ClayTabsRequest = struct { layout: ClayLayoutRequest = .{}, labels: []const []const u8 = &.{}, selected_index: usize = 0 };
// `layout.parent_id` MUST name an existing `.tabs` widget -- validated in
// `createClayTabPanelHostFn` itself (`insertLockedWithLayoutValidated` only
// checks that *some* widget exists at that id, not its kind).
const ClayTabPanelRequest = struct { layout: ClayLayoutRequest = .{} };

fn toSizingAxis(req: ClaySizingAxisRequest) c.Clay_SizingAxis {
    return switch (req.type) {
        .fit => .{ .type = c.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = req.min, .max = req.max } } },
        .grow => .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = req.min, .max = req.max } } },
        .fixed => .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = req.min, .max = req.max } } },
        .percent => .{ .type = c.CLAY__SIZING_TYPE_PERCENT, .size = .{ .percent = req.percent } },
    };
}

fn toClayStyle(req: ClayLayoutRequest) ClayStyle {
    return .{
        .sizing = .{ .width = toSizingAxis(req.sizing.width), .height = toSizingAxis(req.sizing.height) },
        .padding = .{ .left = req.padding.left, .right = req.padding.right, .top = req.padding.top, .bottom = req.padding.bottom },
        .child_gap = req.child_gap,
        .direction = switch (req.direction) {
            .left_to_right => c.CLAY_LEFT_TO_RIGHT,
            .top_to_bottom => c.CLAY_TOP_TO_BOTTOM,
        },
        .child_alignment = .{
            .x = switch (req.child_alignment.x) {
                .left => c.CLAY_ALIGN_X_LEFT,
                .right => c.CLAY_ALIGN_X_RIGHT,
                .center => c.CLAY_ALIGN_X_CENTER,
            },
            .y = switch (req.child_alignment.y) {
                .top => c.CLAY_ALIGN_Y_TOP,
                .bottom => c.CLAY_ALIGN_Y_BOTTOM,
                .center => c.CLAY_ALIGN_Y_CENTER,
            },
        },
        .scroll_vertical = req.scroll_vertical,
        .scroll_horizontal = req.scroll_horizontal,
        .floating = req.floating,
        .modal = req.modal,
        .toast = req.toast,
        .visible = req.visible,
    };
}

/// Shared body for all four natyv_clay_create_* host functions: converts
/// the request's `layout` into a real `ClayStyle`, inserts under the
/// registry lock with parent validation, and writes back {"widget_id":N}
/// or {"error":...}. The widget's `rect` is left zeroed at creation time --
/// real geometry is computed output starting in L4, not creation input, so
/// there's nothing meaningful to draw until the first real Clay layout pass
/// runs.
fn insertClayWidget(self: *Self, plugin: ?*c.ExtismCurrentPlugin, out_val: *allowzero c.ExtismVal, widget: Widget, layout: ClayLayoutRequest, expires_at_ms: ?i64) void {
    const style = toClayStyle(layout);
    const call_io = self.io();
    self.mutex.lockUncancelable(call_io);
    const result = self.insertLockedWithLayoutValidated(widget, layout.parent_id, style, expires_at_ms);
    self.mutex.unlock(call_io);

    const widget_id = result catch |err| {
        switch (err) {
            error.NoSuchParent => host_fn_util.writeErrorJson(plugin, out_val, "no such parent widget {d}", .{layout.parent_id.?}),
            error.RegistryFull => host_fn_util.writeErrorJson(plugin, out_val, "widget registry full", .{}),
        }
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, out_val, json);
}

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

pub fn createButtonHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
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

pub fn createTextFieldHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
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

pub fn createTextAreaHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateTextAreaRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const area = TextArea.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.placeholder);

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .textarea = area });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createDividerHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateDividerRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const divider = Divider.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h });

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .divider = divider });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createBadgeHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateBadgeRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const badge = Badge.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.tone, req.label);

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .badge = badge });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createLabelHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
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

pub fn createCheckboxHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateCheckboxRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    var checkbox = Checkbox.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.label);
    checkbox.checked = req.checked;

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .checkbox = checkbox });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createToggleHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateToggleRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    var toggle = Toggle.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.label);
    toggle.checked = req.checked;

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .toggle = toggle });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createRadioButtonHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateRadioButtonRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    var radio = RadioButton.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.group_id, req.label);
    radio.checked = req.checked;

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .radio_button = radio });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createProgressBarHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateProgressBarRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const bar = ProgressBar.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.value);

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .progress_bar = bar });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createSliderHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateSliderRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const slider = Slider.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.value);

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .slider = slider });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createNumericStepperHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateNumericStepperRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const stepper = NumericStepper.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.value, req.min, req.max, req.step, req.wrap);

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .numeric_stepper = stepper });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createSegmentedControlHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(CreateSegmentedControlRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    const control = SegmentedControl.init(.{ .x = req.x, .y = req.y, .w = req.w, .h = req.h }, req.segments, req.selected_index);

    self.mutex.lockUncancelable(self.io());
    const id = self.insertLocked(.{ .segmented_control = control });
    self.mutex.unlock(self.io());

    const widget_id = id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{});
        return;
    };
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn createClayContainerHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayContainerRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const container = Container.init(std.mem.zeroes(c.SDL_FRect), parsed.value.background);
    // W7: 0 (the default) means "never expires" -- only Container's own
    // creation ever computes a non-null value here, see
    // insertLockedWithLayoutValidated's doc comment.
    const expires_at_ms: ?i64 = if (parsed.value.duration_ms > 0) timing.nowMs() + @as(i64, parsed.value.duration_ms) else null;
    insertClayWidget(self, plugin, &outputs[0], .{ .container = container }, parsed.value.layout, expires_at_ms);
}

pub fn createClayButtonHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayButtonRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const button = Button.init(std.mem.zeroes(c.SDL_FRect), parsed.value.label);
    insertClayWidget(self, plugin, &outputs[0], .{ .button = button }, parsed.value.layout, null);
}

pub fn createClayTextFieldHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayTextFieldRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const field = TextField.init(std.mem.zeroes(c.SDL_FRect), parsed.value.placeholder);
    insertClayWidget(self, plugin, &outputs[0], .{ .textfield = field }, parsed.value.layout, null);
}

pub fn createClayTextAreaHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayTextAreaRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const area = TextArea.init(std.mem.zeroes(c.SDL_FRect), parsed.value.placeholder);
    insertClayWidget(self, plugin, &outputs[0], .{ .textarea = area }, parsed.value.layout, null);
}

pub fn createClayDividerHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayDividerRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const divider = Divider.init(std.mem.zeroes(c.SDL_FRect));
    insertClayWidget(self, plugin, &outputs[0], .{ .divider = divider }, parsed.value.layout, null);
}

pub fn createClayBadgeHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayBadgeRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const badge = Badge.init(std.mem.zeroes(c.SDL_FRect), parsed.value.tone, parsed.value.label);
    insertClayWidget(self, plugin, &outputs[0], .{ .badge = badge }, parsed.value.layout, null);
}

pub fn createClayLabelHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayLabelRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const label = Label.init(std.mem.zeroes(c.SDL_FRect), parsed.value.text);
    insertClayWidget(self, plugin, &outputs[0], .{ .label = label }, parsed.value.layout, null);
}

pub fn createClayCheckboxHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayCheckboxRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    var checkbox = Checkbox.init(std.mem.zeroes(c.SDL_FRect), parsed.value.label);
    checkbox.checked = parsed.value.checked;
    insertClayWidget(self, plugin, &outputs[0], .{ .checkbox = checkbox }, parsed.value.layout, null);
}

pub fn createClayToggleHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayToggleRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    var toggle = Toggle.init(std.mem.zeroes(c.SDL_FRect), parsed.value.label);
    toggle.checked = parsed.value.checked;
    insertClayWidget(self, plugin, &outputs[0], .{ .toggle = toggle }, parsed.value.layout, null);
}

pub fn createClayRadioButtonHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayRadioButtonRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    var radio = RadioButton.init(std.mem.zeroes(c.SDL_FRect), parsed.value.group_id, parsed.value.label);
    radio.checked = parsed.value.checked;
    insertClayWidget(self, plugin, &outputs[0], .{ .radio_button = radio }, parsed.value.layout, null);
}

pub fn createClayProgressBarHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayProgressBarRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const bar = ProgressBar.init(std.mem.zeroes(c.SDL_FRect), parsed.value.value);
    insertClayWidget(self, plugin, &outputs[0], .{ .progress_bar = bar }, parsed.value.layout, null);
}

pub fn createClaySliderHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClaySliderRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const slider = Slider.init(std.mem.zeroes(c.SDL_FRect), parsed.value.value);
    insertClayWidget(self, plugin, &outputs[0], .{ .slider = slider }, parsed.value.layout, null);
}

pub fn createClayNumericStepperHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayNumericStepperRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const stepper = NumericStepper.init(std.mem.zeroes(c.SDL_FRect), parsed.value.value, parsed.value.min, parsed.value.max, parsed.value.step, parsed.value.wrap);
    insertClayWidget(self, plugin, &outputs[0], .{ .numeric_stepper = stepper }, parsed.value.layout, null);
}

pub fn createClaySegmentedControlHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClaySegmentedControlRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const control = SegmentedControl.init(std.mem.zeroes(c.SDL_FRect), parsed.value.segments, parsed.value.selected_index);
    insertClayWidget(self, plugin, &outputs[0], .{ .segmented_control = control }, parsed.value.layout, null);
}

pub fn createClayTabsHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayTabsRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const tabs = Tabs.init(std.mem.zeroes(c.SDL_FRect), parsed.value.labels, parsed.value.selected_index);
    // The header-height top-padding reservation and forced top_to_bottom
    // direction are enforced in ClayLayout.zig's openChildren, not here --
    // that way the invariant holds for every `.tabs` insertion path
    // (including a direct insertWithLayout call in a test), not just this
    // guest-facing wire contract.
    insertClayWidget(self, plugin, &outputs[0], .{ .tabs = tabs }, parsed.value.layout, null);
}

/// W19: unlike every other `natyv_clay_create_*` function, this doesn't go
/// through `insertClayWidget` -- it needs two things that shared helper
/// doesn't do: reject a `parent_id` that exists but isn't a `.tabs` widget
/// (`insertLockedWithLayoutValidated` only checks that *some* widget exists
/// there), and, after inserting, register the new panel's id into the
/// parent Tabs widget's `panel_ids` so `WidgetHost.setActiveTab` knows to
/// manage its `visible` flag. The panel's own initial `visible` is computed
/// here (not left to whatever the guest's `layout.visible` requested,
/// default `true`) -- correct panel visibility on creation is this
/// widget's whole reason for existing, so it isn't guest-configurable.
pub fn createClayTabPanelHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayTabPanelRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const layout = parsed.value.layout;

    const parent_id = layout.parent_id orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "tab panel requires layout.parent_id naming a Tabs widget", .{});
        return;
    };

    const call_io = self.io();
    self.mutex.lockUncancelable(call_io);

    const parent_slot = self.findLocked(parent_id) orelse {
        self.mutex.unlock(call_io);
        host_fn_util.writeErrorJson(plugin, &outputs[0], "no such parent widget {d}", .{parent_id});
        return;
    };
    if (parent_slot.widget != .tabs) {
        self.mutex.unlock(call_io);
        host_fn_util.writeErrorJson(plugin, &outputs[0], "parent_id {d} does not name a Tabs widget", .{parent_id});
        return;
    }
    if (parent_slot.widget.tabs.panel_count >= Tabs.max_tabs) {
        self.mutex.unlock(call_io);
        host_fn_util.writeErrorJson(plugin, &outputs[0], "tabs widget {d} already has the maximum of {d} panels", .{ parent_id, Tabs.max_tabs });
        return;
    }
    const panel_index = parent_slot.widget.tabs.panel_count;
    var style = toClayStyle(layout);
    style.visible = (panel_index == parent_slot.widget.tabs.selected_index);

    const container = Container.init(std.mem.zeroes(c.SDL_FRect), false);
    const result = self.insertLockedWithLayoutValidated(.{ .container = container }, parent_id, style, null);
    const widget_id = result catch |err| {
        self.mutex.unlock(call_io);
        switch (err) {
            error.NoSuchParent => host_fn_util.writeErrorJson(plugin, &outputs[0], "no such parent widget {d}", .{parent_id}),
            error.RegistryFull => host_fn_util.writeErrorJson(plugin, &outputs[0], "widget registry full", .{}),
        }
        return;
    };
    if (self.findLocked(parent_id)) |p| {
        p.widget.tabs.panel_ids[panel_index] = widget_id;
        p.widget.tabs.panel_count = panel_index + 1;
    }
    self.mutex.unlock(call_io);

    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"widget_id\":{d}}}", .{widget_id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn setTextHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
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
        .textarea => |*ta| ta.setText(req.text),
        .label => |*l| l.setText(req.text),
        .checkbox => |*cb| cb.setLabel(req.text),
        .toggle => |*tg| tg.setLabel(req.text),
        .radio_button => |*r| r.setLabel(req.text),
        .badge => |*bd| bd.setLabel(req.text),
        // W17: a stepper's value text is host-derived from `.value`
        // (see `NumericStepper.setValue`), and a segmented control's
        // segment labels are set once at creation with no v1 API to
        // change them afterward -- same "not an error, just doesn't
        // apply" precedent as Container/ProgressBar/Slider/Divider here.
        // W19: Tabs' labels join the same "set once at creation" set.
        .container, .progress_bar, .slider, .divider, .numeric_stepper, .segmented_control, .tabs => {},
    }
    if (slot.clay_managed) self.layout_generation +%= 1;
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{}");
}

pub fn getTextHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
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
        .textarea => |ta| ta.text(),
        .label => |l| l.text(),
        .checkbox => |cb| cb.label(),
        .toggle => |tg| tg.label(),
        .radio_button => |r| r.label(),
        .badge => |bd| bd.label(),
        .container, .progress_bar, .slider, .divider, .numeric_stepper, .segmented_control, .tabs => "",
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

/// W1: bool state for `.checkbox`/`.radio_button` -- a no-op (not an error)
/// on any other kind, matching `setTextHostFn`'s existing precedent for
/// kinds the operation doesn't apply to. A radio button being set `true`
/// routes through `selectRadioExclusive` *after* releasing the lock below
/// (that function takes its own lock -- `Io.Mutex` isn't reentrant, calling
/// it while still holding the lock here would deadlock), so its siblings
/// get deselected the same way a real click would; being set `false` just
/// deselects it directly, no exclusivity to apply.
pub fn setCheckedHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(SetCheckedRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    var is_radio = false;
    self.mutex.lockUncancelable(self.io());
    if (self.findLocked(req.widget_id)) |slot| {
        switch (slot.widget) {
            .checkbox => |*cb| cb.checked = req.checked,
            .toggle => |*tg| tg.checked = req.checked,
            .radio_button => |*r| {
                is_radio = true;
                if (!req.checked) r.deselect();
            },
            else => {},
        }
        self.mutex.unlock(self.io());
    } else {
        self.mutex.unlock(self.io());
        host_fn_util.writeErrorJson(plugin, &outputs[0], "no such widget {d}", .{req.widget_id});
        return;
    }

    if (is_radio and req.checked) self.selectRadioExclusive(self.io(), req.widget_id);
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{}");
}

pub fn getCheckedHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
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
    const checked = switch (slot.widget) {
        .checkbox => |cb| cb.checked,
        .toggle => |tg| tg.checked,
        .radio_button => |r| r.checked,
        else => false,
    };
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"checked\":{}}}", .{checked}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

/// W1: float state for `.progress_bar` -- no-op on any other kind, same
/// "not an error, just doesn't apply" precedent as `setCheckedHostFn`.
/// `ProgressBar.setValue` clamps to [0,1] itself, so no clamping needed here.
pub fn setValueHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(SetValueRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    self.mutex.lockUncancelable(self.io());
    defer self.mutex.unlock(self.io());
    const slot = self.findLocked(req.widget_id) orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "no such widget {d}", .{req.widget_id});
        return;
    };
    switch (slot.widget) {
        .progress_bar => |*p| p.setValue(req.value),
        // W3: a guest can still call natyv_set_value on a slider directly
        // (e.g. to reset it to a default) even though the common case is
        // host-driven drag/arrow-key input -- same "not an error, just
        // doesn't apply" precedent everywhere else in this file, except
        // here it *does* apply.
        .slider => |*s| s.setValue(req.value),
        // W17: same "guest can still set it directly" precedent as
        // Slider above -- round-trips through f32 (the wire's only
        // numeric type), fine for the small integer ranges either of
        // these widgets deals in.
        .numeric_stepper => |*ns| ns.setValue(@intFromFloat(req.value)),
        .segmented_control => |*sc| sc.select(@intFromFloat(@max(0, req.value))),
        else => {},
    }
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{}");
}

pub fn getValueHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
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
    const value: f32 = switch (slot.widget) {
        .progress_bar => |p| p.value,
        .slider => |s| s.value,
        .numeric_stepper => |ns| @floatFromInt(ns.value),
        .segmented_control => |sc| @floatFromInt(sc.selected_index),
        else => 0,
    };
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{value}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

pub fn destroyWidgetHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(WidgetIdRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const req = parsed.value;

    self.mutex.lockUncancelable(self.io());
    defer self.mutex.unlock(self.io());
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            if (s.id == req.widget_id) {
                // F3: this host function runs on the worker thread (nested
                // inside natyv_dispatch -- see Dispatch.zig's doc comment),
                // but TTF_DestroyText is only valid on the thread that
                // created the text (the main thread, which owns the text
                // engine). Queue the pointer for main.zig to actually
                // destroy next frame instead of calling it here -- see
                // `pending_text_destroys`'s doc comment for the full story,
                // and `destroyAllTextObjects` for the shutdown-time
                // counterpart (safe to call directly there since it's
                // already running on the main thread).
                self.queueWidgetTextDestroysLocked(&s.widget);
                if (s.clay_managed) self.layout_generation +%= 1;
                slot.* = null;
                host_fn_util.writeGuestBytes(plugin, &outputs[0], "{}");
                return;
            }
        }
    }
    host_fn_util.writeErrorJson(plugin, &outputs[0], "no such widget {d}", .{req.widget_id});
}
