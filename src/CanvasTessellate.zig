//! Turns a validated canvas drawing's commands into triangles. Pure and
//! dependency-free (its own test root, like `CanvasStore.zig`), so every
//! shape and the ear clipper are tested without a renderer.
//!
//! Output goes to a caller-supplied sink with one method,
//! `triangle(a: Point, b: Point, c: Point, color: Color) void`, in the
//! canvas's logical coordinates. The sink scales and offsets them (2x
//! supersampling, pixel density, the current tile) and batches them into
//! `SDL_RenderGeometry` calls, so a drawing never needs one big vertex
//! buffer. `scale` here only picks how finely curves are segmented.
//!
//! Text commands emit nothing -- the renderer draws text itself (see
//! `capabilities/CanvasRender.zig`).
//!
//! Strokes use miter joins with the miter length clamped, rather than round
//! joins: adjacent segments share their offset points, so a translucent
//! polyline never double-blends at a joint. Lines and open polylines have
//! butt caps.
//!
//! Work is bounded before anything is drawn: `vertexEstimate` gives an upper
//! bound on what `tessellate` emits for a command at any render scale up to
//! `max_render_scale`, and `CanvasStore.build` rejects a drawing whose total
//! passes `max_vertices`. Ear clipping also carries its own work budget,
//! since its cost grows faster than its vertex count.

const std = @import("std");
const CanvasStore = @import("CanvasStore.zig");

pub const Point = CanvasStore.Point;
pub const Color = CanvasStore.Color;
const Command = CanvasStore.Command;
const Drawing = CanvasStore.Drawing;

/// 2x supersampling times a pixel density up to 4. Curve segmentation never
/// goes finer than this, whatever scale the renderer passes.
pub const max_render_scale = 8;
/// Per drawing, at `max_render_scale`. A few MB of triangles per tile pass
/// at most, and a scatter plot of 8192 small circles fits comfortably.
pub const max_vertices = 2 * 1024 * 1024;
pub const min_segments = 8;
pub const max_segments = 1024;
/// Point-in-triangle tests per polygon fill. Past it, the rest of the
/// polygon is fanned, which is wrong for a concave remainder but bounded.
/// Real shapes (area charts, arrowheads) finish far below it.
pub const max_earclip_tests = 1 << 26;
/// How far a miter may extend, in half-widths, before it's clamped.
pub const miter_limit = 4;

const tau = 2 * std.math.pi;

/// Segments for a full circle of logical radius `r` at `scale`. Grows with
/// the square root of the on-screen radius, which keeps the chord error
/// near 0.125px at any size.
pub fn segmentsFor(r: f32, scale: f32) u32 {
    const rp = r * std.math.clamp(scale, 0, max_render_scale);
    // Also catches NaN, which fails every comparison.
    if (!(rp > 0)) return min_segments;
    const n = @ceil(tau * @sqrt(rp));
    if (!(n < max_segments)) return max_segments;
    return @max(min_segments, @as(u32, @intFromFloat(n)));
}

fn arcSegments(r: f32, span: f32, scale: f32) u32 {
    const full = segmentsFor(r, scale);
    const frac = @min(@abs(span) / tau, 1);
    const n: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(full)) * frac));
    return @max(2, n);
}

fn cornerSegments(radius: f32, scale: f32) u32 {
    return @max(1, segmentsFor(radius, scale) / 4);
}

/// Upper bound on the vertices `tessellate` emits for `cmd`, at any scale
/// up to `max_render_scale`.
pub fn vertexEstimate(cmd: Command) usize {
    const s = max_render_scale;
    return switch (cmd) {
        .line => 6,
        .polyline => |p| 6 * @as(usize, p.points.len),
        .rect => |r| blk: {
            const path: usize = if (r.radius > 0) 4 * (@as(usize, cornerSegments(r.radius, s)) + 1) else 4;
            break :blk paintVertices(r.paint, path);
        },
        .circle => |ci| paintVertices(ci.paint, segmentsFor(ci.r, s)),
        .polygon => |p| paintVertices(p.paint, p.points.len),
        // The wedge outline is the arc plus the centre.
        .arc => |a| paintVertices(a.paint, @as(usize, arcSegments(a.r, a.end - a.start, s)) + 2),
        .text => 0,
    };
}

