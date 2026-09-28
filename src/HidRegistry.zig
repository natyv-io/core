//! Registry of open HID devices, one reader thread per device -- see
//! `natyv-hid-capability` memory for the full design.
//!
//! **Why input reports arrive as events, not through a `hid_read` call.** A
//! guest can't wake itself: the host only ever calls it for `natyv_init`, a
//! dispatched event, or a recycle. So a guest has nothing to hang a periodic
//! read off, and for a macropad the keypress *is* the event. Each open device
//! gets a reader thread that pushes every report onto `EventQueue` as
//! `.hid_report`, addressed to the device's handle id.
//!
//! **One thread per device, blocking with a timeout.** `SDL_hid_read_timeout`
//! returns the moment a report lands, so latency is whatever the device's own
//! polling interval is. The ~100ms timeout exists only so the thread notices
//! `stop`; an idle device costs a wakeup ten times a second, not a spin. One
//! shared thread round-robining N devices would add up to N timeouts of
//! latency to a keypress, or else poll at zero timeout and never sleep.
//! hidapi forbids two threads touching *one* device, not one thread per
//! device, and `max_devices` bounds the thread count.
//!
//! **No `Io.Mutex`, same as `TcpRegistry`, but for a different reason than
//! "only one plugin call is in flight".** Every mutation of `slots` happens
//! on one thread at a time: the dispatch worker during a host call or a
//! recycle, or the main thread at shutdown after that worker has been joined.
//! A reader thread never touches `slots` -- it reads its own `Device`'s
//! `id`/`handle` (fixed for the thread's whole life, since a slot is only
//! freed after its thread is joined) and the two atomics, and pushes onto
//! `EventQueue`, which has its own mutex. Nothing here is shared that a lock
//! would protect.
//!
//! **Ids come from `WidgetHost.reserveId`**, passed in by
//! `capabilities/Hid.zig` -- a report reaches the guest through the ordinary
//! `EventQueue` -> `Dispatch` path, which is keyed on `widget_id`, so a
//! private counter here would collide with real widget ids. Same reasoning
//! `TrayRegistry`'s header gives.
//!
//! **A handle outlives a recycle.** A HID device keeps no session state in
//! guest memory (unlike a TCP connection mid-protocol, which is why
//! `TcpRegistry.closeAll` runs on recycle), so the resumed guest can simply
//! reopen the same path and get the same id back (`claimByPath`). Anything it
//! doesn't reopen during `natyv_resume` is closed by `closeUnclaimed`, so a
//! device the new instance no longer wants can't hold a slot forever.
//!
//! Device I/O goes through `Backend` so the tests below can run real reader
//! threads against a scripted fake device -- `sdl_backend` is the only one
//! the app uses.

const std = @import("std");
const Io = std.Io;
const c = @import("c.zig").c;
const EventQueue = @import("EventQueue.zig");
const Hid = @import("Hid.zig");

const Self = @This();

/// Matches `TcpRegistry.max_connections` -- one macropad plus room for a few
/// more, not a device farm. Also the reader-thread cap.
pub const max_devices = 8;

/// Reports allowed to wait in `EventQueue` per device before new ones are
/// dropped and counted. A person pressing keys never gets near this; it only
/// bites a device streaming continuously (a sensor at 1kHz) faster than the
/// guest drains.
pub const max_queued_reports = 64;

/// Largest report read in one go. Full-speed USB HID tops out at 64 bytes and
/// high-speed at 1024; hidapi truncates anything longer to the buffer.
pub const report_buf_len = 1024;

/// Only how often a reader checks `stop` -- see the file header.
const read_timeout_ms = 100;

/// Base64 of a full report, plus room for the `{"data":"...","dropped":N}`
/// wrapper.
const payload_buf_len = std.base64.standard.Encoder.calcSize(report_buf_len) + 48;

pub const Backend = struct {
    /// `SDL_hid_read_timeout`'s contract: bytes read, 0 on timeout, -1 once
    /// the device is gone.
    read: *const fn (handle: *anyopaque, buf: []u8, timeout_ms: i32) i32,
    /// `SDL_hid_write`'s: bytes written, or -1.
    write: *const fn (handle: *anyopaque, data: []const u8) i32,
    close: *const fn (handle: *anyopaque) void,
};

