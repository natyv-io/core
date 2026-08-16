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
//!
//! L3: `natyv_clay_*` variants (only registered when conf.natyv.json's
//! `ui.backend == "clay"`) take a `layout` object instead of x/y/w/h --
//! under a Clay-managed parent, position/size become *computed output*
//! (via L4's per-frame layout pass), not guest-supplied input:
//!   natyv_clay_create_container in: {"layout":{...}}
//!   natyv_clay_create_button    in: {"layout":{...},"label":"..."}
//!   natyv_clay_create_textfield in: {"layout":{...},"placeholder":"..."}
//!   natyv_clay_create_label     in: {"layout":{...},"text":"..."}
//!     all out: {"widget_id":N} | {"error":"..."}
//!   layout: {"parent_id":N|null,
//!            "sizing":{"width":{"type":"fit"|"grow"|"fixed"|"percent","min":f,"max":f,"percent":f}, "height":{...}},
//!            "padding":{"left":u16,"right":u16,"top":u16,"bottom":u16},
//!            "child_gap":u16,
//!            "direction":"left_to_right"|"top_to_bottom",
//!            "child_alignment":{"x":"left"|"right"|"center","y":"top"|"bottom"|"center"}}
//!   (every layout field is optional -- see ClayLayoutRequest defaults below)
//!   natyv_set_text/natyv_get_text/natyv_destroy_widget work unchanged on
//!   Clay-created widgets too, since they're the same underlying Widget
//!   union -- only how a widget's rect gets computed differs.

const std = @import("std");
const Io = std.Io;
const c = @import("../c.zig").c;
const host_fn_util = @import("../host_fn_util.zig");
const json_util = @import("../json_util.zig");
const Button = @import("Button.zig");
const TextField = @import("TextField.zig");
const Label = @import("Label.zig");
const Container = @import("Container.zig");

const Self = @This();

pub const max_widgets = 64;
pub const host_function_count = 6;

pub const WidgetKind = enum { button, textfield, label, container };
pub const Widget = union(WidgetKind) {
    button: Button,
    textfield: TextField,
    label: Label,
    container: Container,

    /// Every variant has its own `rect: c.SDL_FRect` field -- this gets a
    /// pointer to whichever one is active, regardless of kind. L4 uses this
    /// to write Clay's computed geometry back into the registry each frame
    /// without a kind-specific switch at every call site.
    pub fn rectPtr(self: *Widget) *c.SDL_FRect {
        return switch (self.*) {
            .button => |*b| &b.rect,
            .textfield => |*t| &t.rect,
            .label => |*l| &l.rect,
            .container => |*co| &co.rect,
        };
    }

    /// L4.5: the solid-color background fill this widget wants drawn this
    /// frame, or `null` if it doesn't have one (Label never does; Container
    /// is layout-only and never draws at all). `main.zig`'s draw loop
    /// buckets these across every widget into a `DrawBatcher` instead of
    /// each widget filling its own rect with its own `SDL_RenderFillRect`
    /// call.
    pub fn fillRect(self: Widget) ?struct { color: c.SDL_Color, rect: c.SDL_FRect } {
        return switch (self) {
            .button => |b| .{ .color = b.fillColor(), .rect = b.rect },
            .textfield => |t| .{ .color = t.fillColor(), .rect = t.rect },
            .label, .container => null,
        };
    }

    /// Keyboard-interaction model: only `Button`/`TextField` can receive
    /// focus -- `Label`/`Container` are pure display/layout, never
    /// interactive. Used by `focusableIdsSorted` to decide which widgets
    /// participate in Tab order.
    pub fn isFocusable(self: Widget) bool {
        return switch (self) {
            .button, .textfield => true,
            .label, .container => false,
        };
    }

    /// Per-kind dispatch for setting/clearing the `focused: bool` field --
    /// no-op for `Label`/`Container`, which don't have one. Used by
    /// `WidgetHost.setFocused` instead of a hardcoded `.textfield` check, so
    /// `Button` (or any future focusable kind) participates the same way.
    pub fn setFocusedFlag(self: *Widget, focused: bool) void {
        switch (self.*) {
            .button => |*b| b.focused = focused,
            .textfield => |*t| t.focused = focused,
            .label, .container => {},
        }
    }
};

