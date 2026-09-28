//! The pure logic behind the Canvas widget's drawing: the wire format a
//! guest sends, the validation every command goes through, and the store of
//! validated drawings keyed by canvas widget id. Dependency-free (no
//! `c.zig`, no `host_fn_util.zig`) for the same reason as `PersistStore.zig`
//! -- it gets its own clean, standalone test root.
//!
//! A drawing is a retained display list: the guest replaces a canvas's
//! whole list in one host call and the host redraws from it until the next
//! replacement. There is deliberately no per-frame guest draw callback --
//! guest code runs on the dispatch worker, drawing is main-thread only, and
//! a host-side list survives an instance recycle untouched. The vocabulary
//! is host-defined data, never guest-authored rendering code.
//!
//! Wire format (the `commands` array is drawn in order, later on top):
//!
//!   {"widget_id": 7, "commands": [
//!     {"line":     {"x1":0,"y1":0,"x2":10,"y2":10,"width":1,"color":C}},
//!     {"polyline": {"points":[[0,0],[5,3],[9,1]],"width":2,"color":C}},
//!     {"rect":     {"x":0,"y":0,"w":10,"h":5,"fill":C,"stroke":C,"stroke_width":1,"radius":2}},
//!     {"circle":   {"cx":5,"cy":5,"r":3,"fill":C}},
//!     {"polygon":  {"points":[[0,0],[9,0],[4,7]],"fill":C}},
//!     {"arc":      {"cx":5,"cy":5,"r":4,"start":0,"end":1.57,"fill":C}},
//!     {"text":     {"x":0,"y":0,"text":"Q3","color":C,"align":"center"}}
//!   ]}
//!
//! where C is `{"r":..,"g":..,"b":..,"a":..}`, 0..1 floats like every other
//! natyv color. Coordinates are logical pixels from the canvas's top-left.
//! Arc angles are radians, clockwise from +x (y points down) -- the same
//! convention as HTML canvas; a filled arc is a pie wedge, a stroked one an
//! arc segment. Each command is a single-key object so `std.json` parses it
//! straight into `CommandRequest`'s tagged union, rejecting unknown ops and
//! unknown or duplicate fields with no hand-written parser.
//!
//! An invalid or over-limit list is rejected whole and the canvas keeps its
//! previous drawing -- nothing is ever truncated or clamped into validity.

const std = @import("std");

const Self = @This();

/// Canvases and their drawings live host-side and survive recycling, so
/// every dimension is capped. Worst case per canvas is about 1.3 MB of
/// stored drawing, so 32 canvases bound the store near 40 MB.
pub const max_canvases = 32;
pub const max_commands = 8192;
/// Summed over every polyline and polygon in one drawing.
pub const max_points = 65536;
pub const max_text_bytes = 256;
/// Summed over every text command in one drawing.
pub const max_total_text_bytes = 256 * 1024;
/// Checked before parsing, so a huge request can't make `std.json` build a
/// huge tree first. Comfortably above a maxed-out drawing's encoding.
pub const max_request_bytes = 4 * 1024 * 1024;
/// Every coordinate and length. Far past any real canvas, and small enough
/// that 2x supersampling times any plausible pixel density stays exactly
/// representable and well inside `i32` once rendering converts to ints.
pub const max_coord = 100_000;
pub const max_stroke_width = 1024;
/// Radians. Any span past a full turn draws a full circle; the bound only
/// keeps the trigonometry precise.
pub const max_angle = 1024;
/// The largest laid-out canvas that gets rendered (per side, logical px).
pub const max_size = 4096;

pub const ColorRequest = struct { r: f32, g: f32, b: f32, a: f32 = 1 };
pub const Point = [2]f32;
pub const Align = enum { left, center, right };

pub const CommandRequest = union(enum) {
    line: struct { x1: f32, y1: f32, x2: f32, y2: f32, width: f32 = 1, color: ColorRequest },
    polyline: struct { points: []const Point, width: f32 = 1, color: ColorRequest },
    rect: struct { x: f32, y: f32, w: f32, h: f32, fill: ?ColorRequest = null, stroke: ?ColorRequest = null, stroke_width: f32 = 1, radius: f32 = 0 },
    circle: struct { cx: f32, cy: f32, r: f32, fill: ?ColorRequest = null, stroke: ?ColorRequest = null, stroke_width: f32 = 1 },
    polygon: struct { points: []const Point, fill: ?ColorRequest = null, stroke: ?ColorRequest = null, stroke_width: f32 = 1 },
    arc: struct { cx: f32, cy: f32, r: f32, start: f32, end: f32, fill: ?ColorRequest = null, stroke: ?ColorRequest = null, stroke_width: f32 = 1 },
    text: struct { x: f32, y: f32, text: []const u8, color: ColorRequest, @"align": Align = .left },
};

