//! Thin, fully generic wrapper over the system sqlite3 C API -- no schema
//! knowledge, no app-specific SQL. Schema/data are entirely the caller's
//! concern (a capability, or a test); this file just owns a connection and
//! exposes parameterized exec/query.

const std = @import("std");
const c = @import("c.zig").c;
const json_util = @import("json_util.zig");

const Self = @This();

db: ?*c.sqlite3,

pub const Error = error{ OpenFailed, ExecFailed, PrepareFailed, StepFailed, BindFailed };

// sqlite3's SQLITE_TRANSIENT is `((sqlite3_destructor_type)-1)` -- a cast
// expression macro that doesn't survive @cImport translation, and Zig's
// @ptrFromInt/@alignCast won't construct a "-1" function pointer value
// since it's inherently misaligned (all bits set = odd). At the C ABI
// level this is just a register-sized bit pattern regardless of Zig's
// pointer type, so declare our own binding with an integer destructor
// param instead of fighting the pointer-alignment safety check.
extern fn sqlite3_bind_text(stmt: ?*c.sqlite3_stmt, index: c_int, text: [*c]const u8, n: c_int, destructor: isize) callconv(.c) c_int;
const SQLITE_TRANSIENT: isize = -1;

pub fn open(path: [:0]const u8) Error!Self {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path.ptr, &db) != c.SQLITE_OK) {
        return error.OpenFailed;
    }
    if (c.sqlite3_set_authorizer(db, authorize, null) != c.SQLITE_OK) {
        _ = c.sqlite3_close(db);
        return error.OpenFailed;
    }
    return .{ .db = db };
}

/// Keeps guest SQL inside the one database file the host opened. Guest SQL
/// reaches `exec`/`queryToJson` verbatim, and without this `ATTACH` would
/// let it open any path at host privilege -- reading other apps' SQLite
/// files, or creating new ones anywhere -- escaping the WASM sandbox
/// entirely. Everything inside the host-opened database (tables, indexes,
/// views, triggers, transactions, TEMP tables) is untouched.
///
/// `ATTACH` is allowed only for an empty filename: plain `VACUUM` runs
/// `ATTACH '' AS vacuum_db` internally (an anonymous temp database) and
/// goes through this callback too, so a blanket deny would break it.
/// `VACUUM INTO '<path>'` attaches its real path the same way, so it's
/// denied here as well -- it would otherwise write a full copy of the
/// database anywhere. The two deprecated directory pragmas are denied
/// because they redirect where SQLite itself writes files.
///
/// Extension loading needs no rule here: it's off unless
/// `sqlite3_enable_load_extension` is called, and nothing does. Opening up
/// more (e.g. host-mapped named databases) waits for a real need.
fn authorize(_: ?*anyopaque, action: c_int, arg1: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    switch (action) {
        c.SQLITE_ATTACH => {
            const filename: []const u8 = if (arg1) |f| std.mem.span(@as([*:0]const u8, @ptrCast(f))) else "";
            return if (filename.len == 0) c.SQLITE_OK else c.SQLITE_DENY;
        },
        c.SQLITE_DETACH => return c.SQLITE_DENY,
        c.SQLITE_PRAGMA => {
            const name: []const u8 = if (arg1) |n| std.mem.span(@as([*:0]const u8, @ptrCast(n))) else "";
            if (std.ascii.eqlIgnoreCase(name, "temp_store_directory") or
                std.ascii.eqlIgnoreCase(name, "data_store_directory"))
            {
                return c.SQLITE_DENY;
            }
            return c.SQLITE_OK;
        },
        else => return c.SQLITE_OK,
    }
}

pub fn close(self: *Self) void {
    _ = c.sqlite3_close(self.db);
}

fn prepareAndBind(self: *Self, allocator: std.mem.Allocator, sql: []const u8, params: []const []const u8) !?*c.sqlite3_stmt {
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        return error.PrepareFailed;
    }
    for (params, 0..) |p, i| {
        if (sqlite3_bind_text(stmt, @intCast(i + 1), p.ptr, @intCast(p.len), SQLITE_TRANSIENT) != c.SQLITE_OK) {
            _ = c.sqlite3_finalize(stmt);
            return error.BindFailed;
        }
    }
    return stmt;
}

pub const ExecResult = struct {
    rows_affected: i64,
    last_insert_id: i64,
};

pub fn exec(self: *Self, allocator: std.mem.Allocator, sql: []const u8, params: []const []const u8) !ExecResult {
    const stmt = (try self.prepareAndBind(allocator, sql, params)).?;
    defer _ = c.sqlite3_finalize(stmt);
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
        return error.StepFailed;
    }
    return .{
        .rows_affected = c.sqlite3_changes(self.db),
        .last_insert_id = c.sqlite3_last_insert_rowid(self.db),
    };
}