/// The Clay tree relationships/style a widget was created with -- only
/// `natyv_clay_*` host functions (L3) populate these for real; every widget
/// created via the plain `natyv_create_*` functions above keeps the
/// defaults (no parent, zeroed style), since its layout stays
/// guest-supplied absolute pixels. Stored per-slot (not recomputed) so the
/// render loop can redeclare each node to Clay every frame from data it
/// already has, without a second guest round trip.
pub const ClayStyle = struct {
    sizing: c.Clay_Sizing = std.mem.zeroes(c.Clay_Sizing),
    padding: c.Clay_Padding = std.mem.zeroes(c.Clay_Padding),
    child_gap: u16 = 0,
    direction: c.Clay_LayoutDirection = c.CLAY_LEFT_TO_RIGHT,
    child_alignment: c.Clay_ChildAlignment = std.mem.zeroes(c.Clay_ChildAlignment),
};

pub const Slot = struct {
    id: u32,
    widget: Widget,
    parent_id: ?u32 = null,
    clay_style: ClayStyle = .{},
    /// True only for widgets inserted via the `natyv_clay_*` path (L3) --
    /// distinguishes "has a `parent_id`/`clay_style`" (could just be
    /// defaults) from "actually participates in Clay's tree," since a
    /// top-level Clay-managed container legitimately has `parent_id == null`
    /// too. Used to decide which layout-affecting mutations should bump
    /// `layout_generation` below (a legacy natyv_create_* widget's text
    /// changing has no effect on Clay's tree, so it shouldn't force a
    /// recompute).
    clay_managed: bool = false,
};

allocator: std.mem.Allocator,
mutex: Io.Mutex = .init,
slots: [max_widgets]?Slot = [_]?Slot{null} ** max_widgets,
next_id: u32 = 1,
/// Bumped by any mutation that could change Clay-managed layout geometry
/// (create/destroy a Clay-managed widget, or change text on one whose size
/// depends on its content) -- L4's render-loop pass compares this against
/// the generation it last actually ran Clay for, and skips
/// BeginLayout/EndLayout entirely on a frame where nothing moved it,
/// reusing each widget's already-cached `rect` instead. See
/// `ClayLayout.layoutIfNeeded`.
layout_generation: u64 = 0,
/// See file doc comment -- set by Runtime.call around every guest call,
/// unset after. Only ever read from inside a host function callback, which
/// by construction only ever runs nested inside that same call.
current_io: ?Io = null,
/// F3: `TTF_DestroyText` (like `TTF_CreateText`) must run on the thread
/// that created the text -- but `natyv_destroy_widget` is a host function,
/// called from inside `natyv_dispatch` on the *worker* thread (see
/// Dispatch.zig's file doc comment for why guest calls live there at all).
/// A guest destroying a widget (e.g. bookstore's refreshBookList) can't
/// destroy its `TTF_Text` right then and there -- `destroyWidgetHostFn`
/// queues the pointer here instead, and `flushPendingTextDestroys` (called
/// once per frame from `main.zig`, main thread) does the real
/// `TTF_DestroyText` call. Sized for the worst case between two frames:
/// every widget destroyed at once, times 2 (a TextField queues both its
/// entered-text and placeholder objects).
pending_text_destroys: [max_widgets * 2]?*c.TTF_Text = [_]?*c.TTF_Text{null} ** (max_widgets * 2),
pending_text_destroy_count: usize = 0,

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

pub const clay_host_function_count = 4;

/// Registered only when conf.natyv.json's `ui.backend == "clay"` --
/// Runtime.loadPlugin gates this the same way sqlite/widgets.* already
/// gate their own host functions (see Config.zig's UiConfig). These only
/// touch the widget registry (store parent_id + style on insert); the
/// actual Clay arena/BeginLayout/EndLayout lifecycle lives in
/// ClayLayout.zig and is driven per-frame by L4's render-loop pass, not by
/// these guest-facing create calls.
pub fn registerClayInto(self: *Self, funcs_out: []?*const c.ExtismFunction) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    funcs_out[0] = c.extism_function_new("natyv_clay_create_container", &in_types[0], 1, &out_types[0], 1, createClayContainerHostFn, self, null);
    funcs_out[1] = c.extism_function_new("natyv_clay_create_button", &in_types[0], 1, &out_types[0], 1, createClayButtonHostFn, self, null);
    funcs_out[2] = c.extism_function_new("natyv_clay_create_textfield", &in_types[0], 1, &out_types[0], 1, createClayTextFieldHostFn, self, null);
    funcs_out[3] = c.extism_function_new("natyv_clay_create_label", &in_types[0], 1, &out_types[0], 1, createClayLabelHostFn, self, null);
    return clay_host_function_count;
}