pub const SetRequest = struct { widget_id: u32, commands: []const CommandRequest };

pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };

/// Fill and/or stroke for a closed shape -- at least one is always set.
pub const Paint = struct { fill: ?Color, stroke: ?Color, stroke_width: f32 };

/// Indexes into `Drawing.points` or `Drawing.text`, so a command stays small
/// and a whole drawing is three allocations however many commands it has.
pub const Span = struct { start: u32, len: u32 };

pub const Command = union(enum) {
    line: struct { from: Point, to: Point, width: f32, color: Color },
    polyline: struct { points: Span, width: f32, color: Color },
    rect: struct { x: f32, y: f32, w: f32, h: f32, radius: f32, paint: Paint },
    circle: struct { center: Point, r: f32, paint: Paint },
    polygon: struct { points: Span, paint: Paint },
    arc: struct { center: Point, r: f32, start: f32, end: f32, paint: Paint },
    text: struct { pos: Point, text: Span, color: Color, @"align": Align },
};

/// A validated drawing. Every value in it has passed `build`'s checks, so
/// rendering can use it without re-validating.
pub const Drawing = struct {
    commands: []Command = &.{},
    points: []Point = &.{},
    text: []u8 = &.{},

    pub fn deinit(self: *Drawing, allocator: std.mem.Allocator) void {
        allocator.free(self.commands);
        allocator.free(self.points);
        allocator.free(self.text);
        self.* = .{};
    }

    pub fn pointsOf(self: *const Drawing, span: Span) []const Point {
        return self.points[span.start..][0..span.len];
    }

    pub fn textOf(self: *const Drawing, span: Span) []const u8 {
        return self.text[span.start..][0..span.len];
    }
};

/// Why `build` rejected a list. `reason` is always a static string and
/// never echoes guest text, so it's safe to put in an error response
/// unescaped (`host_fn_util.writeErrorJson` doesn't escape).
pub const Diagnostic = struct {
    /// The offending command's index, or null for a whole-list problem.
    command: ?usize = null,
    reason: []const u8 = "",
};

pub const BuildError = error{ Invalid, OutOfMemory };

/// Parses a raw `natyv_canvas_set` request. The caller owns the result and
/// must keep it alive while using `.value` (its slices point into the
/// parse arena).
pub fn parseSetRequest(allocator: std.mem.Allocator, bytes: []const u8, diag: *Diagnostic) BuildError!std.json.Parsed(SetRequest) {
    if (bytes.len > max_request_bytes) return fail(diag, null, "request too large");
    return std.json.parseFromSlice(SetRequest, allocator, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // `std.json`'s error names are the most specific detail it gives,
        // and they are fixed strings, not guest bytes.
        else => fail(diag, null, @errorName(err)),
    };
}