/// Builds a JSON array of objects directly, matching the host<->guest wire
/// contract ({"rows":[{"col":"val",...}]}) -- generic over column count and
/// names, not hardcoded to any particular schema, since the real binding
/// generator would eventually produce something similarly general.
pub fn queryToJson(self: *Self, allocator: std.mem.Allocator, sql: []const u8, params: []const []const u8) ![]u8 {
    const stmt = (try self.prepareAndBind(allocator, sql, params)).?;
    defer _ = c.sqlite3_finalize(stmt);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');

    const col_count = c.sqlite3_column_count(stmt);
    var first_row = true;
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;

        if (!first_row) try out.append(allocator, ',');
        first_row = false;
        try out.append(allocator, '{');
        var col: c_int = 0;
        while (col < col_count) : (col += 1) {
            if (col != 0) try out.append(allocator, ',');
            const name = std.mem.span(c.sqlite3_column_name(stmt, col));
            const text_ptr = c.sqlite3_column_text(stmt, col);
            const value: []const u8 = if (text_ptr) |t| std.mem.span(@as([*:0]const u8, @ptrCast(t))) else "";
            try json_util.writeString(&out, allocator, name);
            try out.append(allocator, ':');
            try json_util.writeString(&out, allocator, value);
        }
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

test "open, exec, query, delete round trip -- no baked-in schema" {
    const allocator = std.testing.allocator;

    var db = try open(":memory:");
    defer db.close();
    _ = try db.exec(allocator, "CREATE TABLE books (id INTEGER PRIMARY KEY AUTOINCREMENT, author TEXT NOT NULL, title TEXT NOT NULL, genre TEXT NOT NULL)", &.{});

    const insert = try db.exec(allocator, "INSERT INTO books (author, title, genre) VALUES (?, ?, ?)", &.{ "Ursula K. Le Guin", "The Left Hand of Darkness", "Sci-Fi" });
    try std.testing.expectEqual(@as(i64, 1), insert.rows_affected);
    try std.testing.expect(insert.last_insert_id > 0);

    const json1 = try db.queryToJson(allocator, "SELECT id, author, title, genre FROM books ORDER BY id", &.{});
    defer allocator.free(json1);
    try std.testing.expect(std.mem.indexOf(u8, json1, "Le Guin") != null);
    try std.testing.expect(std.mem.indexOf(u8, json1, "Left Hand of Darkness") != null);

    // a value containing a quote and backslash should round-trip through
    // JSON escaping without corrupting the array structure.
    _ = try db.exec(allocator, "INSERT INTO books (author, title, genre) VALUES (?, ?, ?)", &.{ "Some \"Author\"", "A \\ Title", "Genre" });
    const json2 = try db.queryToJson(allocator, "SELECT id, author, title, genre FROM books ORDER BY id", &.{});
    defer allocator.free(json2);
    try std.testing.expect(std.mem.indexOf(u8, json2, "Some \\\"Author\\\"") != null);

    var id_buf: [16]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{insert.last_insert_id});
    const del = try db.exec(allocator, "DELETE FROM books WHERE id = ?", &.{id_str});
    try std.testing.expectEqual(@as(i64, 1), del.rows_affected);

    const json3 = try db.queryToJson(allocator, "SELECT id, author, title, genre FROM books ORDER BY id", &.{});
    defer allocator.free(json3);
    try std.testing.expect(std.mem.indexOf(u8, json3, "Le Guin") == null);
    try std.testing.expect(std.mem.indexOf(u8, json3, "Some") != null);
}

test "guest SQL cannot reach files outside the opened database" {
    const allocator = std.testing.allocator;

    var db = try open(":memory:");
    defer db.close();
    _ = try db.exec(allocator, "CREATE TABLE t (v TEXT)", &.{});
    _ = try db.exec(allocator, "INSERT INTO t (v) VALUES (?)", &.{"kept"});

    try std.testing.expectError(error.PrepareFailed, db.exec(allocator, "ATTACH 'natyv_attach_must_fail.db' AS x", &.{}));
    try std.testing.expectError(error.PrepareFailed, db.exec(allocator, "ATTACH ':memory:' AS x", &.{}));
    try std.testing.expectError(error.PrepareFailed, db.exec(allocator, "DETACH x", &.{}));
    try std.testing.expectError(error.PrepareFailed, db.exec(allocator, "PRAGMA temp_store_directory = '/tmp'", &.{}));
    try std.testing.expectError(error.PrepareFailed, db.exec(allocator, "PRAGMA TEMP_STORE_DIRECTORY = '/tmp'", &.{}));
    // VACUUM INTO's own ATTACH is denied at step time, not prepare time.
    try std.testing.expectError(error.StepFailed, db.exec(allocator, "VACUUM INTO 'natyv_vacuum_must_fail.db'", &.{}));
    try std.testing.expectError(error.StepFailed, db.exec(allocator, "SELECT load_extension('natyv_no_such_ext')", &.{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, "natyv_attach_must_fail.db", .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, "natyv_vacuum_must_fail.db", .{}));

    // Plain VACUUM attaches an empty filename internally and must keep working.
    _ = try db.exec(allocator, "VACUUM", &.{});
    _ = try db.exec(allocator, "CREATE TEMP TABLE scratch (v TEXT)", &.{});
    _ = try db.exec(allocator, "CREATE INDEX t_v ON t (v)", &.{});
    const json = try db.queryToJson(allocator, "SELECT v FROM t", &.{});
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "kept") != null);
}