fn io(self: *Self) Io {
    return self.current_io orelse unreachable; // see file doc comment: invariant enforced by Runtime.call
}

fn insertLocked(self: *Self, widget: Widget) ?u32 {
    return self.insertLockedWithLayout(widget, null, .{});
}

fn insertLockedWithLayout(self: *Self, widget: Widget, parent_id: ?u32, clay_style: ClayStyle) ?u32 {
    for (&self.slots) |*slot| {
        if (slot.* == null) {
            const id = self.next_id;
            self.next_id += 1;
            slot.* = .{ .id = id, .widget = widget, .parent_id = parent_id, .clay_style = clay_style };
            return id;
        }
    }
    return null;
}

/// Locks, inserts a widget with explicit Clay parent/style data, and
/// unlocks -- the counterpart to the plain natyv_create_* host functions
/// above (which always go through the parent_id=null/default-style path).
/// L3's natyv_clay_* host functions call this directly once they exist;
/// for now it's exercised by Runtime.zig's own L2 test, since only a test
/// file's own root gets its `test` blocks reliably discovered under Zig's
/// lazy analysis (same lesson as the ClayLayout import above).
pub fn insertWithLayout(self: *Self, call_io: Io, widget: Widget, parent_id: ?u32, clay_style: ClayStyle) ?u32 {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    return self.insertLockedWithLayout(widget, parent_id, clay_style);
}

const InsertClayError = error{ NoSuchParent, RegistryFull };

/// Same as `insertLockedWithLayout`, but rejects a `parent_id` that doesn't
/// name an existing widget instead of silently inserting an orphan -- used
/// by the `natyv_clay_*` host functions below, which need to report a
/// meaningful error back to the guest rather than just failing later when
/// L4's layout pass can't find the parent.
fn insertLockedWithLayoutValidated(self: *Self, widget: Widget, parent_id: ?u32, clay_style: ClayStyle) InsertClayError!u32 {
    if (parent_id) |pid| {
        if (self.findLocked(pid) == null) return error.NoSuchParent;
    }
    const id = self.insertLockedWithLayout(widget, parent_id, clay_style) orelse return error.RegistryFull;
    if (self.findLocked(id)) |slot| slot.clay_managed = true;
    self.layout_generation +%= 1;
    return id;
}

/// Locked read of `layout_generation` -- L4's render-loop pass calls this
/// once per frame to decide whether a real Clay recompute is needed at all.
pub fn currentGeneration(self: *Self, call_io: Io) u64 {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    return self.layout_generation;
}

/// Writes Clay's computed geometry back into a widget's `rect` after a real
/// layout pass. Deliberately does *not* bump `layout_generation` itself --
/// this is downstream of a layout computation, not a cause of one, and
/// bumping here would make the generation counter chase its own tail.
pub fn setRect(self: *Self, call_io: Io, id: u32, rect: c.SDL_FRect) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| slot.widget.rectPtr().* = rect;
}

fn findLocked(self: *Self, id: u32) ?*Slot {
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            if (s.id == id) return s;
        }
    }
    return null;
}

/// F3: creates/updates every button/textfield/label's cached `TTF_Text`
/// against the *live* registry, once per frame, before that frame's
/// `snapshot` below is taken -- same "mutate the registry, then snapshot
/// sees the fresh result" ordering `ClayLayout.layoutIfNeeded` already
/// established for computed geometry (see main.zig's frame loop). Each
/// widget's own `syncText` decides whether it actually needs to touch
/// SDL_ttf at all this frame (see e.g. `Button.syncText`'s doc comment).
pub fn syncTextObjects(self: *Self, call_io: Io, engine: *c.TTF_TextEngine, font: *c.TTF_Font) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            switch (s.widget) {
                .button => |*b| b.syncText(engine, font),
                .textfield => |*t| t.syncText(engine, font),
                .label => |*l| l.syncText(engine, font),
                .container => {},
            }
        }
    }
}

/// SDL_ttf requires every `TTF_Text` be destroyed before its owning
/// `TTF_TextEngine` is -- called once at app shutdown (main.zig), for
/// every widget still in the registry regardless of whether the guest ever
/// explicitly destroyed it, since closing the window is not the same as
/// the guest calling natyv_destroy_widget on everything first.
pub fn destroyAllTextObjects(self: *Self, call_io: Io) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            switch (s.widget) {
                .button => |*b| b.destroyText(),
                .textfield => |*t| t.destroyText(),
                .label => |*l| l.destroyText(),
                .container => {},
            }
        }
    }
}