/// Validates `requests` and copies them into a compact, owned `Drawing`.
/// On `error.Invalid`, `diag` says which command and why; nothing is
/// allocated.
pub fn build(allocator: std.mem.Allocator, requests: []const CommandRequest, diag: *Diagnostic) BuildError!Drawing {
    if (requests.len > max_commands) return fail(diag, null, "too many commands");

    // Validate everything and size the storage first, so a rejected list
    // allocates nothing.
    var point_count: usize = 0;
    var text_bytes: usize = 0;
    for (requests, 0..) |req, i| {
        if (validate(req)) |reason| return fail(diag, i, reason);
        switch (req) {
            .polyline => |p| point_count += p.points.len,
            .polygon => |p| point_count += p.points.len,
            .text => |t| text_bytes += t.text.len,
            else => {},
        }
        if (point_count > max_points) return fail(diag, i, "too many points in drawing");
        if (text_bytes > max_total_text_bytes) return fail(diag, i, "too much text in drawing");
    }

    var drawing: Drawing = .{};
    errdefer drawing.deinit(allocator);
    drawing.commands = try allocator.alloc(Command, requests.len);
    drawing.points = try allocator.alloc(Point, point_count);
    drawing.text = try allocator.alloc(u8, text_bytes);

    var points_used: u32 = 0;
    var text_used: u32 = 0;
    for (requests, drawing.commands) |req, *out| {
        out.* = switch (req) {
            .line => |l| .{ .line = .{ .from = .{ l.x1, l.y1 }, .to = .{ l.x2, l.y2 }, .width = l.width, .color = toColor(l.color) } },
            .polyline => |p| .{ .polyline = .{ .points = copyPoints(&drawing, &points_used, p.points), .width = p.width, .color = toColor(p.color) } },
            .rect => |r| .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .radius = r.radius, .paint = toPaint(r.fill, r.stroke, r.stroke_width) } },
            .circle => |ci| .{ .circle = .{ .center = .{ ci.cx, ci.cy }, .r = ci.r, .paint = toPaint(ci.fill, ci.stroke, ci.stroke_width) } },
            .polygon => |p| .{ .polygon = .{ .points = copyPoints(&drawing, &points_used, p.points), .paint = toPaint(p.fill, p.stroke, p.stroke_width) } },
            .arc => |a| .{ .arc = .{ .center = .{ a.cx, a.cy }, .r = a.r, .start = a.start, .end = a.end, .paint = toPaint(a.fill, a.stroke, a.stroke_width) } },
            .text => |t| blk: {
                const span: Span = .{ .start = text_used, .len = @intCast(t.text.len) };
                @memcpy(drawing.text[text_used..][0..t.text.len], t.text);
                text_used += span.len;
                break :blk .{ .text = .{ .pos = .{ t.x, t.y }, .text = span, .color = toColor(t.color), .@"align" = t.@"align" } };
            },
        };
    }
    std.debug.assert(points_used == drawing.points.len and text_used == drawing.text.len);
    return drawing;
}

fn fail(diag: *Diagnostic, command: ?usize, reason: []const u8) error{Invalid} {
    diag.* = .{ .command = command, .reason = reason };
    return error.Invalid;
}

/// Returns why `req` is invalid, or null if it's fine. Every float is
/// checked finite and in range here -- `std.json` turns an out-of-range
/// literal like `1e999` into `inf`, and a non-finite value reaching an
/// int conversion during rendering is illegal behavior in ReleaseSmall.
fn validate(req: CommandRequest) ?[]const u8 {
    switch (req) {
        .line => |l| {
            if (!coord(l.x1) or !coord(l.y1) or !coord(l.x2) or !coord(l.y2)) return "coordinate out of range";
            if (!strokeWidth(l.width)) return "width out of range";
            if (!color(l.color)) return "color out of range";
        },
        .polyline => |p| {
            if (p.points.len < 2) return "polyline needs at least 2 points";
            if (!points(p.points)) return "coordinate out of range";
            if (!strokeWidth(p.width)) return "width out of range";
            if (!color(p.color)) return "color out of range";
        },
        .rect => |r| {
            if (!coord(r.x) or !coord(r.y)) return "coordinate out of range";
            if (!length(r.w) or !length(r.h)) return "size out of range";
            if (!length(r.radius)) return "radius out of range";
            if (paint(r.fill, r.stroke, r.stroke_width)) |reason| return reason;
        },
        .circle => |ci| {
            if (!coord(ci.cx) or !coord(ci.cy)) return "coordinate out of range";
            if (!length(ci.r)) return "radius out of range";
            if (paint(ci.fill, ci.stroke, ci.stroke_width)) |reason| return reason;
        },
        .polygon => |p| {
            if (p.points.len < 3) return "polygon needs at least 3 points";
            if (!points(p.points)) return "coordinate out of range";
            if (paint(p.fill, p.stroke, p.stroke_width)) |reason| return reason;
        },
        .arc => |a| {
            if (!coord(a.cx) or !coord(a.cy)) return "coordinate out of range";
            if (!length(a.r)) return "radius out of range";
            if (!angle(a.start) or !angle(a.end)) return "angle out of range";
            if (paint(a.fill, a.stroke, a.stroke_width)) |reason| return reason;
        },
        .text => |t| {
            if (!coord(t.x) or !coord(t.y)) return "coordinate out of range";
            if (t.text.len > max_text_bytes) return "text too long";
            if (!std.unicode.utf8ValidateSlice(t.text)) return "text is not valid UTF-8";
            if (!color(t.color)) return "color out of range";
        },
    }
    return null;
}