/// A box (min x, min y, max x, max y) that every triangle `tessellate`
/// emits for `cmd` lies inside, so a tiled render can skip commands that
/// miss a tile. Conservative: strokes pad by the longest possible miter,
/// and an arc by its whole circle. Text is measured by the renderer.
pub fn bounds(drawing: *const Drawing, cmd: Command) [4]f32 {
    return switch (cmd) {
        .line => |l| pad(boxOf(&.{ l.from, l.to }), l.width / 2),
        .polyline => |p| pad(boxOf(drawing.pointsOf(p.points)), strokePad(p.width)),
        .rect => |r| pad(.{ r.x, r.y, r.x + r.w, r.y + r.h }, paintPad(r.paint)),
        .circle => |ci| pad(.{ ci.center[0], ci.center[1], ci.center[0], ci.center[1] }, ci.r + paintPad(ci.paint)),
        .polygon => |p| pad(boxOf(drawing.pointsOf(p.points)), paintPad(p.paint)),
        .arc => |a| pad(.{ a.center[0], a.center[1], a.center[0], a.center[1] }, a.r + paintPad(a.paint)),
        .text => |t| .{ t.pos[0], t.pos[1], t.pos[0], t.pos[1] },
    };
}

fn boxOf(pts: []const Point) [4]f32 {
    var box: [4]f32 = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (pts) |p| box = .{ @min(box[0], p[0]), @min(box[1], p[1]), @max(box[2], p[0]), @max(box[3], p[1]) };
    return box;
}

fn pad(box: [4]f32, by: f32) [4]f32 {
    return .{ box[0] - by, box[1] - by, box[2] + by, box[3] + by };
}

fn strokePad(width: f32) f32 {
    return width / 2 * miter_limit;
}

fn paintPad(paint: CanvasStore.Paint) f32 {
    return if (paint.stroke != null) strokePad(paint.stroke_width) else 0;
}

/// A fan fill of an n-point path is under 3n vertices; a closed stroke of
/// it is 6n.
fn paintVertices(paint: CanvasStore.Paint, path_points: usize) usize {
    var n: usize = 0;
    if (paint.fill != null) n += 3 * path_points;
    if (paint.stroke != null) n += 6 * path_points;
    return n;
}

/// Emits `cmd`'s triangles into `sink`. `scratch` holds temporary paths and
/// is only used for the duration of the call.
pub fn tessellate(drawing: *const Drawing, cmd: Command, scale: f32, scratch: std.mem.Allocator, sink: anytype) error{OutOfMemory}!void {
    switch (cmd) {
        .line => |l| strokeSegment(l.from, l.to, l.width, l.color, sink),
        .polyline => |p| try strokePath(drawing.pointsOf(p.points), false, p.width, p.color, scratch, sink),
        .rect => |r| {
            if (r.radius <= 0) {
                const corners = [4]Point{ .{ r.x, r.y }, .{ r.x + r.w, r.y }, .{ r.x + r.w, r.y + r.h }, .{ r.x, r.y + r.h } };
                try paintPath(&corners, r.paint, scratch, sink);
                return;
            }
            const path = try roundedRectPath(scratch, r.x, r.y, r.w, r.h, r.radius, scale);
            defer scratch.free(path);
            try paintPath(path, r.paint, scratch, sink);
        },
        .circle => |ci| {
            if (ci.r <= 0) return;
            const n = segmentsFor(ci.r, scale);
            if (ci.paint.fill) |f| fillArcFan(ci.center, ci.r, 0, tau, n, f, sink);
            if (ci.paint.stroke) |s| strokeRing(ci.center, ci.r, 0, tau, n, ci.paint.stroke_width, s, sink);
        },
        .polygon => |p| {
            const pts = drawing.pointsOf(p.points);
            if (p.paint.fill) |f| try fillPolygon(pts, f, scratch, sink);
            if (p.paint.stroke) |s| try strokePath(pts, true, p.paint.stroke_width, s, scratch, sink);
        },
        .arc => |a| {
            if (a.r <= 0) return;
            var span = a.end - a.start;
            const full = @abs(span) >= tau;
            if (full) span = tau;
            const n = arcSegments(a.r, span, scale);
            if (a.paint.fill) |f| fillArcFan(a.center, a.r, a.start, span, n, f, sink);
            if (a.paint.stroke) |s| {
                if (a.paint.fill == null or full) {
                    strokeRing(a.center, a.r, a.start, span, n, a.paint.stroke_width, s, sink);
                } else {
                    // A filled wedge's stroke outlines the whole slice --
                    // both radii and the curve -- like a pie chart's
                    // separators.
                    const path = try scratch.alloc(Point, n + 2);
                    defer scratch.free(path);
                    path[0] = a.center;
                    for (0..n + 1) |k| path[k + 1] = arcPoint(a.center, a.r, a.start + span * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n)));
                    try strokePath(path, true, a.paint.stroke_width, s, scratch, sink);
                }
            }
        },
        .text => {},
    }
}