pub const sdl_backend: Backend = .{
    .read = sdlRead,
    .write = sdlWrite,
    .close = sdlClose,
};

fn sdlRead(handle: *anyopaque, buf: []u8, timeout_ms: i32) i32 {
    return c.SDL_hid_read_timeout(@ptrCast(handle), buf.ptr, buf.len, timeout_ms);
}

fn sdlWrite(handle: *anyopaque, data: []const u8) i32 {
    return c.SDL_hid_write(@ptrCast(handle), data.ptr, data.len);
}

fn sdlClose(handle: *anyopaque) void {
    _ = c.SDL_hid_close(@ptrCast(handle));
}

pub const Device = struct {
    id: u32,
    handle: *anyopaque,
    /// Kept so a resumed guest reopening the same path gets this handle back
    /// -- see `claimByPath`.
    path: Hid.Path,
    thread: std.Thread = undefined,
    stop: std.atomic.Value(bool) = .init(false),
    /// Set by the reader when a read fails. The slot stays until the guest
    /// closes it (its id is still the guest's to close), but it's never
    /// handed out again by `claimByPath` -- a replugged device can come back
    /// under the same path (Linux reuses `/dev/hidrawN`) and deserves a fresh
    /// open, not this dead handle.
    disconnected: std.atomic.Value(bool) = .init(false),
    /// Cleared for every device when a recycle starts, set again by
    /// `claimByPath` -- see `closeUnclaimed`.
    claimed: bool = true,
};

pub const InsertError = error{ TooManyDevices, ThreadSpawnFailed };
pub const WriteError = error{ NoSuchDevice, Disconnected, WriteFailed };

queue: *EventQueue,
backend: *const Backend,
slots: [max_devices]?Device = @splat(null),

pub fn init(queue: *EventQueue, backend: *const Backend) Self {
    return .{ .queue = queue, .backend = backend };
}

/// The id of a live device already open at `path`, marking it claimed -- so
/// `hid_open` is idempotent per path, and a resumed guest reopening its
/// devices gets back the ids its checkpoint remembers. `null` means the
/// caller should open it for real.
pub fn claimByPath(self: *Self, path: []const u8) ?u32 {
    for (&self.slots) |*slot| {
        const dev = &(slot.* orelse continue);
        if (dev.disconnected.load(.acquire)) continue;
        if (!std.mem.eql(u8, dev.path.slice(), path)) continue;
        dev.claimed = true;
        return dev.id;
    }
    return null;
}

/// Takes ownership of `handle` and starts its reader. On error the handle is
/// closed here, so the caller never has to.
pub fn insert(self: *Self, io: Io, id: u32, handle: *anyopaque, path: []const u8) InsertError!void {
    std.debug.assert(path.len <= Hid.max_path_len);
    const idx = for (self.slots, 0..) |slot, i| {
        if (slot == null) break i;
    } else {
        self.backend.close(handle);
        return error.TooManyDevices;
    };

    self.slots[idx] = .{ .id = id, .handle = handle, .path = .{ .len = path.len } };
    const dev = &self.slots[idx].?;
    @memcpy(dev.path.buf[0..path.len], path);
    // Spawned only once the slot is fully written: the reader reads `id` and
    // `handle` from it, and they never change again until it's joined.
    dev.thread = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, readerLoop, .{ self, io, dev }) catch {
        self.backend.close(handle);
        self.slots[idx] = null;
        return error.ThreadSpawnFailed;
    };
}

pub fn write(self: *Self, id: u32, data: []const u8) WriteError!void {
    const dev = self.find(id) orelse return error.NoSuchDevice;
    if (dev.disconnected.load(.acquire)) return error.Disconnected;
    if (self.backend.write(dev.handle, data) < 0) return error.WriteFailed;
}

/// Stops the reader, closes the device, and drops any of its reports still
/// queued. A no-op for an id that isn't open, matching `TcpRegistry.close`.
pub fn close(self: *Self, io: Io, id: u32) void {
    for (&self.slots) |*slot| {
        const dev = &(slot.* orelse continue);
        if (dev.id != id) continue;
        dev.stop.store(true, .release);
        self.finishClose(io, slot);
        return;
    }
}