fn paint(fill: ?ColorRequest, stroke: ?ColorRequest, stroke_width: f32) ?[]const u8 {
    if (fill == null and stroke == null) return "needs a fill or a stroke";
    if (fill) |f| if (!color(f)) return "color out of range";
    if (stroke) |s| if (!color(s)) return "color out of range";
    if (!strokeWidth(stroke_width)) return "stroke_width out of range";
    return null;
}

// The range comparisons alone already reject NaN (every comparison with it
// is false) and inf; the explicit `isFinite` states the intent rather than
// leaning on that.
fn coord(v: f32) bool {
    return std.math.isFinite(v) and @abs(v) <= max_coord;
}

fn length(v: f32) bool {
    return std.math.isFinite(v) and v >= 0 and v <= max_coord;
}

/// A zero width draws nothing, which is always a bug in the caller.
fn strokeWidth(v: f32) bool {
    return std.math.isFinite(v) and v > 0 and v <= max_stroke_width;
}

fn angle(v: f32) bool {
    return std.math.isFinite(v) and @abs(v) <= max_angle;
}

fn channel(v: f32) bool {
    return std.math.isFinite(v) and v >= 0 and v <= 1;
}

fn color(col: ColorRequest) bool {
    return channel(col.r) and channel(col.g) and channel(col.b) and channel(col.a);
}

fn points(pts: []const Point) bool {
    for (pts) |p| if (!coord(p[0]) or !coord(p[1])) return false;
    return true;
}

fn toColor(col: ColorRequest) Color {
    return .{ .r = col.r, .g = col.g, .b = col.b, .a = col.a };
}

fn toPaint(fill: ?ColorRequest, stroke: ?ColorRequest, stroke_width: f32) Paint {
    return .{
        .fill = if (fill) |f| toColor(f) else null,
        .stroke = if (stroke) |s| toColor(s) else null,
        .stroke_width = stroke_width,
    };
}

fn copyPoints(drawing: *Drawing, used: *u32, pts: []const Point) Span {
    const span: Span = .{ .start = used.*, .len = @intCast(pts.len) };
    @memcpy(drawing.points[used.*..][0..pts.len], pts);
    used.* += span.len;
    return span;
}

/// One canvas's current drawing. `version` bumps on every replacement, so
/// the renderer can tell its cached texture is stale without comparing
/// lists.
pub const Entry = struct {
    drawing: Drawing = .{},
    version: u32 = 0,
};

pub const StoreError = error{ LimitExceeded, AlreadyExists, NoSuchCanvas, OutOfMemory };

allocator: std.mem.Allocator,
canvases: std.AutoHashMapUnmanaged(u32, Entry) = .empty,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    var it = self.canvases.valueIterator();
    while (it.next()) |entry| entry.drawing.deinit(self.allocator);
    self.canvases.deinit(self.allocator);
}

/// Registers a new, empty canvas. Called when the canvas widget is
/// created, so the canvas cap is enforced at creation rather than on the
/// first draw.
pub fn add(self: *Self, id: u32) StoreError!void {
    if (self.canvases.contains(id)) return error.AlreadyExists;
    if (self.canvases.count() >= max_canvases) return error.LimitExceeded;
    try self.canvases.put(self.allocator, id, .{});
}

/// Drops a canvas and its drawing. Removing an unknown id is a no-op, so
/// widget teardown doesn't need to know whether a canvas was ever added.
pub fn remove(self: *Self, id: u32) void {
    if (self.canvases.fetchRemove(id)) |kv| {
        var drawing = kv.value.drawing;
        drawing.deinit(self.allocator);
    }
}

/// Borrowed -- valid only until the next `set`/`remove` for this id.
pub fn get(self: *const Self, id: u32) ?*const Entry {
    return self.canvases.getPtr(id);
}

pub const SetError = StoreError || BuildError;

/// Validates `requests` and, only if the whole list is valid, replaces the
/// canvas's drawing with it. Any failure leaves the previous drawing in
/// place.
pub fn set(self: *Self, id: u32, requests: []const CommandRequest, diag: *Diagnostic) SetError!void {
    const entry = self.canvases.getPtr(id) orelse return error.NoSuchCanvas;
    const drawing = try build(self.allocator, requests, diag);
    entry.drawing.deinit(self.allocator);
    entry.drawing = drawing;
    entry.version +%= 1;
}