fn arcPoint(center: Point, r: f32, theta: f32) Point {
    return .{ center[0] + r * @cos(theta), center[1] + r * @sin(theta) };
}

fn paintPath(path: []const Point, paint: CanvasStore.Paint, scratch: std.mem.Allocator, sink: anytype) error{OutOfMemory}!void {
    if (paint.fill) |f| {
        // Every path through here is convex, so a fan from its first point
        // is exact.
        for (1..path.len -| 1) |i| sink.triangle(path[0], path[i], path[i + 1], f);
    }
    if (paint.stroke) |s| try strokePath(path, true, paint.stroke_width, s, scratch, sink);
}

/// Clockwise from the top-left corner. The radius is clamped to half the
/// shorter side, like CSS.
fn roundedRectPath(scratch: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32, radius: f32, scale: f32) error{OutOfMemory}![]Point {
    const rr = @min(radius, @min(w, h) / 2);
    const k = cornerSegments(rr, scale);
    const path = try scratch.alloc(Point, 4 * (k + 1));
    const centers = [4]Point{ .{ x + rr, y + rr }, .{ x + w - rr, y + rr }, .{ x + w - rr, y + h - rr }, .{ x + rr, y + h - rr } };
    var i: usize = 0;
    for (centers, 0..) |ctr, corner| {
        const start = std.math.pi + @as(f32, @floatFromInt(corner)) * (std.math.pi / 2.0);
        for (0..k + 1) |j| {
            path[i] = arcPoint(ctr, rr, start + (std.math.pi / 2.0) * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(k)));
            i += 1;
        }
    }
    return path;
}

fn fillArcFan(center: Point, r: f32, start: f32, span: f32, n: u32, color: Color, sink: anytype) void {
    var prev = arcPoint(center, r, start);
    for (1..n + 1) |k| {
        const next = arcPoint(center, r, start + span * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n)));
        sink.triangle(center, prev, next, color);
        prev = next;
    }
}

/// An annulus segment centred on radius `r`. The inner edge stops at the
/// centre rather than crossing it when the stroke is wider than the circle.
fn strokeRing(center: Point, r: f32, start: f32, span: f32, n: u32, width: f32, color: Color, sink: anytype) void {
    const inner = @max(0, r - width / 2);
    const outer = r + width / 2;
    var prev_in = arcPoint(center, inner, start);
    var prev_out = arcPoint(center, outer, start);
    for (1..n + 1) |k| {
        const theta = start + span * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        const next_in = arcPoint(center, inner, theta);
        const next_out = arcPoint(center, outer, theta);
        sink.triangle(prev_in, prev_out, next_out, color);
        sink.triangle(prev_in, next_out, next_in, color);
        prev_in = next_in;
        prev_out = next_out;
    }
}

fn strokeSegment(a: Point, b: Point, width: f32, color: Color, sink: anytype) void {
    const n = normalOf(a, b) orelse return;
    const off = scaled(n, width / 2);
    const a1 = add(a, off);
    const a2 = sub(a, off);
    const b1 = add(b, off);
    const b2 = sub(b, off);
    sink.triangle(a1, a2, b1, color);
    sink.triangle(a2, b2, b1, color);
}