/// Every device, for shutdown. All readers are told to stop before any is
/// joined, so this waits one read timeout in total rather than one each.
pub fn closeAll(self: *Self, io: Io) void {
    for (&self.slots) |*slot| {
        if (slot.*) |*dev| dev.stop.store(true, .release);
    }
    for (&self.slots) |*slot| {
        if (slot.* != null) self.finishClose(io, slot);
    }
}

/// Called as a recycle starts, before `natyv_resume` -- every device must be
/// reclaimed by the resumed guest or `closeUnclaimed` closes it.
pub fn markAllUnclaimed(self: *Self) void {
    for (&self.slots) |*slot| {
        if (slot.*) |*dev| dev.claimed = false;
    }
}

/// Undoes `markAllUnclaimed` when a recycle fails -- the old instance keeps
/// running and still owns every device it had.
pub fn markAllClaimed(self: *Self) void {
    for (&self.slots) |*slot| {
        if (slot.*) |*dev| dev.claimed = true;
    }
}

/// Called once `natyv_resume` has succeeded: closes whatever the resumed
/// guest didn't reopen. Same stop-all-then-join shape as `closeAll`.
pub fn closeUnclaimed(self: *Self, io: Io) void {
    for (&self.slots) |*slot| {
        if (slot.*) |*dev| {
            if (!dev.claimed) dev.stop.store(true, .release);
        }
    }
    for (&self.slots) |*slot| {
        if (slot.*) |*dev| {
            if (!dev.claimed) self.finishClose(io, slot);
        }
    }
}

pub fn openCount(self: *const Self) usize {
    var n: usize = 0;
    for (self.slots) |slot| {
        if (slot != null) n += 1;
    }
    return n;
}

fn find(self: *Self, id: u32) ?*Device {
    for (&self.slots) |*slot| {
        const dev = &(slot.* orelse continue);
        if (dev.id == id) return dev;
    }
    return null;
}

/// Order matters: join before closing (the reader may be inside a read on
/// this handle), and purge the queue after joining (the reader may have
/// pushed one last report on its way out).
fn finishClose(self: *Self, io: Io, slot: *?Device) void {
    const dev = &slot.*.?;
    dev.thread.join();
    self.backend.close(dev.handle);
    self.queue.removeAllFor(io, dev.id);
    slot.* = null;
}

fn readerLoop(self: *Self, io: Io, dev: *Device) void {
    var report: [report_buf_len]u8 = undefined;
    var payload: [payload_buf_len]u8 = undefined;
    // Reports refused by the queue since the last one it accepted. Carried
    // on the next accepted report so a guest always learns it lost some,
    // then reset.
    var dropped: u32 = 0;
    while (!dev.stop.load(.acquire)) {
        const n = self.backend.read(dev.handle, &report, read_timeout_ms);
        if (n < 0) {
            dev.disconnected.store(true, .release);
            // Unbounded on purpose: at most one per device, and a guest has
            // to learn its device is gone even with a full backlog.
            self.queue.push(io, dev.id, .hid_disconnected, "{}", 0);
            return;
        }
        if (n == 0) continue;
        const json = formatReport(&payload, report[0..@intCast(n)], dropped);
        if (self.queue.pushBounded(io, dev.id, .hid_report, json, 0, max_queued_reports)) {
            dropped = 0;
        } else {
            dropped +|= 1;
        }
    }
}