// --- tests ---

const testing = std.testing;

/// Parses `json` as a full set request and builds it, returning the
/// diagnostic's reason on rejection so tests can assert on it.
fn buildJson(json: []const u8, diag: *Diagnostic) BuildError!Drawing {
    const parsed = try parseSetRequest(testing.allocator, json, diag);
    defer parsed.deinit();
    return build(testing.allocator, parsed.value.commands, diag);
}

fn expectRejected(json: []const u8, command: ?usize, reason: []const u8) !void {
    var diag: Diagnostic = .{};
    try testing.expectError(error.Invalid, buildJson(json, &diag));
    try testing.expectEqual(command, diag.command);
    try testing.expectEqualStrings(reason, diag.reason);
}

const red = "{\"r\":1,\"g\":0,\"b\":0}";

test "build: every op round-trips into compact storage" {
    var diag: Diagnostic = .{};
    var drawing = try buildJson(
        \\{"widget_id":1,"commands":[
        \\ {"line":{"x1":0,"y1":1,"x2":2,"y2":3,"width":2,"color":{"r":1,"g":0,"b":0}}},
        \\ {"polyline":{"points":[[0,0],[5,3],[9,1]],"color":{"r":0,"g":1,"b":0,"a":0.5}}},
        \\ {"rect":{"x":1,"y":2,"w":3,"h":4,"fill":{"r":0,"g":0,"b":1},"radius":2}},
        \\ {"circle":{"cx":5,"cy":6,"r":7,"stroke":{"r":0,"g":0,"b":0},"stroke_width":3}},
        \\ {"polygon":{"points":[[0,0],[9,0],[4,7]],"fill":{"r":1,"g":1,"b":1}}},
        \\ {"arc":{"cx":5,"cy":5,"r":4,"start":0,"end":1.5,"fill":{"r":1,"g":0,"b":0}}},
        \\ {"text":{"x":3,"y":4,"text":"Q3 é","color":{"r":0,"g":0,"b":0},"align":"center"}},
        \\ {"text":{"x":0,"y":0,"text":"","color":{"r":0,"g":0,"b":0}}}
        \\]}
    , &diag);
    defer drawing.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 8), drawing.commands.len);
    try testing.expectEqual(@as(usize, 6), drawing.points.len);

    const line = drawing.commands[0].line;
    try testing.expectEqual(Point{ 2, 3 }, line.to);
    try testing.expectEqual(@as(f32, 2), line.width);

    const polyline = drawing.commands[1].polyline;
    try testing.expectEqualSlices(Point, &.{ .{ 0, 0 }, .{ 5, 3 }, .{ 9, 1 } }, drawing.pointsOf(polyline.points));
    try testing.expectEqual(@as(f32, 1), polyline.width);
    try testing.expectEqual(@as(f32, 0.5), polyline.color.a);

    const rect = drawing.commands[2].rect;
    try testing.expectEqual(@as(f32, 2), rect.radius);
    try testing.expect(rect.paint.fill != null and rect.paint.stroke == null);
    // Alpha defaults to opaque, like every other natyv color.
    try testing.expectEqual(@as(f32, 1), rect.paint.fill.?.a);

    try testing.expectEqual(@as(f32, 3), drawing.commands[3].circle.paint.stroke_width);
    try testing.expectEqualSlices(Point, &.{ .{ 0, 0 }, .{ 9, 0 }, .{ 4, 7 } }, drawing.pointsOf(drawing.commands[4].polygon.points));
    try testing.expectEqual(@as(f32, 1.5), drawing.commands[5].arc.end);

    const text = drawing.commands[6].text;
    try testing.expectEqualStrings("Q3 \u{e9}", drawing.textOf(text.text));
    try testing.expectEqual(Align.center, text.@"align");
    try testing.expectEqual(Align.left, drawing.commands[7].text.@"align");
    try testing.expectEqualStrings("", drawing.textOf(drawing.commands[7].text.text));
}

test "build: an empty list is a valid, empty drawing" {
    var diag: Diagnostic = .{};
    var drawing = try buildJson("{\"widget_id\":1,\"commands\":[]}", &diag);
    defer drawing.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), drawing.commands.len);
}