/// Strokes a path with miter joins. Consecutive duplicate points (and, when
/// closed, a last point repeating the first) are dropped first, since a
/// zero-length segment has no direction to offset along.
fn strokePath(raw: []const Point, closed: bool, width: f32, color: Color, scratch: std.mem.Allocator, sink: anytype) error{OutOfMemory}!void {
    const buf, const len = try dedupe(scratch, raw, closed);
    defer scratch.free(buf);
    const pts = buf[0..len];
    if (pts.len < 2) return;

    const half = width / 2;
    const offsets = try scratch.alloc(Point, pts.len);
    defer scratch.free(offsets);
    for (pts, 0..) |_, i| {
        const has_prev = closed or i > 0;
        const has_next = closed or i + 1 < pts.len;
        const prev = pts[if (i == 0) pts.len - 1 else i - 1];
        const next = pts[if (i + 1 == pts.len) 0 else i + 1];
        const n_in: ?Point = if (has_prev) normalOf(prev, pts[i]) else null;
        const n_out: ?Point = if (has_next) normalOf(pts[i], next) else null;
        offsets[i] = miterOffset(n_in orelse n_out.?, n_out orelse n_in.?, half);
    }

    const segments = if (closed) pts.len else pts.len - 1;
    for (0..segments) |i| {
        const j = (i + 1) % pts.len;
        const a1 = add(pts[i], offsets[i]);
        const a2 = sub(pts[i], offsets[i]);
        const b1 = add(pts[j], offsets[j]);
        const b2 = sub(pts[j], offsets[j]);
        sink.triangle(a1, a2, b1, color);
        sink.triangle(a2, b2, b1, color);
    }
}

fn miterOffset(n1: Point, n2: Point, half: f32) Point {
    const m = add(n1, n2);
    const len = @sqrt(m[0] * m[0] + m[1] * m[1]);
    // A full reversal has no miter direction; fall back to a plain normal.
    if (len < 1e-6) return scaled(n1, half);
    const dir = scaled(m, 1 / len);
    const cos = dir[0] * n1[0] + dir[1] * n1[1];
    return scaled(dir, half / @max(cos, 1.0 / @as(f32, miter_limit)));
}

/// Returns the whole scratch buffer (to free) and how much of it is used.
fn dedupe(scratch: std.mem.Allocator, raw: []const Point, closed: bool) error{OutOfMemory}!struct { []Point, usize } {
    const out = try scratch.alloc(Point, raw.len);
    var n: usize = 0;
    for (raw) |p| {
        if (n > 0 and samePoint(out[n - 1], p)) continue;
        out[n] = p;
        n += 1;
    }
    if (closed) while (n > 1 and samePoint(out[n - 1], out[0])) {
        n -= 1;
    };
    return .{ out, n };
}

fn samePoint(a: Point, b: Point) bool {
    return @abs(a[0] - b[0]) < 1e-4 and @abs(a[1] - b[1]) < 1e-4;
}

fn normalOf(a: Point, b: Point) ?Point {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return null;
    return .{ -dy / len, dx / len };
}

fn add(a: Point, b: Point) Point {
    return .{ a[0] + b[0], a[1] + b[1] };
}

fn sub(a: Point, b: Point) Point {
    return .{ a[0] - b[0], a[1] - b[1] };
}

fn scaled(a: Point, k: f32) Point {
    return .{ a[0] * k, a[1] * k };
}