/// Appends `obj_ptr`'s pointee to the pending-destroy queue (see the field
/// doc comment) and nulls it out on the widget -- called from
/// `destroyWidgetHostFn` (worker thread) instead of calling `TTF_DestroyText`
/// directly there, since that call is only valid on the thread that created
/// the text. Silently drops the pointer if the queue is already at its
/// (generous, whole-registry-sized) capacity rather than overflow -- a tiny,
/// practically-unreachable leak is preferable to a panic in a guest-facing
/// host function.
fn queuePendingTextDestroy(self: *Self, obj_ptr: *?*c.TTF_Text) void {
    if (obj_ptr.*) |obj| {
        if (self.pending_text_destroy_count < self.pending_text_destroys.len) {
            self.pending_text_destroys[self.pending_text_destroy_count] = obj;
            self.pending_text_destroy_count += 1;
        }
        obj_ptr.* = null;
    }
}

/// Must be called with `mutex` already held -- queues every `TTF_Text`
/// pointer this widget owns for later destruction on the main thread. See
/// `destroyWidgetHostFn`, the only caller.
fn queueWidgetTextDestroysLocked(self: *Self, widget: *Widget) void {
    switch (widget.*) {
        .button => |*b| self.queuePendingTextDestroy(&b.text_obj),
        .textfield => |*t| {
            self.queuePendingTextDestroy(&t.text_obj);
            self.queuePendingTextDestroy(&t.placeholder_obj);
        },
        .label => |*l| self.queuePendingTextDestroy(&l.text_obj),
        .container => {},
    }
}

/// Drains the pending-destroy queue -- called once per frame from
/// `main.zig`, on the main thread (the only thread `TTF_DestroyText` is
/// valid to call on for these objects). See the field's doc comment for why
/// this queue exists at all instead of destroying inline in
/// `destroyWidgetHostFn`.
pub fn flushPendingTextDestroys(self: *Self, call_io: Io) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    for (self.pending_text_destroys[0..self.pending_text_destroy_count]) |maybe_obj| {
        if (maybe_obj) |obj| c.TTF_DestroyText(obj);
    }
    self.pending_text_destroy_count = 0;
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
        if (slot.widget == .textfield) {
            slot.widget.textfield.appendText(s);
            // FIT-sized Clay nodes size themselves from content -- a text
            // change can change a Clay-managed widget's geometry, so it
            // needs to force a recompute. A legacy (non-Clay) textfield's
            // text has no effect on any Clay tree, so it shouldn't.
            if (slot.clay_managed) self.layout_generation +%= 1;
        }
    }
}

pub fn backspaceOn(self: *Self, call_io: Io, id: u32) void {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    if (self.findLocked(id)) |slot| {
        if (slot.widget == .textfield) {
            slot.widget.textfield.backspace();
            if (slot.clay_managed) self.layout_generation +%= 1;
        }
    }
}

/// Sets `id` as the sole focused widget (clearing focus on every other
/// slot), or clears focus entirely when `id` is `null`. Returns `true` when
/// the newly focused widget is specifically a `.textfield` -- `main.zig`
/// uses this to decide whether to start/stop `SDL_StartTextInput` without a
/// second registry lookup (focusing a `Button` shouldn't turn on IME/text
/// composition).
pub fn setFocused(self: *Self, call_io: Io, id: ?u32) bool {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    var focused_is_textfield = false;
    for (&self.slots) |*slot| {
        if (slot.*) |*s| {
            const this_one = id != null and s.id == id.?;
            s.widget.setFocusedFlag(this_one);
            if (this_one and s.widget == .textfield) focused_is_textfield = true;
        }
    }
    return focused_is_textfield;
}