test "parse: unknown ops, unknown fields, duplicates and missing fields are rejected" {
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"bezier\":{}}]}", null, "UnknownField");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"circle\":{\"cx\":0,\"cy\":0,\"r\":1,\"radius\":2,\"fill\":" ++ red ++ "}}]}", null, "UnknownField");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"circle\":{\"cx\":0,\"cx\":1,\"cy\":0,\"r\":1,\"fill\":" ++ red ++ "}}]}", null, "DuplicateField");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"circle\":{\"cx\":0,\"r\":1,\"fill\":" ++ red ++ "}}]}", null, "MissingField");
    // Two ops in one command object is ambiguous, not "draw both".
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"circle\":{\"cx\":0,\"cy\":0,\"r\":1,\"fill\":" ++ red ++ "},\"rect\":{}}]}", null, "UnexpectedToken");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"text\":{\"x\":0,\"y\":0,\"text\":\"a\",\"color\":" ++ red ++ ",\"align\":\"justify\"}}]}", null, "InvalidEnumTag");
}

test "parse: an oversized request is rejected before parsing" {
    const big = try testing.allocator.alloc(u8, max_request_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    var diag: Diagnostic = .{};
    try testing.expectError(error.Invalid, parseSetRequest(testing.allocator, big, &diag));
    try testing.expectEqualStrings("request too large", diag.reason);
}

test "validate: non-finite numbers are rejected wherever they appear" {
    // `1e999` is how inf reaches us -- `std.json` rejects a bare NaN/Infinity
    // token outright, but parses an out-of-range literal as inf.
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"line\":{\"x1\":1e999,\"y1\":0,\"x2\":1,\"y2\":1,\"color\":" ++ red ++ "}}]}", 0, "coordinate out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"polyline\":{\"points\":[[0,0],[0,-1e999]],\"color\":" ++ red ++ "}}]}", 0, "coordinate out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"rect\":{\"x\":0,\"y\":0,\"w\":1e999,\"h\":1,\"fill\":" ++ red ++ "}}]}", 0, "size out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"arc\":{\"cx\":0,\"cy\":0,\"r\":1,\"start\":0,\"end\":1e999,\"fill\":" ++ red ++ "}}]}", 0, "angle out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"circle\":{\"cx\":0,\"cy\":0,\"r\":1,\"stroke\":" ++ red ++ ",\"stroke_width\":1e999}}]}", 0, "stroke_width out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"text\":{\"x\":0,\"y\":0,\"text\":\"a\",\"color\":{\"r\":1e999,\"g\":0,\"b\":0}}}]}", 0, "color out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"line\":{\"x1\":NaN,\"y1\":0,\"x2\":1,\"y2\":1,\"color\":" ++ red ++ "}}]}", null, "SyntaxError");

    // And NaN built in code rather than parsed: the range checks must not
    // be fooled by NaN comparing false to everything.
    const nan = std.math.nan(f32);
    const c: ColorRequest = .{ .r = 0, .g = 0, .b = 0 };
    const cases = [_]CommandRequest{
        .{ .line = .{ .x1 = nan, .y1 = 0, .x2 = 0, .y2 = 0, .color = c } },
        .{ .rect = .{ .x = 0, .y = 0, .w = nan, .h = 1, .fill = c } },
        .{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .radius = nan, .fill = c } },
        .{ .circle = .{ .cx = 0, .cy = 0, .r = 1, .fill = .{ .r = nan, .g = 0, .b = 0 } } },
        .{ .arc = .{ .cx = 0, .cy = 0, .r = 1, .start = nan, .end = 0, .fill = c } },
        .{ .polyline = .{ .points = &.{ .{ 0, 0 }, .{ 0, 0 } }, .width = nan, .color = c } },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        try testing.expectError(error.Invalid, build(testing.allocator, &.{case}, &diag));
        try testing.expectEqual(@as(?usize, 0), diag.command);
    }
}