/// Fills any simple polygon, convex or not, by ear clipping. Always
/// terminates and emits at most n-2 triangles, even for self-intersecting
/// or degenerate input: a full lap without finding an ear clips the current
/// vertex anyway, and past `max_earclip_tests` the remainder is fanned.
/// Maths is in f64, since cross products of coordinates near `max_coord`
/// lose too much precision in f32.
fn fillPolygon(raw: []const Point, color: Color, scratch: std.mem.Allocator, sink: anytype) error{OutOfMemory}!void {
    const buf, const n = try dedupe(scratch, raw, true);
    defer scratch.free(buf);
    const pts = buf[0..n];
    if (n < 3) return;

    var area: f64 = 0;
    for (0..n) |i| {
        const a = pts[i];
        const b = pts[(i + 1) % n];
        area += @as(f64, a[0]) * b[1] - @as(f64, b[0]) * a[1];
    }
    if (@abs(area) < 1e-9) return;
    const orient: f64 = if (area > 0) 1 else -1;

    const prev = try scratch.alloc(u32, n);
    defer scratch.free(prev);
    const next = try scratch.alloc(u32, n);
    defer scratch.free(next);
    for (0..n) |i| {
        prev[i] = @intCast(if (i == 0) n - 1 else i - 1);
        next[i] = @intCast((i + 1) % n);
    }

    var remaining = n;
    var cur: u32 = 0;
    var stall: usize = 0;
    var tests: usize = 0;
    while (remaining > 3) {
        const p = prev[cur];
        const q = next[cur];
        const turn = cross(pts[p], pts[cur], pts[q]) * orient;
        if (tests >= max_earclip_tests) break;

        var clip = false;
        var emit = true;
        if (@abs(turn) < 1e-9) {
            // Collinear: dropping it changes nothing, so no triangle.
            clip = true;
            emit = false;
        } else if (turn > 0) {
            clip = true;
            var v = next[q];
            while (v != p) : (v = next[v]) {
                tests += 1;
                if (samePoint(pts[v], pts[p]) or samePoint(pts[v], pts[cur]) or samePoint(pts[v], pts[q])) continue;
                if (inTriangle(pts[v], pts[p], pts[cur], pts[q], orient)) {
                    clip = false;
                    break;
                }
            }
        }
        // A full lap with no ear means the input isn't a simple polygon;
        // clip anyway so the loop always shrinks.
        if (!clip and stall >= remaining) clip = true;

        if (clip) {
            if (emit) sink.triangle(pts[p], pts[cur], pts[q], color);
            next[p] = q;
            prev[q] = p;
            remaining -= 1;
            cur = q;
            stall = 0;
        } else {
            cur = q;
            stall += 1;
        }
    }

    // The last triangle, or the fanned remainder once the budget ran out.
    const first = cur;
    var v = next[first];
    while (next[v] != first) : (v = next[v]) sink.triangle(pts[first], pts[v], pts[next[v]], color);
}

fn cross(a: Point, b: Point, c: Point) f64 {
    const abx = @as(f64, b[0]) - a[0];
    const aby = @as(f64, b[1]) - a[1];
    const bcx = @as(f64, c[0]) - b[0];
    const bcy = @as(f64, c[1]) - b[1];
    return abx * bcy - aby * bcx;
}

/// Inclusive of edges, so a vertex touching the candidate ear's diagonal
/// blocks it.
fn inTriangle(v: Point, a: Point, b: Point, c: Point, orient: f64) bool {
    return cross(a, b, v) * orient >= 0 and cross(b, c, v) * orient >= 0 and cross(c, a, v) * orient >= 0;
}

// --- tests ---

const testing = std.testing;

const TestSink = struct {
    tris: std.ArrayList([3]Point) = .empty,
    area: f64 = 0,

    fn triangle(self: *TestSink, a: Point, b: Point, c: Point, color: Color) void {
        _ = color;
        self.tris.append(testing.allocator, .{ a, b, c }) catch @panic("oom");
        self.area += @abs(cross(a, b, c)) / 2;
    }

    fn deinit(self: *TestSink) void {
        self.tris.deinit(testing.allocator);
    }
};

const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };

fn fillArea(pts: []const Point) !struct { f64, usize } {
    var sink: TestSink = .{};
    defer sink.deinit();
    try fillPolygon(pts, black, testing.allocator, &sink);
    return .{ sink.area, sink.tris.items.len };
}

test "segmentsFor: grows with radius and scale, clamped both ways" {
    try testing.expectEqual(@as(u32, min_segments), segmentsFor(0, 2));
    try testing.expectEqual(@as(u32, min_segments), segmentsFor(0.1, 2));
    try testing.expect(segmentsFor(100, 2) > segmentsFor(10, 2));
    try testing.expect(segmentsFor(10, 4) > segmentsFor(10, 2));
    try testing.expectEqual(@as(u32, max_segments), segmentsFor(CanvasStore.max_coord, max_render_scale));
    // A scale past the cap segments no finer than the cap.
    try testing.expectEqual(segmentsFor(50, max_render_scale), segmentsFor(50, 1000));
    try testing.expectEqual(@as(u32, min_segments), segmentsFor(std.math.nan(f32), 2));
}

test "fillPolygon: convex polygons fill their exact area with n-2 triangles" {
    const square = [_]Point{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const area, const tris = try fillArea(&square);
    try testing.expectApproxEqAbs(@as(f64, 100), area, 1e-6);
    try testing.expectEqual(@as(usize, 2), tris);

    // Winding direction doesn't matter.
    const ccw = [_]Point{ .{ 0, 0 }, .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 } };
    const area2, _ = try fillArea(&ccw);
    try testing.expectApproxEqAbs(@as(f64, 100), area2, 1e-6);
}

