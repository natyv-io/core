//! Host-side system tray state: which trays and menu entries exist, what
//! their real SDL handles are, and a FIFO of not-yet-applied operations the
//! main thread drains each frame.
//!
//! **Why a pending queue at all.** Every `SDL_Tray*` call is documented
//! main-thread-only (`SDL_CreateTray`'s own `\threadsafety`, and the rest
//! "on the thread that created the tray"), but every guest-facing host
//! function runs on the dispatch worker thread. Same cross-thread hand-off
//! `WidgetHost.pending_file_dialog_request`/`pending_window_requests`
//! already established, and for the same reason. A bounded FIFO rather than
//! a single slot, matching `pending_window_requests`' own reasoning: a guest
//! builds a whole menu inside one `natyv_init`, and a single slot would
//! silently drop all but the last entry.
//!
//! **FIFO order is load-bearing, not incidental.** A submenu's entries are
//! queued after the submenu entry that owns them, and an entry's label
//! update after the entry itself -- applying out of order would target a
//! handle that does not exist yet. `takeOps` drains in insertion order and
//! `push` appends, so this holds by construction.
//!
//! **Ids are assigned synchronously, handles are not.** `natyv_tray_*`
//! returns an id immediately, before the main thread has created anything,
//! so a guest can register an `OnClick` and add children in the same
//! dispatch it created the parent in. Exactly what
//! `natyv_clay_create_window` already does with a `window_root` slot. A
//! `handle` of `null` therefore means "queued, not materialized yet", never
//! "broken" -- every mutation path treats it as a no-op rather than an
//! error, since the create op is still ahead of it in the same FIFO.
//!
//! **Ids come from `WidgetHost`, not from a counter here.** A tray entry's
//! click reaches the guest through the ordinary `EventQueue` -> `Dispatch`
//! path, which is keyed on `widget_id` and never validates it against the
//! widget registry. A private counter would collide with real widget ids;
//! `WidgetHost.reserveId` hands out from the same monotonic space instead,
//! which makes collisions structurally impossible rather than unlikely.
//! `capabilities/Tray.zig` does that reservation and passes the id in, so
//! this file stays independent of `WidgetHost`.
//!
//! **Checkbox state is mirrored here.** SDL flips a checkbox entry itself
//! when the user clicks it, so the host cannot just remember what the guest
//! last set. Reading it back means `SDL_GetTrayEntryChecked`, which is
//! main-thread-only -- so the callback (already on the main thread) reads it
//! at click time, stores it, and puts it in the event payload. A guest's
//! `Checked()` then answers from this mirror with no round trip, the same
//! way `Checkbox`'s own widget state is read today.

const std = @import("std");
const Io = std.Io;
const c = @import("c.zig").c;

const Self = @This();

/// Deliberately small. Platforms actively discourage more than one tray
/// icon per app (`SDL_CreateTray`'s own doc: "Avoid needlessly creating a
/// tray icon"), so this is really "one, with room for a mistake" -- same
/// "bump it when a real need shows up" precedent `max_open_windows` set.
pub const max_trays = 4;

/// Entries across every tray and submenu combined. A tray menu that needs
/// more than this is already a usability problem.
pub const max_entries = 64;

/// One frame's worth of queued operations. A guest building a full menu in
/// `natyv_init` queues one op per entry plus a handful of creates, so this
/// holds several complete menus.
pub const max_pending_ops = 128;

pub const max_label_len = 96;
pub const max_tooltip_len = 96;

/// Mirrors SDL's own required-flag set (`SDL_TRAYENTRY_BUTTON`/`_CHECKBOX`/
/// `_SUBMENU`), plus `separator` -- which is not an SDL flag but SDL's
/// documented convention of inserting an entry with a null label.
pub const EntryKind = enum { button, checkbox, submenu, separator };

/// A label copied into host-owned storage at queue time. Guest memory is
/// not guaranteed to outlive the host call that queued the op, the same
/// reason `Button.label_buf` and `PendingWindowRequest.title_buf` are owned
/// buffers rather than slices.
pub const Label = struct {
    buf: [max_label_len]u8 = undefined,
    len: usize = 0,

    pub fn from(s: []const u8) Label {
        var l: Label = .{};
        l.len = @min(s.len, max_label_len);
        @memcpy(l.buf[0..l.len], s[0..l.len]);
        return l;
    }

    pub fn slice(self: *const Label) []const u8 {
        return self.buf[0..self.len];
    }

    /// NUL-terminated copy for the SDL call, written into caller-owned
    /// scratch so the returned pointer's lifetime is the caller's problem
    /// and not this struct's.
    pub fn cString(self: *const Label, scratch: *[max_label_len + 1]u8) [:0]const u8 {
        @memcpy(scratch[0..self.len], self.buf[0..self.len]);
        scratch[self.len] = 0;
        return scratch[0..self.len :0];
    }
};