test "validate: out-of-range values are rejected, boundaries accepted" {
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"rect\":{\"x\":0,\"y\":0,\"w\":-1,\"h\":1,\"fill\":" ++ red ++ "}}]}", 0, "size out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"circle\":{\"cx\":0,\"cy\":0,\"r\":-0.5,\"fill\":" ++ red ++ "}}]}", 0, "radius out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"rect\":{\"x\":0,\"y\":0,\"w\":1,\"h\":1,\"radius\":-1,\"fill\":" ++ red ++ "}}]}", 0, "radius out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"line\":{\"x1\":100001,\"y1\":0,\"x2\":1,\"y2\":1,\"color\":" ++ red ++ "}}]}", 0, "coordinate out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"line\":{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"width\":0,\"color\":" ++ red ++ "}}]}", 0, "width out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"line\":{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"width\":1025,\"color\":" ++ red ++ "}}]}", 0, "width out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"line\":{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"color\":{\"r\":1.01,\"g\":0,\"b\":0}}}]}", 0, "color out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"line\":{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"color\":{\"r\":1,\"g\":0,\"b\":0,\"a\":-0.1}}}]}", 0, "color out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"arc\":{\"cx\":0,\"cy\":0,\"r\":1,\"start\":-1025,\"end\":0,\"fill\":" ++ red ++ "}}]}", 0, "angle out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"polygon\":{\"points\":[[0,0],[1,0],[0,-100001]],\"fill\":" ++ red ++ "}}]}", 0, "coordinate out of range");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"circle\":{\"cx\":0,\"cy\":0,\"r\":1,\"fill\":" ++ red ++ ",\"stroke\":{\"r\":0,\"g\":2,\"b\":0}}}]}", 0, "color out of range");

    var diag: Diagnostic = .{};
    var drawing = try buildJson(
        \\{"widget_id":1,"commands":[
        \\ {"line":{"x1":-100000,"y1":100000,"x2":0,"y2":0,"width":1024,"color":{"r":0,"g":1,"b":0,"a":0}}},
        \\ {"rect":{"x":0,"y":0,"w":0,"h":100000,"radius":0,"stroke":{"r":1,"g":1,"b":1},"stroke_width":1024}},
        \\ {"arc":{"cx":0,"cy":0,"r":0,"start":-1024,"end":1024,"stroke":{"r":1,"g":1,"b":1}}}
        \\]}
    , &diag);
    drawing.deinit(testing.allocator);
}

test "validate: shape rules" {
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"rect\":{\"x\":0,\"y\":0,\"w\":1,\"h\":1}}]}", 0, "needs a fill or a stroke");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"polyline\":{\"points\":[[0,0]],\"color\":" ++ red ++ "}}]}", 0, "polyline needs at least 2 points");
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"polygon\":{\"points\":[[0,0],[1,1]],\"fill\":" ++ red ++ "}}]}", 0, "polygon needs at least 3 points");
    // The index points at the bad command, not the first one.
    try expectRejected("{\"widget_id\":1,\"commands\":[{\"circle\":{\"cx\":0,\"cy\":0,\"r\":1,\"fill\":" ++ red ++ "}},{\"circle\":{\"cx\":0,\"cy\":0,\"r\":1}}]}", 1, "needs a fill or a stroke");
}

test "validate: text length and encoding" {
    const c: ColorRequest = .{ .r = 0, .g = 0, .b = 0 };
    const long = [_]u8{'a'} ** (max_text_bytes + 1);
    var diag: Diagnostic = .{};
    try testing.expectError(error.Invalid, build(testing.allocator, &.{.{ .text = .{ .x = 0, .y = 0, .text = &long, .color = c } }}, &diag));
    try testing.expectEqualStrings("text too long", diag.reason);

    var drawing = try build(testing.allocator, &.{.{ .text = .{ .x = 0, .y = 0, .text = long[0..max_text_bytes], .color = c } }}, &diag);
    drawing.deinit(testing.allocator);

    try testing.expectError(error.Invalid, build(testing.allocator, &.{.{ .text = .{ .x = 0, .y = 0, .text = "ok\xff", .color = c } }}, &diag));
    try testing.expectEqualStrings("text is not valid UTF-8", diag.reason);
}