test "fillPolygon: concave shapes fill exactly -- no triangle crosses the notch" {
    // An L shape: area 10*10 - 5*5.
    const l_shape = [_]Point{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 5 }, .{ 5, 5 }, .{ 5, 10 }, .{ 0, 10 } };
    const area, const tris = try fillArea(&l_shape);
    try testing.expectApproxEqAbs(@as(f64, 75), area, 1e-6);
    try testing.expectEqual(@as(usize, 4), tris);

    // An area chart: a jagged top edge over a flat baseline, the shape
    // ear clipping exists for.
    const chart = [_]Point{ .{ 0, 100 }, .{ 0, 40 }, .{ 10, 80 }, .{ 20, 20 }, .{ 30, 90 }, .{ 40, 10 }, .{ 50, 60 }, .{ 50, 100 } };
    var expected: f64 = 0;
    for (0..chart.len) |i| {
        const a = chart[i];
        const b = chart[(i + 1) % chart.len];
        expected += @as(f64, a[0]) * b[1] - @as(f64, b[0]) * a[1];
    }
    const chart_area, const chart_tris = try fillArea(&chart);
    try testing.expectApproxEqAbs(@abs(expected) / 2, chart_area, 1e-3);
    try testing.expectEqual(chart.len - 2, chart_tris);
}

test "fillPolygon: degenerate input terminates and draws nothing wrong" {
    // All collinear: zero area, nothing drawn.
    const line = [_]Point{ .{ 0, 0 }, .{ 5, 5 }, .{ 10, 10 } };
    _, const tris = try fillArea(&line);
    try testing.expectEqual(@as(usize, 0), tris);

    // Duplicates everywhere, including a closing repeat of the first point.
    const dupes = [_]Point{ .{ 0, 0 }, .{ 0, 0 }, .{ 10, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 0 } };
    const area, _ = try fillArea(&dupes);
    try testing.expectApproxEqAbs(@as(f64, 100), area, 1e-6);

    // Collinear points along an edge are dropped, not triangulated.
    const edge = [_]Point{ .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const edge_area, _ = try fillArea(&edge);
    try testing.expectApproxEqAbs(@as(f64, 100), edge_area, 1e-6);

    // A self-intersecting bowtie has no valid triangulation; the point is
    // that it finishes with a bounded number of triangles.
    const bowtie = [_]Point{ .{ 0, 0 }, .{ 10, 10 }, .{ 10, 0 }, .{ 0, 10 } };
    _, const bowtie_tris = try fillArea(&bowtie);
    try testing.expect(bowtie_tris <= bowtie.len - 2);

    // A star that folds over itself many times.
    var star: [50]Point = undefined;
    for (&star, 0..) |*p, i| {
        const t = @as(f32, @floatFromInt(i)) * 2.0 * 0.4 * std.math.pi;
        p.* = .{ 100 * @cos(t * 7), 100 * @sin(t * 7) };
    }
    _, const star_tris = try fillArea(&star);
    try testing.expect(star_tris <= star.len - 2);
}

test "fillPolygon: a huge concave polygon stays within the work budget" {
    // A comb: every other vertex is reflex, the expensive case.
    const n = 20000;
    const pts = try testing.allocator.alloc(Point, n + 2);
    defer testing.allocator.free(pts);
    for (0..n) |i| pts[i] = .{ @floatFromInt(i), if (i % 2 == 0) 0 else 50 };
    pts[n] = .{ n, 100 };
    pts[n + 1] = .{ 0, 100 };
    _, const tris = try fillArea(pts);
    try testing.expect(tris <= pts.len - 2);
}

test "strokePath: a straight polyline is one clean band; a closed square's joins are mitered" {
    var sink: TestSink = .{};
    defer sink.deinit();
    try strokePath(&.{ .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 } }, false, 2, black, testing.allocator, &sink);
    try testing.expectApproxEqAbs(@as(f64, 20), sink.area, 1e-4);

    var sq: TestSink = .{};
    defer sq.deinit();
    try strokePath(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }, true, 2, black, testing.allocator, &sq);
    // Outer square 12x12 minus inner 8x8, exactly -- mitered corners, no
    // gaps and no overlaps.
    try testing.expectApproxEqAbs(@as(f64, 144 - 64), sq.area, 1e-3);
}