/// Keyboard interaction model: every focusable widget's id (see
/// `Widget.isFocusable`), sorted ascending. Ids are assigned by a monotonic
/// counter that's never reused, so ascending id order *is* creation order --
/// but `snapshot()`'s array-index order is not a safe substitute for this
/// once a widget has been destroyed and a new one created afterward (the
/// new widget can land in a freed lower-index slot while carrying a higher
/// id). `main.zig`'s Tab handling calls this fresh on every Tab press
/// rather than caching it, so it never goes stale.
pub fn focusableIdsSorted(self: *Self, call_io: Io, out: []u32) usize {
    self.mutex.lockUncancelable(call_io);
    defer self.mutex.unlock(call_io);
    var n: usize = 0;
    for (self.slots) |slot| {
        if (n >= out.len) break;
        if (slot) |s| {
            if (s.widget.isFocusable()) {
                out[n] = s.id;
                n += 1;
            }
        }
    }
    std.mem.sort(u32, out[0..n], {}, std.sort.asc(u32));
    return n;
}

/// Pure Tab-navigation logic, deliberately kept free of `Io`/locking so it's
/// unit-testable in isolation -- given `ids` (already sorted ascending, see
/// `focusableIdsSorted`) and the currently focused id (`null` if nothing is
/// focused), returns the next (`forward`) or previous (`!forward`) id,
/// wrapping around either end. Returns `null` only when `ids` is empty.
/// `current` not being present in `ids` (e.g. the focused widget was just
/// destroyed) is treated the same as `current == null` -- starts from the
/// beginning (forward) or end (backward) of the list.
pub fn nextFocusable(ids: []const u32, current: ?u32, forward: bool) ?u32 {
    if (ids.len == 0) return null;
    const current_index: ?usize = if (current) |cur| std.mem.indexOfScalar(u32, ids, cur) else null;
    if (current_index) |i| {
        if (forward) {
            return ids[(i + 1) % ids.len];
        } else {
            return ids[(i + ids.len - 1) % ids.len];
        }
    }
    return if (forward) ids[0] else ids[ids.len - 1];
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
};
const ClayContainerRequest = struct { layout: ClayLayoutRequest = .{} };
const ClayButtonRequest = struct { layout: ClayLayoutRequest = .{}, label: []const u8 };
const ClayTextFieldRequest = struct { layout: ClayLayoutRequest = .{}, placeholder: []const u8 = "" };
const ClayLabelRequest = struct { layout: ClayLayoutRequest = .{}, text: []const u8 = "" };

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
    };
}

/// Shared body for all four natyv_clay_create_* host functions: converts
/// the request's `layout` into a real `ClayStyle`, inserts under the
/// registry lock with parent validation, and writes back {"widget_id":N}
/// or {"error":...}. The widget's `rect` is left zeroed at creation time --
/// real geometry is computed output starting in L4, not creation input, so
/// there's nothing meaningful to draw until the first real Clay layout pass
/// runs.
fn insertClayWidget(self: *Self, plugin: ?*c.ExtismCurrentPlugin, out_val: *allowzero c.ExtismVal, widget: Widget, layout: ClayLayoutRequest) void {
    const style = toClayStyle(layout);
    const call_io = self.io();
    self.mutex.lockUncancelable(call_io);
    const result = self.insertLockedWithLayoutValidated(widget, layout.parent_id, style);
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

fn createClayContainerHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayContainerRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const container = Container.init(std.mem.zeroes(c.SDL_FRect));
    insertClayWidget(self, plugin, &outputs[0], .{ .container = container }, parsed.value.layout);
}

fn createClayButtonHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayButtonRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const button = Button.init(std.mem.zeroes(c.SDL_FRect), parsed.value.label);
    insertClayWidget(self, plugin, &outputs[0], .{ .button = button }, parsed.value.layout);
}

fn createClayTextFieldHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayTextFieldRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const field = TextField.init(std.mem.zeroes(c.SDL_FRect), parsed.value.placeholder);
    insertClayWidget(self, plugin, &outputs[0], .{ .textfield = field }, parsed.value.layout);
}

fn createClayLabelHostFn(plugin: ?*c.ExtismCurrentPlugin, inputs: [*c]const c.ExtismVal, n_inputs: c.ExtismSize, outputs: [*c]c.ExtismVal, n_outputs: c.ExtismSize, user_data: ?*anyopaque) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const parsed = parseRequest(ClayLabelRequest, self, plugin, &inputs[0], &outputs[0]) orelse return;
    defer parsed.deinit();
    const label = Label.init(std.mem.zeroes(c.SDL_FRect), parsed.value.text);
    insertClayWidget(self, plugin, &outputs[0], .{ .label = label }, parsed.value.layout);
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
        .container => {},
    }
    if (slot.clay_managed) self.layout_generation +%= 1;
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
        .container => "",
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