test "limits: commands, points and total text" {
    const c: ColorRequest = .{ .r = 0, .g = 0, .b = 0 };
    var diag: Diagnostic = .{};

    const dot: CommandRequest = .{ .circle = .{ .cx = 0, .cy = 0, .r = 1, .fill = c } };
    const commands = try testing.allocator.alloc(CommandRequest, max_commands + 1);
    defer testing.allocator.free(commands);
    @memset(commands, dot);
    var drawing = try build(testing.allocator, commands[0..max_commands], &diag);
    drawing.deinit(testing.allocator);
    try testing.expectError(error.Invalid, build(testing.allocator, commands, &diag));
    try testing.expectEqualStrings("too many commands", diag.reason);
    try testing.expectEqual(@as(?usize, null), diag.command);

    // The point cap is per drawing, so it trips across commands, not only
    // within one.
    const pts = try testing.allocator.alloc(Point, max_points / 2);
    defer testing.allocator.free(pts);
    @memset(pts, .{ 0, 0 });
    const half: CommandRequest = .{ .polyline = .{ .points = pts, .color = c } };
    drawing = try build(testing.allocator, &.{ half, half }, &diag);
    drawing.deinit(testing.allocator);
    const tri: CommandRequest = .{ .polygon = .{ .points = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } }, .fill = c } };
    try testing.expectError(error.Invalid, build(testing.allocator, &.{ half, half, tri }, &diag));
    try testing.expectEqualStrings("too many points in drawing", diag.reason);
    try testing.expectEqual(@as(?usize, 2), diag.command);

    const label: CommandRequest = .{ .text = .{ .x = 0, .y = 0, .text = &([_]u8{'a'} ** max_text_bytes), .color = c } };
    const labels_allowed = max_total_text_bytes / max_text_bytes;
    @memset(commands[0 .. labels_allowed + 1], label);
    drawing = try build(testing.allocator, commands[0..labels_allowed], &diag);
    drawing.deinit(testing.allocator);
    try testing.expectError(error.Invalid, build(testing.allocator, commands[0 .. labels_allowed + 1], &diag));
    try testing.expectEqualStrings("too much text in drawing", diag.reason);
}

test "build: failing allocations leak nothing" {
    const c: ColorRequest = .{ .r = 0, .g = 0, .b = 0 };
    const requests = [_]CommandRequest{
        .{ .polygon = .{ .points = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } }, .fill = c } },
        .{ .text = .{ .x = 0, .y = 0, .text = "hi", .color = c } },
    };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, reqs: []const CommandRequest) !void {
            var diag: Diagnostic = .{};
            var drawing = try build(allocator, reqs, &diag);
            drawing.deinit(allocator);
        }
    }.run, .{&requests});
}

test "store: add, set, get, remove" {
    var self = Self.init(testing.allocator);
    defer self.deinit();
    const c: ColorRequest = .{ .r = 0, .g = 0, .b = 0 };
    var diag: Diagnostic = .{};

    try testing.expectError(error.NoSuchCanvas, self.set(9, &.{}, &diag));
    try self.add(9);
    try testing.expectError(error.AlreadyExists, self.add(9));
    try testing.expectEqual(@as(u32, 0), self.get(9).?.version);
    try testing.expectEqual(@as(usize, 0), self.get(9).?.drawing.commands.len);

    try self.set(9, &.{.{ .circle = .{ .cx = 1, .cy = 2, .r = 3, .fill = c } }}, &diag);
    try testing.expectEqual(@as(u32, 1), self.get(9).?.version);
    try testing.expectEqual(@as(f32, 3), self.get(9).?.drawing.commands[0].circle.r);

    self.remove(9);
    try testing.expect(self.get(9) == null);
    self.remove(9);
}

test "store: a rejected set keeps the previous drawing and version" {
    var self = Self.init(testing.allocator);
    defer self.deinit();
    const c: ColorRequest = .{ .r = 0, .g = 0, .b = 0 };
    var diag: Diagnostic = .{};

    try self.add(1);
    try self.set(1, &.{.{ .text = .{ .x = 0, .y = 0, .text = "kept", .color = c } }}, &diag);
    try testing.expectError(error.Invalid, self.set(1, &.{
        .{ .circle = .{ .cx = 0, .cy = 0, .r = 1, .fill = c } },
        .{ .circle = .{ .cx = 0, .cy = 0, .r = -1, .fill = c } },
    }, &diag));

    const entry = self.get(1).?;
    try testing.expectEqual(@as(u32, 1), entry.version);
    try testing.expectEqual(@as(usize, 1), entry.drawing.commands.len);
    try testing.expectEqualStrings("kept", entry.drawing.textOf(entry.drawing.commands[0].text.text));
}

test "store: the canvas cap is enforced at add and frees up on remove" {
    var self = Self.init(testing.allocator);
    defer self.deinit();

    for (0..max_canvases) |i| try self.add(@intCast(i));
    try testing.expectError(error.LimitExceeded, self.add(max_canvases));
    self.remove(0);
    try self.add(max_canvases);
}