pub const Tooltip = struct {
    buf: [max_tooltip_len]u8 = undefined,
    len: usize = 0,

    pub fn from(s: []const u8) Tooltip {
        var t: Tooltip = .{};
        t.len = @min(s.len, max_tooltip_len);
        @memcpy(t.buf[0..t.len], s[0..t.len]);
        return t;
    }

    pub fn slice(self: *const Tooltip) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn cString(self: *const Tooltip, scratch: *[max_tooltip_len + 1]u8) [:0]const u8 {
        @memcpy(scratch[0..self.len], self.buf[0..self.len]);
        scratch[self.len] = 0;
        return scratch[0..self.len :0];
    }
};

/// Handed to SDL as a tray callback's `userdata`. Lives inside its own
/// `Entry` slot, so its address is stable for as long as that entry exists
/// -- the same "address stable for the callback's whole life" requirement
/// `FrameLoop.file_dialog_ctx` already has, just one per entry instead of
/// one shared, since many entries can be armed at once.
pub const CallbackContext = struct {
    registry: *Self = undefined,
    entry_id: u32 = 0,
};

pub const Tray = struct {
    id: u32,
    /// `null` until the main thread has run this tray's `.create_tray` op.
    handle: ?*c.SDL_Tray = null,
    /// This tray's root menu, created alongside the tray itself -- SDL
    /// splits `SDL_CreateTray` and `SDL_CreateTrayMenu`, but a tray with no
    /// menu can hold no entries and natyv exposes no way to use one, so the
    /// two are always created together and addressed by the tray's own id.
    menu: ?*c.SDL_TrayMenu = null,
    tooltip: Tooltip = .{},
};

pub const Entry = struct {
    id: u32,
    /// The tray id (for a root-menu entry) or the entry id of the `.submenu`
    /// entry that owns this one. Resolved to a real `*SDL_TrayMenu` at drain
    /// time rather than stored, because the parent's own handle may not
    /// exist yet when this entry is queued.
    parent_id: u32,
    kind: EntryKind,
    handle: ?*c.SDL_TrayEntry = null,
    /// Only ever non-null for `.submenu`, created lazily when the first
    /// child entry is inserted into it.
    submenu: ?*c.SDL_TrayMenu = null,
    label: Label = .{},
    /// Mirror of SDL's own checkbox state -- see this file's header.
    checked: bool = false,
    enabled: bool = true,
    ctx: CallbackContext = .{},
};

pub const Op = union(enum) {
    create_tray: struct { id: u32, tooltip: Tooltip },
    destroy_tray: struct { id: u32 },
    set_tooltip: struct { id: u32, tooltip: Tooltip },
    insert_entry: struct { id: u32, parent_id: u32, pos: i32, kind: EntryKind, label: Label, checked: bool, enabled: bool },
    remove_entry: struct { id: u32 },
    set_entry_label: struct { id: u32, label: Label },
    set_entry_checked: struct { id: u32, checked: bool },
    set_entry_enabled: struct { id: u32, enabled: bool },
};

pub const Error = error{ TooManyTrays, TooManyEntries, OpQueueFull, NoSuchTray, NoSuchEntry };

mutex: Io.Mutex = .init,
trays: [max_trays]?Tray = [_]?Tray{null} ** max_trays,
tray_count: usize = 0,
entries: [max_entries]?Entry = [_]?Entry{null} ** max_entries,
entry_count: usize = 0,
ops: [max_pending_ops]Op = undefined,
op_count: usize = 0,

/// True once at least one tray has been created and not destroyed. Read by
/// `main.zig` to decide whether the app still has a reason to exist after
/// its last window closes -- see `quit_on_last_window_close`.
pub fn hasLiveTray(self: *Self, io: Io) bool {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return self.tray_count > 0;
}

// -- Registration (worker thread) --

