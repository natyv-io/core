//! Worker-thread loop: pops queued UI events and calls the guest's single
//! `natyv_dispatch(event_bytes) -> response_bytes` export for each one --
//! the host-runtime event contract decided before this was ever built (see
//! project memory). Must run off the thread that owns the window/render
//! loop, same as every guest call in this project: `extism_plugin_call`
//! blocks, and on macOS SDL's event pump/rendering must stay on the main
//! thread regardless.
//!
//! What the guest does with a dispatch response is entirely up to it --
//! this loop doesn't interpret it, just logs it. A guest mutates its own UI
//! by calling natyv_create_button/natyv_destroy_widget/etc. *during* its
//! own natyv_dispatch handler, the same way add_book already calls
//! sqlite_exec during its own handler -- nested host-function calls, not a
//! host-side response format this loop needs to understand.

const std = @import("std");
const Io = std.Io;
const json_util = @import("json_util.zig");
const EventQueue = @import("EventQueue.zig");
const Runtime = @import("Runtime.zig");

pub fn run(runtime: *Runtime, io: Io, queue: *EventQueue) void {
    while (true) {
        const event = queue.pop(io) orelse break;
        defer queue.freeEntry(event);

        var allocator_buf: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
        const payload = buildDispatchPayload(fba.allocator(), event) catch {
            std.debug.print("[dispatch] failed to build payload for widget {d}\n", .{event.widget_id});
            continue;
        };

        if (runtime.call(io, "natyv_dispatch", payload)) |resp| {
            std.debug.print("[dispatch] widget={d} type={s} -> {s}\n", .{ event.widget_id, @tagName(event.event_type), resp });
        }
    }
    std.debug.print("[dispatch] worker shutting down\n", .{});
}

fn buildDispatchPayload(allocator: std.mem.Allocator, event: EventQueue.Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    // W5: surface_id (0 = root/main surface) is a top-level sibling on
    // every dispatch event, not nested under payload -- see
    // FloatingOrder.surfaceIdFor's doc comment for why.
    try out.print(allocator, "{{\"widget_id\":{d},\"event_type\":\"{s}\",\"surface_id\":{d},\"payload\":", .{ event.widget_id, @tagName(event.event_type), event.surface_id });
    try json_util.writeString(&out, allocator, event.payload);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}
