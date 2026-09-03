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
const c = @import("c.zig").c;
const json_util = @import("json_util.zig");
const EventQueue = @import("EventQueue.zig");
const Runtime = @import("Runtime.zig");

/// `wake_event_type` is `main.zig`'s own `SDL_RegisterEvents(1)` result --
/// pushed after every `natyv_dispatch` call below so the main thread's own
/// `SDL_WaitEventTimeout` wakes immediately on a worker-thread-driven
/// widget change, instead of waiting out its own timeout or a real OS
/// event. `SDL_PushEvent` is documented safe to call from any thread
/// (confirmed against SDL3's own header), so no `Io`/cross-thread
/// synchronization is needed for this beyond the call itself.
pub fn run(runtime: *Runtime, io: Io, queue: *EventQueue, wake_event_type: u32) void {
    while (true) {
        const event = queue.pop(io) orelse break;
        defer queue.freeEntry(event);

        // W10: bumped from 512 -- TextField's payloads always fit
        // comfortably under that, but TextArea's (up to 1023 bytes of
        // content, plus JSON-escaping overhead and the envelope itself)
        // wouldn't. Under the old size, a large-enough TextArea's
        // `.text_changed` event would silently fail to reach the guest
        // (buildDispatchPayload's OutOfMemory just gets logged and
        // dropped below, no crash) -- caught by reading this file before
        // picking TextArea's max_len, not by hitting the bug live.
        var allocator_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
        const payload = buildDispatchPayload(fba.allocator(), event) catch {
            std.debug.print("[dispatch] failed to build payload for widget {d}\n", .{event.widget_id});
            continue;
        };

        if (runtime.call(io, "natyv_dispatch", payload)) |resp| {
            std.debug.print("[dispatch] widget={d} type={s} -> {s}\n", .{ event.widget_id, @tagName(event.event_type), resp });
        }

        // Wake the main thread's own SDL_WaitEventTimeout unconditionally,
        // regardless of the call above succeeding/failing/returning null --
        // even a failed handler can have mutated state before failing, and
        // the main thread has no other way to learn that promptly. Real
        // possible mutations this guards: any natyv_create_*/natyv_set_*/
        // natyv_destroy_* host function the guest's own dispatch handler
        // calls nested inside natyv_dispatch itself (see this file's own
        // top doc comment) -- the codebase's documented single-plugin-
        // call-in-flight invariant means this is the only place any of
        // those can happen from this thread, so this one push is complete.
        var wake_event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        wake_event.type = wake_event_type;
        _ = c.SDL_PushEvent(&wake_event);
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