/// Records a tray and queues its real creation. `id` must already be
/// reserved from `WidgetHost`'s own id space by the caller.
pub fn createTray(self: *Self, io: Io, id: u32, tooltip: []const u8) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const slot = self.freeTraySlotLocked() orelse return Error.TooManyTrays;
    const tip = Tooltip.from(tooltip);
    self.trays[slot] = .{ .id = id, .tooltip = tip };
    self.tray_count += 1;
    errdefer {
        self.trays[slot] = null;
        self.tray_count -= 1;
    }
    try self.pushOpLocked(.{ .create_tray = .{ .id = id, .tooltip = tip } });
}

pub fn destroyTray(self: *Self, io: Io, id: u32) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    _ = self.findTrayLocked(id) orelse return Error.NoSuchTray;
    try self.pushOpLocked(.{ .destroy_tray = .{ .id = id } });
    // The record itself (and every entry under it) is dropped by the main
    // thread once the real handles are gone -- `SDL_DestroyTray` frees the
    // whole menu tree, so the entry slots have to survive until then or the
    // drain would have nothing to walk.
}

pub fn setTooltip(self: *Self, io: Io, id: u32, tooltip: []const u8) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const idx = self.findTrayLocked(id) orelse return Error.NoSuchTray;
    const tip = Tooltip.from(tooltip);
    self.trays[idx].?.tooltip = tip;
    try self.pushOpLocked(.{ .set_tooltip = .{ .id = id, .tooltip = tip } });
}

/// `parent_id` is either a tray id (insert into that tray's root menu) or a
/// `.submenu` entry's id (insert into its submenu). `pos` follows SDL's own
/// `SDL_InsertTrayEntryAt` convention: -1 appends.
pub fn insertEntry(
    self: *Self,
    io: Io,
    id: u32,
    parent_id: u32,
    pos: i32,
    kind: EntryKind,
    label: []const u8,
    checked: bool,
    enabled: bool,
) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.findTrayLocked(parent_id) == null) {
        const parent_idx = self.findEntryLocked(parent_id) orelse return Error.NoSuchTray;
        if (self.entries[parent_idx].?.kind != .submenu) return Error.NoSuchTray;
    }

    const slot = self.freeEntrySlotLocked() orelse return Error.TooManyEntries;
    const lbl = Label.from(label);
    self.entries[slot] = .{
        .id = id,
        .parent_id = parent_id,
        .kind = kind,
        .label = lbl,
        .checked = checked,
        .enabled = enabled,
    };
    self.entries[slot].?.ctx = .{ .registry = self, .entry_id = id };
    self.entry_count += 1;
    errdefer {
        self.entries[slot] = null;
        self.entry_count -= 1;
    }
    try self.pushOpLocked(.{ .insert_entry = .{
        .id = id,
        .parent_id = parent_id,
        .pos = pos,
        .kind = kind,
        .label = lbl,
        .checked = checked,
        .enabled = enabled,
    } });
}

pub fn removeEntry(self: *Self, io: Io, id: u32) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    _ = self.findEntryLocked(id) orelse return Error.NoSuchEntry;
    try self.pushOpLocked(.{ .remove_entry = .{ .id = id } });
}

pub fn setEntryLabel(self: *Self, io: Io, id: u32, label: []const u8) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const idx = self.findEntryLocked(id) orelse return Error.NoSuchEntry;
    const lbl = Label.from(label);
    self.entries[idx].?.label = lbl;
    try self.pushOpLocked(.{ .set_entry_label = .{ .id = id, .label = lbl } });
}

pub fn setEntryChecked(self: *Self, io: Io, id: u32, checked: bool) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const idx = self.findEntryLocked(id) orelse return Error.NoSuchEntry;
    self.entries[idx].?.checked = checked;
    try self.pushOpLocked(.{ .set_entry_checked = .{ .id = id, .checked = checked } });
}

pub fn setEntryEnabled(self: *Self, io: Io, id: u32, enabled: bool) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const idx = self.findEntryLocked(id) orelse return Error.NoSuchEntry;
    self.entries[idx].?.enabled = enabled;
    try self.pushOpLocked(.{ .set_entry_enabled = .{ .id = id, .enabled = enabled } });
}

/// Reads the mirrored checkbox state -- see this file's header for why this
/// answers from a mirror instead of asking SDL.
pub fn entryChecked(self: *Self, io: Io, id: u32) Error!bool {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const idx = self.findEntryLocked(id) orelse return Error.NoSuchEntry;
    return self.entries[idx].?.checked;
}

// -- Drain (main thread) --