test "strokePath: duplicates and zero-length paths draw nothing broken" {
    var sink: TestSink = .{};
    defer sink.deinit();
    try strokePath(&.{ .{ 3, 3 }, .{ 3, 3 } }, false, 2, black, testing.allocator, &sink);
    try testing.expectEqual(@as(usize, 0), sink.tris.items.len);
    // A hairpin: the miter is clamped, not sent off to infinity.
    try strokePath(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 0.001 } }, false, 2, black, testing.allocator, &sink);
    for (sink.tris.items) |t| for (t) |p| {
        try testing.expect(@abs(p[0]) < 20 and @abs(p[1]) < 20);
    };
    // And a full reversal.
    try strokePath(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 0 } }, false, 2, black, testing.allocator, &sink);
    for (sink.tris.items) |t| for (t) |p| {
        try testing.expect(std.math.isFinite(p[0]) and std.math.isFinite(p[1]));
    };
}

test "tessellate: circles, rounded rects and wedges cover close to their true area" {
    var pts = [_]Point{};
    const drawing: Drawing = .{ .points = &pts };
    const fill: CanvasStore.Paint = .{ .fill = black, .stroke = null, .stroke_width = 1 };

    var circle: TestSink = .{};
    defer circle.deinit();
    try tessellate(&drawing, .{ .circle = .{ .center = .{ 50, 50 }, .r = 40, .paint = fill } }, 2, testing.allocator, &circle);
    try testing.expectApproxEqRel(std.math.pi * 1600.0, circle.area, 0.005);

    var rect: TestSink = .{};
    defer rect.deinit();
    try tessellate(&drawing, .{ .rect = .{ .x = 0, .y = 0, .w = 100, .h = 50, .radius = 10, .paint = fill } }, 2, testing.allocator, &rect);
    try testing.expectApproxEqRel(5000.0 - (4.0 - std.math.pi) * 100.0, rect.area, 0.005);

    // An oversized radius is clamped to a pill, not drawn inside out.
    var pill: TestSink = .{};
    defer pill.deinit();
    try tessellate(&drawing, .{ .rect = .{ .x = 0, .y = 0, .w = 100, .h = 20, .radius = 500, .paint = fill } }, 2, testing.allocator, &pill);
    try testing.expectApproxEqRel(2000.0 - (4.0 - std.math.pi) * 100.0, pill.area, 0.005);

    var wedge: TestSink = .{};
    defer wedge.deinit();
    try tessellate(&drawing, .{ .arc = .{ .center = .{ 0, 0 }, .r = 40, .start = 0, .end = std.math.pi / 2.0, .paint = fill } }, 2, testing.allocator, &wedge);
    try testing.expectApproxEqRel(std.math.pi * 1600.0 / 4.0, wedge.area, 0.005);
    // Clockwise from +x with y down: a quarter from 0 to pi/2 lies in +x,+y.
    for (wedge.tris.items) |t| for (t) |p| {
        try testing.expect(p[0] >= -1e-3 and p[1] >= -1e-3);
    };

    // Past a full turn is just a full circle.
    var over: TestSink = .{};
    defer over.deinit();
    try tessellate(&drawing, .{ .arc = .{ .center = .{ 0, 0 }, .r = 40, .start = 0, .end = 100, .paint = fill } }, 2, testing.allocator, &over);
    try testing.expectApproxEqRel(std.math.pi * 1600.0, over.area, 0.005);
}

test "tessellate: a ring stroke covers the annulus" {
    var pts = [_]Point{};
    const drawing: Drawing = .{ .points = &pts };
    var sink: TestSink = .{};
    defer sink.deinit();
    try tessellate(&drawing, .{ .circle = .{ .center = .{ 0, 0 }, .r = 20, .paint = .{ .fill = null, .stroke = black, .stroke_width = 4 } } }, 2, testing.allocator, &sink);
    try testing.expectApproxEqRel(std.math.pi * (22.0 * 22.0 - 18.0 * 18.0), sink.area, 0.01);
}