fn formatReport(buf: *[payload_buf_len]u8, report: []const u8, dropped: u32) []const u8 {
    var b64: [std.base64.standard.Encoder.calcSize(report_buf_len)]u8 = undefined;
    // Base64's alphabet never needs JSON escaping.
    const encoded = std.base64.standard.Encoder.encode(&b64, report);
    return if (dropped == 0)
        std.fmt.bufPrint(buf, "{{\"data\":\"{s}\"}}", .{encoded}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{{\"data\":\"{s}\",\"dropped\":{d}}}", .{ encoded, dropped }) catch unreachable;
}

// --- Tests: real reader threads against a scripted fake device. ---

/// A fake device the test drives by hand. `reports` is handed out one per
/// read; once empty, reads time out (sleeping briefly, like the real thing)
/// until `unplug` makes them fail.
const FakeDevice = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    reports: [16][]const u8 = undefined,
    report_count: usize = 0,
    next: usize = 0,
    unplugged: bool = false,
    closed: std.atomic.Value(bool) = .init(false),
    written: [64]u8 = undefined,
    written_len: usize = 0,

    fn feed(self: *FakeDevice, report: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reports[self.report_count] = report;
        self.report_count += 1;
    }

    fn unplug(self: *FakeDevice) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.unplugged = true;
    }

    fn fakeRead(handle: *anyopaque, buf: []u8, timeout_ms: i32) i32 {
        _ = timeout_ms;
        const self: *FakeDevice = @ptrCast(@alignCast(handle));
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.next < self.report_count) {
                const r = self.reports[self.next];
                self.next += 1;
                @memcpy(buf[0..r.len], r);
                return @intCast(r.len);
            }
            if (self.unplugged) return -1;
        }
        self.io.sleep(.fromMilliseconds(1), .awake) catch {};
        return 0;
    }

    fn fakeWrite(handle: *anyopaque, data: []const u8) i32 {
        const self: *FakeDevice = @ptrCast(@alignCast(handle));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.unplugged) return -1;
        @memcpy(self.written[0..data.len], data);
        self.written_len = data.len;
        return @intCast(data.len);
    }

    fn fakeClose(handle: *anyopaque) void {
        const self: *FakeDevice = @ptrCast(@alignCast(handle));
        self.closed.store(true, .release);
    }

    const backend: Backend = .{ .read = fakeRead, .write = fakeWrite, .close = fakeClose };
};