/// Moves every queued op into `out` and empties the queue. Returns how many
/// were written. Caller applies them in the order returned -- see this
/// file's header on why order matters.
pub fn takeOps(self: *Self, io: Io, out: []Op) usize {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const n = @min(self.op_count, out.len);
    @memcpy(out[0..n], self.ops[0..n]);
    // A partial drain (out shorter than the queue) keeps the remainder in
    // order for next frame rather than dropping it.
    if (n < self.op_count) {
        std.mem.copyForwards(Op, self.ops[0 .. self.op_count - n], self.ops[n..self.op_count]);
    }
    self.op_count -= n;
    return n;
}

/// Records the real SDL handles the main thread just created. Separate from
/// `takeOps` so the lock is held for the bookkeeping only, never across an
/// SDL call.
pub fn attachTrayHandles(self: *Self, io: Io, id: u32, handle: *c.SDL_Tray, menu: *c.SDL_TrayMenu) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const idx = self.findTrayLocked(id) orelse return;
    self.trays[idx].?.handle = handle;
    self.trays[idx].?.menu = menu;
}

pub fn attachEntryHandle(self: *Self, io: Io, id: u32, handle: *c.SDL_TrayEntry) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const idx = self.findEntryLocked(id) orelse return;
    self.entries[idx].?.handle = handle;
}

pub fn attachSubmenu(self: *Self, io: Io, id: u32, submenu: *c.SDL_TrayMenu) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const idx = self.findEntryLocked(id) orelse return;
    self.entries[idx].?.submenu = submenu;
}

/// The `*SDL_TrayMenu` a new entry with this `parent_id` belongs in, or null
/// if it is not materialized yet (parent still queued, or a submenu whose
/// own menu has not been created). `needs_submenu` tells the caller it must
/// call `SDL_CreateTraySubmenu` first and then `attachSubmenu`.
pub const ParentMenu = struct { menu: ?*c.SDL_TrayMenu, parent_entry: ?*c.SDL_TrayEntry, needs_submenu: bool };

pub fn parentMenuFor(self: *Self, io: Io, parent_id: u32) ParentMenu {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.findTrayLocked(parent_id)) |idx| {
        return .{ .menu = self.trays[idx].?.menu, .parent_entry = null, .needs_submenu = false };
    }
    if (self.findEntryLocked(parent_id)) |idx| {
        const e = self.entries[idx].?;
        if (e.submenu) |sm| return .{ .menu = sm, .parent_entry = e.handle, .needs_submenu = false };
        return .{ .menu = null, .parent_entry = e.handle, .needs_submenu = e.handle != null };
    }
    return .{ .menu = null, .parent_entry = null, .needs_submenu = false };
}

/// Everything the main thread needs to apply one op to a real handle,
/// snapshotted under the lock so no SDL call happens while it is held.
pub const EntryHandles = struct { handle: ?*c.SDL_TrayEntry, kind: EntryKind, ctx: ?*CallbackContext };

pub fn entryHandles(self: *Self, io: Io, id: u32) ?EntryHandles {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const idx = self.findEntryLocked(id) orelse return null;
    return .{
        .handle = self.entries[idx].?.handle,
        .kind = self.entries[idx].?.kind,
        .ctx = &self.entries[idx].?.ctx,
    };
}

pub fn trayHandle(self: *Self, io: Io, id: u32) ?*c.SDL_Tray {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const idx = self.findTrayLocked(id) orelse return null;
    return self.trays[idx].?.handle;
}

/// Drops a tray's record and every entry underneath it -- called by the main
/// thread after `SDL_DestroyTray`, which frees the whole menu tree at once,
/// so no per-entry SDL teardown is needed or safe.
pub fn forgetTray(self: *Self, io: Io, id: u32) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const idx = self.findTrayLocked(id) orelse return;
    self.trays[idx] = null;
    self.tray_count -= 1;
    // Entries hang off the tray transitively (an entry's parent may be
    // another entry's submenu), so this walks to a fixed point rather than
    // matching `parent_id == id` once.
    var changed = true;
    while (changed) {
        changed = false;
        for (&self.entries) |*maybe| {
            const e = maybe.* orelse continue;
            const parent_gone = self.findTrayLocked(e.parent_id) == null and self.findEntryLocked(e.parent_id) == null;
            if (e.parent_id == id or parent_gone) {
                maybe.* = null;
                self.entry_count -= 1;
                changed = true;
            }
        }
    }
}