test "vertexEstimate: bounds what tessellate emits at the maximum scale" {
    var pts = [_]Point{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 5, 3 }, .{ 0, 10 } };
    const drawing: Drawing = .{ .points = &pts };
    const both: CanvasStore.Paint = .{ .fill = black, .stroke = black, .stroke_width = 3 };
    const span: CanvasStore.Span = .{ .start = 0, .len = pts.len };
    const cmds = [_]Command{
        .{ .line = .{ .from = .{ 0, 0 }, .to = .{ 9, 9 }, .width = 2, .color = black } },
        .{ .polyline = .{ .points = span, .width = 2, .color = black } },
        .{ .rect = .{ .x = 0, .y = 0, .w = 90, .h = 40, .radius = 0, .paint = both } },
        .{ .rect = .{ .x = 0, .y = 0, .w = 90, .h = 40, .radius = 12, .paint = both } },
        .{ .circle = .{ .center = .{ 0, 0 }, .r = 3, .paint = both } },
        .{ .circle = .{ .center = .{ 0, 0 }, .r = 5000, .paint = both } },
        .{ .polygon = .{ .points = span, .paint = both } },
        .{ .arc = .{ .center = .{ 0, 0 }, .r = 40, .start = 0.3, .end = 2.1, .paint = both } },
        .{ .arc = .{ .center = .{ 0, 0 }, .r = 40, .start = 0, .end = 10, .paint = both } },
        .{ .arc = .{ .center = .{ 0, 0 }, .r = 40, .start = 1, .end = -1, .paint = .{ .fill = null, .stroke = black, .stroke_width = 2 } } },
    };
    for (cmds) |cmd| {
        var sink: TestSink = .{};
        defer sink.deinit();
        try tessellate(&drawing, cmd, max_render_scale, testing.allocator, &sink);
        try testing.expect(sink.tris.items.len * 3 <= vertexEstimate(cmd));
    }
}

test "tessellate: failing scratch allocations are reported, never leaked" {
    var pts = [_]Point{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 5, 3 }, .{ 0, 10 } };
    const drawing: Drawing = .{ .points = &pts };
    const cmd: Command = .{ .polygon = .{ .points = .{ .start = 0, .len = pts.len }, .paint = .{ .fill = black, .stroke = black, .stroke_width = 1 } } };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, d: *const Drawing, c: Command) !void {
            var sink: TestSink = .{};
            defer sink.deinit();
            try tessellate(d, c, 2, allocator, &sink);
        }
    }.run, .{ &drawing, cmd });
}

test "bounds: contains every emitted vertex" {
    var pts = [_]Point{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 9, 0.5 }, .{ 0, 10 } };
    const drawing: Drawing = .{ .points = &pts };
    const both: CanvasStore.Paint = .{ .fill = black, .stroke = black, .stroke_width = 3 };
    const span: CanvasStore.Span = .{ .start = 0, .len = pts.len };
    const cmds = [_]Command{
        .{ .line = .{ .from = .{ 0, 0 }, .to = .{ 9, 9 }, .width = 2, .color = black } },
        .{ .polyline = .{ .points = span, .width = 2, .color = black } },
        .{ .rect = .{ .x = 5, .y = 7, .w = 90, .h = 40, .radius = 12, .paint = both } },
        .{ .circle = .{ .center = .{ 3, 4 }, .r = 30, .paint = both } },
        .{ .polygon = .{ .points = span, .paint = both } },
        .{ .arc = .{ .center = .{ 0, 0 }, .r = 40, .start = 0.3, .end = 2.1, .paint = both } },
        .{ .arc = .{ .center = .{ 0, 0 }, .r = 40, .start = 1, .end = -1, .paint = .{ .fill = null, .stroke = black, .stroke_width = 2 } } },
    };
    for (cmds) |cmd| {
        var sink: TestSink = .{};
        defer sink.deinit();
        try tessellate(&drawing, cmd, 2, testing.allocator, &sink);
        try testing.expect(sink.tris.items.len > 0);
        const box = bounds(&drawing, cmd);
        for (sink.tris.items) |t| for (t) |p| {
            try testing.expect(p[0] >= box[0] - 1e-3 and p[0] <= box[2] + 1e-3);
            try testing.expect(p[1] >= box[1] - 1e-3 and p[1] <= box[3] + 1e-3);
        };
    }
}