/// Polls until `queue` holds `want` entries or a second passes -- reader
/// threads push asynchronously, so tests wait for the result rather than
/// sleeping a fixed amount.
fn waitForQueueLen(io: Io, queue: *EventQueue, want: usize) !void {
    var tries: usize = 0;
    while (tries < 1000) : (tries += 1) {
        {
            queue.mutex.lockUncancelable(io);
            defer queue.mutex.unlock(io);
            if (queue.items.items.len == want) return;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestTimedOut;
}

test "reports arrive as hid_report events addressed to the handle, in order" {
    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var queue = EventQueue.init(allocator);
    defer queue.deinit();
    var registry = Self.init(&queue, &FakeDevice.backend);
    defer registry.closeAll(io);

    var fake: FakeDevice = .{ .io = io };
    fake.feed(&.{ 0x01, 0x02 });
    fake.feed(&.{0xFF});
    try registry.insert(io, 42, &fake, "/dev/hidraw1");
    try waitForQueueLen(io, &queue, 2);

    const first = queue.pop(io).?;
    defer queue.freeEntry(first);
    try std.testing.expectEqual(@as(u32, 42), first.widget_id);
    try std.testing.expectEqual(EventQueue.EventType.hid_report, first.event_type);
    try std.testing.expectEqualStrings("{\"data\":\"AQI=\"}", first.payload);
    const second = queue.pop(io).?;
    defer queue.freeEntry(second);
    try std.testing.expectEqualStrings("{\"data\":\"/w==\"}", second.payload);
}

test "past the queued-report cap, reports are dropped and the next one delivered carries the count" {
    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var queue = EventQueue.init(allocator);
    defer queue.deinit();
    var registry = Self.init(&queue, &FakeDevice.backend);
    defer registry.closeAll(io);

    // Fill the queue to the cap with reports the reader will see as already
    // waiting, so its own next two are refused.
    for (0..max_queued_reports) |_| queue.push(io, 7, .hid_report, "{}", 0);
    var fake: FakeDevice = .{ .io = io };
    fake.feed(&.{1});
    fake.feed(&.{2});
    try registry.insert(io, 7, &fake, "p");
    while (true) {
        fake.mutex.lockUncancelable(io);
        const consumed = fake.next == 2;
        fake.mutex.unlock(io);
        if (consumed) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(usize, max_queued_reports), queue.items.items.len);

    // Room again: the next report goes through and reports both losses.
    const drained = queue.pop(io).?;
    queue.freeEntry(drained);
    fake.feed(&.{3});
    try waitForQueueLen(io, &queue, max_queued_reports);
    const last = queue.items.items[queue.items.items.len - 1];
    try std.testing.expectEqualStrings("{\"data\":\"Aw==\",\"dropped\":2}", last.payload);

    // The count is reported once, then starts over.
    const drained_again = queue.pop(io).?;
    queue.freeEntry(drained_again);
    fake.feed(&.{4});
    try waitForQueueLen(io, &queue, max_queued_reports);
    const after = queue.items.items[queue.items.items.len - 1];
    try std.testing.expectEqualStrings("{\"data\":\"BA==\"}", after.payload);
}

test "unplugging pushes one hid_disconnected, fails writes, and isn't reclaimable by path" {
    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var queue = EventQueue.init(allocator);
    defer queue.deinit();
    var registry = Self.init(&queue, &FakeDevice.backend);
    defer registry.closeAll(io);

    var fake: FakeDevice = .{ .io = io };
    try registry.insert(io, 5, &fake, "/dev/hidraw1");
    try registry.write(5, &.{ 0, 9 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 9 }, fake.written[0..fake.written_len]);

    fake.unplug();
    try waitForQueueLen(io, &queue, 1);
    try std.testing.expectEqual(EventQueue.EventType.hid_disconnected, queue.items.items[0].event_type);
    try std.testing.expectError(error.Disconnected, registry.write(5, &.{0}));
    try std.testing.expectEqual(@as(?u32, null), registry.claimByPath("/dev/hidraw1"));
    // Still the guest's to close -- the slot stays until it does.
    try std.testing.expectEqual(@as(usize, 1), registry.openCount());
    registry.close(io, 5);
    try std.testing.expectEqual(@as(usize, 0), registry.openCount());
}

test "close joins the reader, closes the device, and purges its queued reports" {
    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var queue = EventQueue.init(allocator);
    defer queue.deinit();
    var registry = Self.init(&queue, &FakeDevice.backend);
    defer registry.closeAll(io);

    var fake: FakeDevice = .{ .io = io };
    fake.feed(&.{1});
    try registry.insert(io, 3, &fake, "a");
    queue.push(io, 99, .click, "other", 0);
    try waitForQueueLen(io, &queue, 2);

    registry.close(io, 3);
    try std.testing.expect(fake.closed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqual(@as(u32, 99), queue.items.items[0].widget_id);
    try std.testing.expectError(error.NoSuchDevice, registry.write(3, &.{0}));
    registry.close(io, 3); // closing again is a no-op
}

test "the device cap rejects the next insert and closes its handle; a close frees a slot" {
    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var queue = EventQueue.init(allocator);
    defer queue.deinit();
    var registry = Self.init(&queue, &FakeDevice.backend);
    defer registry.closeAll(io);

    var fakes: [max_devices + 1]FakeDevice = @splat(.{ .io = io });
    for (0..max_devices) |i| try registry.insert(io, @intCast(i + 1), &fakes[i], "p");
    try std.testing.expectError(error.TooManyDevices, registry.insert(io, 100, &fakes[max_devices], "p"));
    try std.testing.expect(fakes[max_devices].closed.load(.acquire));

    registry.close(io, 1);
    fakes[max_devices].closed.store(false, .release);
    try registry.insert(io, 100, &fakes[max_devices], "p");
    try std.testing.expectEqual(@as(usize, max_devices), registry.openCount());
}

test "recycle: reclaimed devices keep their id, unclaimed ones are closed" {
    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var queue = EventQueue.init(allocator);
    defer queue.deinit();
    var registry = Self.init(&queue, &FakeDevice.backend);
    defer registry.closeAll(io);

    var kept: FakeDevice = .{ .io = io };
    var dropped: FakeDevice = .{ .io = io };
    try registry.insert(io, 10, &kept, "/dev/hidraw1");
    try registry.insert(io, 11, &dropped, "/dev/hidraw2");

    registry.markAllUnclaimed();
    try std.testing.expectEqual(@as(?u32, 10), registry.claimByPath("/dev/hidraw1"));
    registry.closeUnclaimed(io);

    try std.testing.expect(!kept.closed.load(.acquire));
    try std.testing.expect(dropped.closed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), registry.openCount());
    try std.testing.expectEqual(@as(?u32, 10), registry.claimByPath("/dev/hidraw1"));
}

test "recycle: a failed resume restores every claim, so nothing is swept later" {
    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var queue = EventQueue.init(allocator);
    defer queue.deinit();
    var registry = Self.init(&queue, &FakeDevice.backend);
    defer registry.closeAll(io);

    var fake: FakeDevice = .{ .io = io };
    try registry.insert(io, 10, &fake, "p");
    registry.markAllUnclaimed();
    registry.markAllClaimed();
    registry.closeUnclaimed(io);
    try std.testing.expect(!fake.closed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), registry.openCount());
}
