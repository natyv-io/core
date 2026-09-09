//! Host-owned persisted state: registers `natyv_persist_get_or_init`/
//! `natyv_persist_set`/`natyv_persist_free` as Extism host functions over
//! `../PersistStore.zig`'s real key/value + freed-keys logic. This is the
//! real mechanism behind the Go SDK's `natyv.Persisted[T]` -- see
//! `project_natyv_ergonomics_layer` memory and
//! `~/.claude/plans/lexical-wishing-penguin.md` for the full design and why
//! it exists (state lives host-side from the moment it's written, so a
//! guest recycle -- destroy and recreate the WASM instance to reclaim
//! memory the guest can never give back on its own -- never loses it).
//!
//! This file is deliberately thin -- pure JSON-parse/format glue over
//! `PersistStore`'s own logic, which lives directly in `src/` (not here)
//! specifically so it can have its own clean, standalone test root with no
//! C-import/module-root entanglement -- see that file's own doc comment.
//! No dedicated test root exists for *this* file, matching `Tcp.zig`'s own
//! capabilities-glue precedent (its host-fn callbacks aren't unit-tested
//! directly either); this glue is covered by the real end-to-end
//! verification in `~/.claude/plans/lexical-wishing-penguin.md`'s own
//! Tests section instead.
//!
//! Wire contract (JSON both directions; `"default"`/`"value"` carry
//! already-`persistjson`-encoded bytes -- valid JSON text, always valid
//! UTF-8 -- embedded as an ordinary escaped JSON string, no base64 needed
//! the way `Tcp.zig`'s binary payloads need it; the host never parses this
//! text, matching the "host is a dumb byte-slice store" design):
//!   natyv_persist_get_or_init: in {"key":"...","default":"<json text>"}
//!                              out {"value":"<json text>"} (present or newly-created)
//!                                | {"value":null}           (freed -- do not recreate)
//!                                | {"error":"..."}
//!   natyv_persist_set:         in {"key":"...","value":"<json text>"}
//!                              out {} | {"error":"..."}
//!   natyv_persist_free:        in {"key":"..."}
//!                              out {} | {"error":"..."}
//!
//! `natyv_persist_get_or_init`'s create-if-absent semantics are load-bearing,
//! not incidental: `natyv.Persisted[T](key, default)` unconditionally
//! re-registers on every instance boot (fresh or resumed), so this primitive
//! must return whatever's already there rather than overwrite it -- getting
//! this backwards would make every recycle quietly reset every persisted
//! value to its default. A freed key stays freed until an explicit
//! `natyv_persist_set` -- the automatic startup flush (`FlushPersisted()`,
//! Go SDK) must never silently resurrect one, which is exactly why "freed"
//! is a real third state, not just an absent key -- see `PersistStore.zig`.

const std = @import("std");
const c = @import("../c.zig").c;
const host_fn_util = @import("../host_fn_util.zig");
const PersistStore = @import("../PersistStore.zig");

const Self = @This();

pub const host_function_count = 3;

store: PersistStore,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .store = PersistStore.init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.store.deinit();
}

pub fn registerInto(self: *Self, funcs_out: []?*const c.ExtismFunction) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    funcs_out[0] = c.extism_function_new("natyv_persist_get_or_init", &in_types[0], 1, &out_types[0], 1, getOrInitHostFn, self, null);
    funcs_out[1] = c.extism_function_new("natyv_persist_set", &in_types[0], 1, &out_types[0], 1, setHostFn, self, null);
    funcs_out[2] = c.extism_function_new("natyv_persist_free", &in_types[0], 1, &out_types[0], 1, freeHostFn, self, null);
    return host_function_count;
}

const GetOrInitRequest = struct { key: []const u8, default: []const u8 };

fn getOrInitHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.store.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.store.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(GetOrInitRequest, self.store.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();
    const req = parsed.value;

    const result = self.store.getOrInit(req.key, req.default) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
        return;
    };

    switch (result) {
        .freed => host_fn_util.writeGuestBytes(plugin, &outputs[0], "{\"value\":null}"),
        .value => |v| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.store.allocator);
            out.appendSlice(self.store.allocator, "{\"value\":\"") catch {
                host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
                return;
            };
            PersistStore.appendJsonEscaped(&out, self.store.allocator, v) catch {
                host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
                return;
            };
            out.appendSlice(self.store.allocator, "\"}") catch {
                host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
                return;
            };
            host_fn_util.writeGuestBytes(plugin, &outputs[0], out.items);
        },
    }
}

const SetRequest = struct { key: []const u8, value: []const u8 };

fn setHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.store.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.store.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(SetRequest, self.store.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();
    const req = parsed.value;

    self.store.setValue(req.key, req.value) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
        return;
    };
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{}");
}

const FreeRequest = struct { key: []const u8 };

fn freeHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.store.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.store.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(FreeRequest, self.store.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();

    self.store.freeKey(parsed.value.key) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
        return;
    };
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{}");
}