pub fn forgetEntry(self: *Self, io: Io, id: u32) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    const idx = self.findEntryLocked(id) orelse return;
    self.entries[idx] = null;
    self.entry_count -= 1;
    // `SDL_RemoveTrayEntry` takes the entry's whole submenu with it.
    var changed = true;
    while (changed) {
        changed = false;
        for (&self.entries) |*maybe| {
            const e = maybe.* orelse continue;
            if (self.findTrayLocked(e.parent_id) == null and self.findEntryLocked(e.parent_id) == null) {
                maybe.* = null;
                self.entry_count -= 1;
                changed = true;
            }
        }
    }
}

/// Records what SDL reports for a checkbox after the user clicked it. Called
/// from the tray callback, which is already on the main thread.
pub fn recordChecked(self: *Self, io: Io, id: u32, checked: bool) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const idx = self.findEntryLocked(id) orelse return;
    self.entries[idx].?.checked = checked;
}

// -- Locked helpers --

fn findTrayLocked(self: *Self, id: u32) ?usize {
    for (self.trays, 0..) |maybe, i| {
        if (maybe) |t| if (t.id == id) return i;
    }
    return null;
}

fn findEntryLocked(self: *Self, id: u32) ?usize {
    for (self.entries, 0..) |maybe, i| {
        if (maybe) |e| if (e.id == id) return i;
    }
    return null;
}

fn freeTraySlotLocked(self: *Self) ?usize {
    for (self.trays, 0..) |maybe, i| {
        if (maybe == null) return i;
    }
    return null;
}

fn freeEntrySlotLocked(self: *Self) ?usize {
    for (self.entries, 0..) |maybe, i| {
        if (maybe == null) return i;
    }
    return null;
}

fn pushOpLocked(self: *Self, op: Op) Error!void {
    if (self.op_count >= max_pending_ops) return Error.OpQueueFull;
    self.ops[self.op_count] = op;
    self.op_count += 1;
}

// -- Tests --
//
// These cover the bookkeeping half only: ids, slot lifetime, queue order
// and the checkbox mirror. Nothing here calls SDL -- every handle stays
// null, which is also the real state a freshly-queued tray is in, so these
// exercise the same "not materialized yet" paths a first frame does. The
// SDL half is main-thread-only and unreachable from a test process with no
// video subsystem, same split `Tcp.zig`'s own glue already lives with.

const testing = std.testing;

test "createTray records the tray and queues exactly one create op" {
    const io = testing.io;
    var reg: Self = .{};

    try reg.createTray(io, 7, "natyv");
    try testing.expect(reg.hasLiveTray(io));

    var ops: [8]Op = undefined;
    try testing.expectEqual(@as(usize, 1), reg.takeOps(io, &ops));
    try testing.expectEqual(@as(u32, 7), ops[0].create_tray.id);
    try testing.expectEqualStrings("natyv", ops[0].create_tray.tooltip.slice());

    // Drained, not merely copied.
    try testing.expectEqual(@as(usize, 0), reg.takeOps(io, &ops));
}

test "ops drain in the order they were queued" {
    const io = testing.io;
    var reg: Self = .{};

    try reg.createTray(io, 1, "t");
    try reg.insertEntry(io, 2, 1, -1, .submenu, "More", false, true);
    try reg.insertEntry(io, 3, 2, -1, .button, "Nested", false, true);
    try reg.setEntryLabel(io, 3, "Renamed");

    var ops: [8]Op = undefined;
    try testing.expectEqual(@as(usize, 4), reg.takeOps(io, &ops));
    // Order is load-bearing: entry 3 lives in entry 2's submenu, and the
    // rename targets a handle that only exists once the insert has run.
    try testing.expect(ops[0] == .create_tray);
    try testing.expectEqual(@as(u32, 2), ops[1].insert_entry.id);
    try testing.expectEqual(@as(u32, 3), ops[2].insert_entry.id);
    try testing.expectEqual(@as(u32, 3), ops[3].set_entry_label.id);
}

test "a partial drain keeps the remainder queued, still in order" {
    const io = testing.io;
    var reg: Self = .{};

    try reg.createTray(io, 1, "t");
    try reg.insertEntry(io, 2, 1, -1, .button, "A", false, true);
    try reg.insertEntry(io, 3, 1, -1, .button, "B", false, true);

    // A main thread with a smaller scratch buffer than the queue must not
    // silently drop the tail -- it comes back next frame, in order.
    var small: [2]Op = undefined;
    try testing.expectEqual(@as(usize, 2), reg.takeOps(io, &small));
    try testing.expect(small[0] == .create_tray);
    try testing.expectEqual(@as(u32, 2), small[1].insert_entry.id);

    try testing.expectEqual(@as(usize, 1), reg.takeOps(io, &small));
    try testing.expectEqual(@as(u32, 3), small[0].insert_entry.id);
}

