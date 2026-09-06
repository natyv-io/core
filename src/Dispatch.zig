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
const process_memory = @import("process_memory.zig");

/// `wake_event_type` is `main.zig`'s own `SDL_RegisterEvents(1)` result --
/// pushed after every `natyv_dispatch` call below so the main thread's own
/// `SDL_WaitEventTimeout` wakes immediately on a worker-thread-driven
/// widget change, instead of waiting out its own timeout or a real OS
/// event. `SDL_PushEvent` is documented safe to call from any thread
/// (confirmed against SDL3's own header), so no `Io`/cross-thread
/// synchronization is needed for this beyond the call itself.
///
/// Memory-reclamation, real trigger (2026-09-06) -- supersedes the
/// original spike's fixed-dispatch-count stand-in. `recycle_threshold_mb`
/// (sourced from `conf.natyv.json`'s `memory.recycle_threshold_mb`, see
/// `Config.MemoryConfig`) is compared against real process RSS
/// (`process_memory.residentSetSizeBytes`) after every dispatch, since
/// guest code only ever runs inside a host-initiated call
/// (`natyv_init`/`natyv_dispatch`/`natyv_checkpoint`/`natyv_resume`) --
/// RSS structurally can't grow between dispatches, so this loop's own
/// per-dispatch position is already the only place that needs checking, no
/// separate timer thread required. `null` means no automatic recycling at
/// all (checked first, before `runtime.can_recycle`, purely because it's
/// the field most apps will actually leave unset) -- same fail-safe-off
/// posture as every other capability in `Config.zig`. `Runtime.recycle`
/// itself is still a no-op for any app that hasn't declared both
/// `natyv_checkpoint`/`natyv_resume`, so `runtime.can_recycle` is checked
/// too, before ever touching the RSS syscall -- a threshold configured
/// against an app that can't actually recycle should cost nothing.
const recycle_cooldown_dispatches: u32 = 3;

pub fn run(runtime: *Runtime, io: Io, queue: *EventQueue, wake_event_type: u32, recycle_threshold_mb: ?u32) void {
    // Sits alongside the threshold check below, not exposed as its own
    // `conf.natyv.json` field -- a rate limit protecting against thrashing,
    // not a policy choice a dev needs to tune. Once a recycle fires, the
    // RSS check is skipped for this many dispatches before resuming --
    // without it, a threshold configured close to an app's own real
    // post-resume floor would refire a real recycle (a force-close of
    // every open TCP connection, ~30ms measured) on every single
    // subsequent dispatch. Trade-off, stated plainly: RSS can drift above
    // the configured threshold during the cooldown window -- this is a
    // soft ceiling, not a hard one.
    var recycle_cooldown_remaining: u32 = 0;
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

        // Between dispatches, same as every other nested host-function call
        // in this codebase relies on -- see `Runtime.recycle`'s own doc
        // comment for why this window is the safe one. Must run *before*
        // the wake-event push below, not after: `natyv_resume` (called
        // inside `recycle`) mutates widget state exactly the same way a
        // normal dispatch handler does, and needs the same one wake-event
        // to tell the main thread to notice it -- putting the push first
        // (the original shape, before this was found live) leaves resume's
        // own mutation with no wake-event of its own, since nothing pushes
        // a second one afterward. Real, live-caught bug: a resumed
        // instance's Label update and a Button's own click-flash revert
        // could each silently miss their next redraw this way, since the
        // draw-level dirty check gated on `layout_generation` (see
        // `FrameLoop.drawWindow`'s own doc comment) only ever runs when
        // *something* wakes the main thread's event wait in the first
        // place -- not intermittently, but reliably wrong on every real
        // recycle boundary regardless of what triggered it.
        if (recycle_threshold_mb) |threshold_mb| {
            if (runtime.can_recycle) {
                if (recycle_cooldown_remaining > 0) {
                    recycle_cooldown_remaining -= 1;
                } else if (process_memory.residentSetSizeBytes(io)) |rss_bytes| {
                    const threshold_bytes = @as(u64, threshold_mb) * 1024 * 1024;
                    if (rss_bytes >= threshold_bytes) {
                        runtime.recycle(io);
                        recycle_cooldown_remaining = recycle_cooldown_dispatches;
                    }
                } else |err| {
                    std.debug.print("[dispatch] RSS check failed: {}\n", .{err});
                }
            }
        }

        // Wake the main thread's own SDL_WaitEventTimeout unconditionally,
        // regardless of the call above succeeding/failing/returning null --
        // even a failed handler can have mutated state before failing, and
        // the main thread has no other way to learn that promptly. Real
        // possible mutations this guards: any natyv_create_*/natyv_set_*/
        // natyv_destroy_* host function the guest's own dispatch handler
        // calls nested inside natyv_dispatch itself (see this file's own
        // top doc comment), plus (see above) whatever `recycle` itself just
        // did -- the codebase's documented single-plugin-call-in-flight
        // invariant means this is the only place any of those can happen
        // from this thread, so this one push, now placed after both,
        // is complete.
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