test "an entry can only be parented to a tray or to a submenu entry" {
    const io = testing.io;
    var reg: Self = .{};

    try reg.createTray(io, 1, "t");
    try reg.insertEntry(io, 2, 1, -1, .button, "Plain", false, true);

    // A plain button has no submenu to insert into -- SDL would have
    // nothing to hand `SDL_InsertTrayEntryAt`, so this is rejected at queue
    // time rather than becoming a silently-dropped op at drain time.
    try testing.expectError(Error.NoSuchTray, reg.insertEntry(io, 3, 2, -1, .button, "Child", false, true));
    // ...and an id that is neither is rejected the same way.
    try testing.expectError(Error.NoSuchTray, reg.insertEntry(io, 4, 999, -1, .button, "Orphan", false, true));
}

test "checkbox state mirrors what SDL reports, not what the guest last set" {
    const io = testing.io;
    var reg: Self = .{};

    try reg.createTray(io, 1, "t");
    try reg.insertEntry(io, 2, 1, -1, .checkbox, "Notify", true, true);
    try testing.expect(try reg.entryChecked(io, 2));

    // The user clicking the entry flips it inside SDL with no guest
    // involvement at all; the callback writes back what it read.
    reg.recordChecked(io, 2, false);
    try testing.expect(!(try reg.entryChecked(io, 2)));

    // A guest set still works and is still visible.
    try reg.setEntryChecked(io, 2, true);
    try testing.expect(try reg.entryChecked(io, 2));
}

test "forgetTray drops entries nested under it, not just its direct children" {
    const io = testing.io;
    var reg: Self = .{};

    try reg.createTray(io, 1, "t");
    try reg.insertEntry(io, 2, 1, -1, .submenu, "More", false, true);
    try reg.insertEntry(io, 3, 2, -1, .button, "Nested", false, true);
    try testing.expectEqual(@as(usize, 2), reg.entry_count);

    // SDL_DestroyTray frees the whole menu tree in one call, so the records
    // have to follow transitively -- entry 3's parent is entry 2, not the
    // tray, and a one-level sweep would leak it.
    reg.forgetTray(io, 1);
    try testing.expect(!reg.hasLiveTray(io));
    try testing.expectEqual(@as(usize, 0), reg.entry_count);
    try testing.expectError(Error.NoSuchEntry, reg.entryChecked(io, 3));
}

test "removing a submenu entry takes its children with it" {
    const io = testing.io;
    var reg: Self = .{};

    try reg.createTray(io, 1, "t");
    try reg.insertEntry(io, 2, 1, -1, .submenu, "More", false, true);
    try reg.insertEntry(io, 3, 2, -1, .button, "Nested", false, true);
    try reg.insertEntry(io, 4, 1, -1, .button, "Sibling", false, true);

    reg.forgetEntry(io, 2);
    try testing.expectError(Error.NoSuchEntry, reg.entryChecked(io, 3));
    // The sibling is parented to the tray, not to the removed entry.
    try testing.expect((try reg.entryChecked(io, 4)) == false);
}

test "running out of entry slots is a real error, not a silent drop" {
    const io = testing.io;
    var reg: Self = .{};

    try reg.createTray(io, 1, "t");
    var i: u32 = 0;
    while (i < max_entries) : (i += 1) {
        try reg.insertEntry(io, 100 + i, 1, -1, .button, "x", false, true);
    }
    try testing.expectError(Error.TooManyEntries, reg.insertEntry(io, 9999, 1, -1, .button, "one too many", false, true));
}

test "a label longer than the buffer is truncated, never overruns it" {
    const io = testing.io;
    var reg: Self = .{};

    const long = "x" ** (max_label_len * 2);
    try reg.createTray(io, 1, "t");
    try reg.insertEntry(io, 2, 1, -1, .button, long, false, true);

    var ops: [4]Op = undefined;
    _ = reg.takeOps(io, &ops);
    try testing.expectEqual(@as(usize, max_label_len), ops[1].insert_entry.label.slice().len);
}

test "cString NUL-terminates into caller scratch" {
    const label = Label.from("Quit");
    var scratch: [max_label_len + 1]u8 = undefined;
    const z = label.cString(&scratch);
    try testing.expectEqualStrings("Quit", z);
    try testing.expectEqual(@as(u8, 0), z.ptr[z.len]);
}
