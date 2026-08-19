//! Tests for `Runtime.zig`, split out purely to keep that file's own
//! length down to its real orchestration logic -- see its doc comment.
//! Registered as its own `b.addTest` root in build.zig (same
//! `linkNatyvDeps`/`setCwd` config the old inline-in-Runtime.zig tests
//! used), same pattern every other split-out test file in this project
//! (Manifest.zig/Sqlite.zig/Config.zig/DrawBatcher.zig/ScrollClip.zig/
//! ScrollBar.zig/EventQueue.zig/FloatingOrder.zig) already establishes --
//! `test` blocks are only discovered by `zig build test` when their
//! containing file is itself an `addTest` root (or reachable through one
//! that is), so this split requires exactly that one build.zig addition,
//! nothing more.

const std = @import("std");
const Io = std.Io;
const c = @import("c.zig").c;
const timing = @import("timing.zig");
const json_util = @import("json_util.zig");
const Runtime = @import("Runtime.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");
const ClayLayout = @import("capabilities/ClayLayout.zig");
const Container = @import("widgets/Container.zig");
const Button = @import("widgets/Button.zig");
const TextField = @import("widgets/TextField.zig");
const TextArea = @import("widgets/TextArea.zig");
const Label = @import("widgets/Label.zig");
const RadioButton = @import("widgets/RadioButton.zig");
const NumericStepper = @import("widgets/NumericStepper.zig");
const SegmentedControl = @import("widgets/SegmentedControl.zig");
const Tabs = @import("widgets/Tabs.zig");
const Font = @import("capabilities/Font.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");

test "bookstore example: guest-declared UI end to end through natyv_init + natyv_dispatch" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/bookstore/guest/bookstore.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, ":memory:");
    defer runtime.deinit();
    // L5: bookstore is now laid out entirely via sdk/go/ui/clay, so its
    // guest only imports natyv_clay_* (never natyv_create_button/etc) --
    // needs clay_enabled=true or plugin creation itself fails with an
    // "unknown import" error before natyv_init ever runs.
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // W13: natyv_init now lands on the Home page (a real navigation
    // landing screen, not the book-management UI directly) -- navigate to
    // Books first via a real "Go to Books" click, same as a user would,
    // before any of this test's book-management assertions apply.
    // 45, not 32: W8's delete-confirm Dialog adds up to 5 more widgets
    // (root + message Label + button row + 2 buttons) on top of what this
    // test already exercises, and W13's breadcrumb trail adds up to 4 more
    // of its own on the Books page (root + "Home" Button + "/" separator
    // Label + "Books" Label) -- same silent-truncation risk documented at
    // every prior buffer bump in this file.
    var snap: [45]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var go_to_books_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Go to Books")) go_to_books_id = slot.id;
    }
    var dispatch_buf: [128]u8 = undefined;
    var click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{go_to_books_id orelse return error.MissingGoToBooksButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    // Drive it exactly the way main.zig's real event loop does: locate the
    // widgets the guest created (by placeholder/label, not by assuming
    // fixed ids), type into them via the same WidgetHost methods SDL text
    // input calls, and push a click the same way a real mouse click would.
    n = runtime.widgets.snapshot(io, &snap);

    var author_id: ?u32 = null;
    var title_id: ?u32 = null;
    var genre_id: ?u32 = null;
    var add_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        switch (slot.widget) {
            .textfield => |t| {
                if (std.mem.eql(u8, t.placeholder(), "Author")) author_id = slot.id;
                if (std.mem.eql(u8, t.placeholder(), "Title")) title_id = slot.id;
                if (std.mem.eql(u8, t.placeholder(), "Genre")) genre_id = slot.id;
            },
            .button => |b| {
                if (std.mem.eql(u8, b.label(), "Add Book")) add_id = slot.id;
            },
            .label => {},
            .container => {},
            .checkbox, .toggle, .radio_button, .progress_bar, .slider, .textarea, .divider, .badge, .numeric_stepper, .segmented_control, .tabs => {},
        }
    }

    var text_scratch: [128]u8 = undefined;
    _ = runtime.widgets.appendTextTo(io, author_id orelse return error.MissingAuthorField, "Frank Herbert", &text_scratch);
    _ = runtime.widgets.appendTextTo(io, title_id orelse return error.MissingTitleField, "Dune", &text_scratch);
    _ = runtime.widgets.appendTextTo(io, genre_id orelse return error.MissingGenreField, "Sci-Fi", &text_scratch);

    click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{add_id orelse return error.MissingAddButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    var found_book = false;
    var delete_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        switch (slot.widget) {
            .label => |l| if (std.mem.indexOf(u8, l.text(), "Frank Herbert") != null) {
                found_book = true;
            },
            .button => |b| if (std.mem.eql(u8, b.label(), "Delete")) {
                delete_id = slot.id;
            },
            else => {},
        }
    }
    try std.testing.expect(found_book);

    // W8: clicking "Delete" no longer removes the book immediately -- it
    // opens a real confirmation Dialog instead (showDeleteConfirm).
    click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{delete_id orelse return error.MissingDeleteButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    found_book = false;
    var confirm_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        switch (slot.widget) {
            .label => |l| if (std.mem.indexOf(u8, l.text(), "Frank Herbert") != null) {
                found_book = true;
            },
            .button => |b| if (std.mem.eql(u8, b.label(), "Confirm")) {
                confirm_id = slot.id;
            },
            else => {},
        }
    }
    // Still present -- nothing is deleted until "Confirm" is clicked.
    try std.testing.expect(found_book);

    click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{confirm_id orelse return error.MissingConfirmButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    found_book = false;
    var dialog_widgets_remain = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.indexOf(u8, slot.widget.label.text(), "Frank Herbert") != null) found_book = true;
        if (slot.widget == .button and (std.mem.eql(u8, slot.widget.button.label(), "Confirm") or std.mem.eql(u8, slot.widget.button.label(), "Cancel"))) dialog_widgets_remain = true;
    }
    try std.testing.expect(!found_book);
    // The dialog (root, message, button row, both buttons) must be fully
    // gone too -- Dialog.close() explicitly destroys every widget it
    // created, not just its root (Container.Destroy has no cascading
    // delete, see clay.Dialog's own doc comment on the guest side).
    try std.testing.expect(!dialog_widgets_remain);
}

test "bookstore: cancelling the delete-confirm dialog leaves the book untouched" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/bookstore/guest/bookstore.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, ":memory:");
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var snap: [45]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    // W13: navigate off the Home landing page first, same as the test
    // above.
    var go_to_books_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Go to Books")) go_to_books_id = slot.id;
    }
    var dispatch_buf: [128]u8 = undefined;
    var click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{go_to_books_id orelse return error.MissingGoToBooksButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);

    var author_id: ?u32 = null;
    var title_id: ?u32 = null;
    var genre_id: ?u32 = null;
    var add_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        switch (slot.widget) {
            .textfield => |t| {
                if (std.mem.eql(u8, t.placeholder(), "Author")) author_id = slot.id;
                if (std.mem.eql(u8, t.placeholder(), "Title")) title_id = slot.id;
                if (std.mem.eql(u8, t.placeholder(), "Genre")) genre_id = slot.id;
            },
            .button => |b| {
                if (std.mem.eql(u8, b.label(), "Add Book")) add_id = slot.id;
            },
            else => {},
        }
    }

    var text_scratch: [128]u8 = undefined;
    _ = runtime.widgets.appendTextTo(io, author_id orelse return error.MissingAuthorField, "Ursula K. Le Guin", &text_scratch);
    _ = runtime.widgets.appendTextTo(io, title_id orelse return error.MissingTitleField, "The Dispossessed", &text_scratch);
    _ = runtime.widgets.appendTextTo(io, genre_id orelse return error.MissingGenreField, "Sci-Fi", &text_scratch);

    click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{add_id orelse return error.MissingAddButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    var delete_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Delete")) delete_id = slot.id;
    }

    click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{delete_id orelse return error.MissingDeleteButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    var cancel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Cancel")) cancel_id = slot.id;
    }

    click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{cancel_id orelse return error.MissingCancelButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    var found_book = false;
    var dialog_widgets_remain = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.indexOf(u8, slot.widget.label.text(), "Ursula K. Le Guin") != null) found_book = true;
        if (slot.widget == .button and (std.mem.eql(u8, slot.widget.button.label(), "Confirm") or std.mem.eql(u8, slot.widget.button.label(), "Cancel"))) dialog_widgets_remain = true;
    }
    // Cancel leaves the book alone -- OnResult only runs its real body for
    // "Confirm" (see showDeleteConfirm's guest-side branch), but the
    // dialog itself is still fully destroyed either way (Dialog.close()
    // runs unconditionally in OnResult before the button-specific check).
    try std.testing.expect(found_book);
    try std.testing.expect(!dialog_widgets_remain);
}

// Small helper for the W13 test below: does any widget in `snap[0..n]`
// match `kind`/`text`? Kept generic over Button/Label (both expose their
// text via `.label()`/`.text()`) rather than duplicating this scan four
// times over per assertion.
fn findBreadcrumbWidget(snap: []const WidgetHost.Slot, comptime kind: WidgetHost.WidgetKind, text: []const u8) ?u32 {
    for (snap) |slot| {
        switch (kind) {
            .button => if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), text)) return slot.id,
            .label => if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), text)) return slot.id,
            else => unreachable,
        }
    }
    return null;
}

test "W13: a breadcrumb trail reflects the real navigation path and OnCrumbClick actually navigates through a real guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/bookstore/guest/bookstore.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, ":memory:");
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var snap: [45]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    // Lands on Home: a single "Home" crumb -- the current page, so it's a
    // plain Label (CreateBreadcrumbs' own last-crumb-is-non-clickable
    // contract, same "not a Button" precedent Divider/Toggle established
    // for "this widget doesn't do X"), not yet a Button anywhere. The
    // Books page's own widgets don't exist yet.
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .label, "Home") != null);
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .button, "Home") == null);
    const go_to_books_id = findBreadcrumbWidget(snap[0..n], .button, "Go to Books") orelse return error.MissingGoToBooksButton;
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .button, "Add Book") == null);

    var dispatch_buf: [128]u8 = undefined;
    var click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{go_to_books_id});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    // Now on Books: the trail grew to "Home" (now a real, clickable Button
    // -- no longer the current page) / "Books" (the new current page, a
    // Label). Home's own widgets (the welcome message, "Go to Books") are
    // gone -- destroyHomePage() ran, not just a visual change -- and the
    // Books page's own widgets exist.
    const home_button_id = findBreadcrumbWidget(snap[0..n], .button, "Home") orelse return error.MissingHomeCrumbButton;
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .label, "Books") != null);
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .button, "Go to Books") == null);
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .button, "Add Book") != null);

    click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{home_button_id});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    // Back on Home: the trail shrank back to a single non-clickable "Home"
    // Label -- the old "Books" crumb doesn't linger as a clickable link
    // back to it (per Quinn's own framing of the real navigation model),
    // and the Books page's own widgets are gone again.
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .label, "Home") != null);
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .button, "Home") == null);
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .label, "Books") == null);
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .button, "Go to Books") != null);
    try std.testing.expect(findBreadcrumbWidget(snap[0..n], .button, "Add Book") == null);
}

test "widget host functions: create/get/set/destroy round trip through a trivial guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/counter/guest/counter.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, ":memory:");
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, false);
    runtime.initGuest(io);

    // The trivial counter guest creates exactly one button in natyv_init.
    var snap: [4]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(snap[0].widget == .button);
    const widget_id = snap[0].id;

    var dispatch_buf: [128]u8 = undefined;
    const dispatch_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{widget_id});

    const resp1 = runtime.call(io, "natyv_dispatch", dispatch_payload) orelse return error.CallFailed;
    try std.testing.expect(std.mem.indexOf(u8, resp1, "\"counter\":1") != null);

    const resp2 = runtime.call(io, "natyv_dispatch", dispatch_payload) orelse return error.CallFailed;
    try std.testing.expect(std.mem.indexOf(u8, resp2, "\"counter\":2") != null);
}

test "Clay toolchain: two GROW children split a fixed-size parent's width evenly" {
    const result = try ClayLayout.proveTwoGrowChildrenSplitEvenly(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 150), result.child_a.width, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 150), result.child_b.width, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100), result.child_a.height, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 150), result.child_b.x, 1.0);
}

test "F1: FreeType + SDL_ttf toolchain loads the real embedded Inter font and measures real glyphs" {
    const size = try Font.proveFontRenderingToolchain();
    try std.testing.expect(size.w > 0);
    try std.testing.expect(size.h > 0);
}

test "F2: the persistent default-font capability loads Inter and reports real font metrics" {
    var font_cap = try Font.init();
    defer font_cap.deinit();

    const height = c.TTF_GetFontHeight(font_cap.font);
    try std.testing.expect(height > 0);
}

test "L2: parent_id and Clay style survive a widget-registry snapshot round trip" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    const parent_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 300, .h = 100 }, false) }, null, .{}) orelse return error.RegistryFull;

    const child_style: WidgetHost.ClayStyle = .{
        .sizing = .{
            .width = .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = 0, .max = std.math.floatMax(f32) } } },
            .height = .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = 40, .max = 40 } } },
        },
        .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 },
        .child_gap = 6,
        .direction = c.CLAY_TOP_TO_BOTTOM,
        .child_alignment = .{ .x = c.CLAY_ALIGN_X_CENTER, .y = c.CLAY_ALIGN_Y_TOP },
    };
    const child_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, parent_id, child_style) orelse return error.RegistryFull;

    var snap: [4]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 2), n);

    var found_child = false;
    var found_parent = false;
    for (snap[0..n]) |slot| {
        if (slot.id == child_id) {
            found_child = true;
            try std.testing.expectEqual(parent_id, slot.parent_id);
            try std.testing.expectEqual(@as(u16, 8), slot.clay_style.padding.left);
            try std.testing.expectEqual(@as(u16, 6), slot.clay_style.child_gap);
            try std.testing.expectEqual(c.CLAY_TOP_TO_BOTTOM, slot.clay_style.direction);
            try std.testing.expectEqual(c.CLAY__SIZING_TYPE_GROW, slot.clay_style.sizing.width.type);
        } else if (slot.id == parent_id) {
            found_parent = true;
            try std.testing.expectEqual(@as(?u32, null), slot.parent_id);
        }
    }
    try std.testing.expect(found_child);
    try std.testing.expect(found_parent);
}

test "L3: natyv_clay_create_container/_button through a real compiled guest, gated by ui.backend" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // 45, not 8: natyv_init creates container + button + checkbox + 2 radio
    // buttons + a progress bar (W1, 6 widgets) + a W2 scroll container + 5
    // row labels (6 more) + a W3 slider (1 more) + a W4 dropdown trigger
    // button (1 more) + a W5 modal trigger button (1 more) + a W6 combobox
    // TextField (1 more) + a W7 toast trigger button and the persistent
    // toast-stack container (2 more) + a W9 menu trigger button (1 more) +
    // a W11 divider (1 more) + a W10 TextArea and its char-count Label (2
    // more) + a W12 toggle and its status Label (2 more) + a W14 badge row
    // and its 3 Badges (4 more) + a W15 "?" help Button (1 more) + a W16
    // date/time picker trigger and its result Label (2 more) + a W17
    // Quantity row/label/NumericStepper and a View row/label/
    // SegmentedControl (6 more) + a W18 popover trigger (1 more) + a W19
    // Tabs widget, its 3 panels, and each panel's own Label (7 more) -- 45
    // widgets total (the dropdown's floating panel, the modal's panel, the
    // combobox's options panel, the menu's panel/submenu, the W15 tooltip
    // panel/label, the W16 picker's own panel/grid/steppers, and the W18
    // popover's own panel/label/checkbox/close-button are all only created
    // on demand, not by natyv_init -- see the W4/W5/W6/W7/W9/W15/W16/W18
    // tests below; the toast stack itself IS created here, unlike those,
    // but individual toasts inside it aren't -- the W19 Tabs widget and its
    // 3 panels/labels ARE all created here too, unlike Popover, since
    // there's no open/close state for this one, see tabsID's own doc
    // comment in the fixture guest). Same silent-truncation risk documented
    // at W1's identical bump from 4 to 8 -- snapshot() caps at out.len with
    // no error, so every clay-fixture-loading test's buffer needs auditing
    // whenever natyv_init grows, not just the test being extended.
    var snap: [48]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 45), n);

    // W2: the fixture now creates a *second* top-level container (the
    // scroll container, parent_id == null just like this one) alongside
    // its 5 row labels, so "the first/only .container in the snapshot" is
    // no longer a unique match -- derive cid from the button's own
    // parent_id instead, which is unambiguous regardless of how many other
    // containers exist elsewhere in the tree.
    var button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Grow Button")) {
            button_id = slot.id;
        }
    }
    const bid = button_id orelse return error.MissingButton;
    var container_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.id == bid) container_id = slot.parent_id;
    }
    const cid = container_id orelse return error.MissingContainer;

    for (snap[0..n]) |slot| {
        if (slot.id == cid) {
            try std.testing.expectEqual(@as(?u32, null), slot.parent_id);
            try std.testing.expectEqual(c.CLAY__SIZING_TYPE_FIXED, slot.clay_style.sizing.width.type);
            try std.testing.expectApproxEqAbs(@as(f32, 300), slot.clay_style.sizing.width.size.minMax.max, 0.01);
            try std.testing.expectEqual(@as(u16, 8), slot.clay_style.padding.left);
            try std.testing.expectEqual(@as(u16, 6), slot.clay_style.child_gap);
            try std.testing.expectEqual(c.CLAY_TOP_TO_BOTTOM, slot.clay_style.direction);
        } else if (slot.id == bid) {
            try std.testing.expectEqual(@as(?u32, cid), slot.parent_id);
            try std.testing.expectEqual(c.CLAY__SIZING_TYPE_GROW, slot.clay_style.sizing.width.type);
            try std.testing.expectEqual(c.CLAY__SIZING_TYPE_FIXED, slot.clay_style.sizing.height.type);
            try std.testing.expectApproxEqAbs(@as(f32, 40), slot.clay_style.sizing.height.size.minMax.max, 0.01);
        }
    }
}

test "L4: dirty-flag caching skips Clay recompute on an unchanged frame, real geometry gets written back" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    var clay_layout = try ClayLayout.init(allocator, 300, 100, font_cap.font);
    defer clay_layout.deinit(allocator);

    // First frame: nothing computed yet, so this must run Clay for real.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [29]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    // W4: the fixture now creates a *second* button (the dropdown trigger,
    // "Select...", Fixed height 32) alongside "Grow Button" (GROW width,
    // Fixed height 40) -- "the button in the snapshot" is no longer
    // unique, same class of fix the L3 test's cid derivation already
    // needed at W2. Match by label instead of taking whichever comes last.
    var button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Grow Button")) button_id = slot.id;
    }
    const bid = button_id orelse return error.MissingButton;

    // The button is GROW-width inside an 8px-padded 300px container -- it
    // should have real, non-zero computed geometry now, not the zeroed
    // rect it was created with in L3.
    for (snap[0..n]) |slot| {
        if (slot.id == bid) {
            try std.testing.expect(slot.widget.button.rect.w > 100);
            try std.testing.expectApproxEqAbs(@as(f32, 40), slot.widget.button.rect.h, 0.01);
        }
    }

    // Second frame: nothing changed since the first -- must skip the real
    // Clay computation entirely, not just produce the same numbers.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    // Mutating a Clay-managed widget's text bumps layout_generation (see
    // WidgetHost.setTextHostFn) -- the next frame must recompute for real.
    // Routed through the guest's own natyv_dispatch export (which calls
    // natyv_set_text on the button internally), not called directly --
    // natyv_set_text is a host function the guest imports, not a guest
    // export the host can call by name.
    var payload_buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{{\"widget_id\":{d},\"event_type\":\"Grown\"}}", .{bid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;

    clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);
}

fn fixedAxis(v: f32) c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = v, .max = v } } };
}

test "W16: a floating widget that would overflow the bottom of the window flips to open above its trigger instead" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);

    // A top_to_bottom root -- a tall spacer pushes the trigger down near
    // the bottom of a 700px-tall window (620 + 30 = 650), leaving only
    // 50px below it. The floating panel is 200px tall, so attaching below
    // (the default) would put its bottom at 850 -- 150px past the window.
    const root_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(700) },
        .direction = c.CLAY_TOP_TO_BOTTOM,
    }) orelse return error.RegistryFull;
    _ = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, root_id, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(620) },
    }) orelse return error.RegistryFull;
    const trigger_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, root_id, .{
        .sizing = .{ .width = fixedAxis(100), .height = fixedAxis(30) },
    }) orelse return error.RegistryFull;
    const panel_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, trigger_id, .{
        .sizing = .{ .width = fixedAxis(100), .height = fixedAxis(200) },
        .floating = true,
    }) orelse return error.RegistryFull;

    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    // A flip event means two real Clay_EndLayout calls this recompute.
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    var trigger_rect: c.SDL_FRect = undefined;
    var panel_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == trigger_id) trigger_rect = slot.widget.container.rect;
        if (slot.id == panel_id) panel_rect = slot.widget.container.rect;
    }

    // Fully visible within the window now, not overflowing past it.
    try std.testing.expect(panel_rect.y + panel_rect.h <= 700.01);
    // Opened *above* the trigger, not below -- proves this is a real flip,
    // not just an incidental clamp to some other position.
    try std.testing.expect(panel_rect.y < trigger_rect.y);
    try std.testing.expectApproxEqAbs(trigger_rect.y, panel_rect.y + panel_rect.h, 0.5);
}

test "W16: a floating widget that already fits below its trigger is not flipped" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);

    // Same shape as the flip test above, but the trigger sits near the
    // *top* this time (a 50px spacer, not 620px) -- plenty of room below
    // for a 200px panel within the 700px window, so this must behave
    // exactly as it did before this fix existed.
    const root_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(700) },
        .direction = c.CLAY_TOP_TO_BOTTOM,
    }) orelse return error.RegistryFull;
    _ = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, root_id, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(50) },
    }) orelse return error.RegistryFull;
    const trigger_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, root_id, .{
        .sizing = .{ .width = fixedAxis(100), .height = fixedAxis(30) },
    }) orelse return error.RegistryFull;
    const panel_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, trigger_id, .{
        .sizing = .{ .width = fixedAxis(100), .height = fixedAxis(200) },
        .floating = true,
    }) orelse return error.RegistryFull;

    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    // No overflow anywhere -- exactly one real Clay_EndLayout, same as
    // every other unflipped-floating test in this file.
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    var trigger_rect: c.SDL_FRect = undefined;
    var panel_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == trigger_id) trigger_rect = slot.widget.container.rect;
        if (slot.id == panel_id) panel_rect = slot.widget.container.rect;
    }

    try std.testing.expectApproxEqAbs(trigger_rect.y + trigger_rect.h, panel_rect.y, 0.5);
}

test "W16: a floating widget that would overflow the right edge of the window flips to open right-aligned instead" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);

    // A left_to_right root -- a wide spacer pushes the trigger over near
    // the right edge of a 900px-wide window (750 + 100 = 850), leaving
    // only 50px to its right. The floating panel is 200px wide, so
    // attaching left-aligned (the default) would put its right edge at
    // 1050 -- 150px past the window.
    const root_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = fixedAxis(900), .height = fixedAxis(700) },
        .direction = c.CLAY_LEFT_TO_RIGHT,
    }) orelse return error.RegistryFull;
    _ = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, root_id, .{
        .sizing = .{ .width = fixedAxis(750), .height = fixedAxis(30) },
    }) orelse return error.RegistryFull;
    const trigger_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, root_id, .{
        .sizing = .{ .width = fixedAxis(100), .height = fixedAxis(30) },
    }) orelse return error.RegistryFull;
    const panel_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, trigger_id, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(50) },
        .floating = true,
    }) orelse return error.RegistryFull;

    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    var trigger_rect: c.SDL_FRect = undefined;
    var panel_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == trigger_id) trigger_rect = slot.widget.container.rect;
        if (slot.id == panel_id) panel_rect = slot.widget.container.rect;
    }

    // Fully visible within the window now, not overflowing past it.
    try std.testing.expect(panel_rect.x + panel_rect.w <= 900.01);
    // Opened right-aligned to the trigger, not left-aligned -- proves
    // this is a real flip, not an incidental clamp.
    try std.testing.expect(panel_rect.x < trigger_rect.x);
    try std.testing.expectApproxEqAbs(trigger_rect.x + trigger_rect.w, panel_rect.x + panel_rect.w, 0.5);
}

test "W18 follow-up: a floating widget anchored inside a scrolling ancestor flips before it overlaps that ancestor's own scrollbar, even though it'd still fit the whole window" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);

    // Mirrors the real bug (Quinn's click-through on the Tooltip): the
    // scrolling ancestor (200px wide) is far narrower than the 900px
    // window. A 60px leading spacer pushes the trigger to x=60 (spans
    // [60,160]) before a 150px floating panel attached left-aligned to it
    // (spans [60,210]) -- comfortably within the *window* (210 < 900, the
    // old check alone would never flip this) but its right edge still
    // passes the ancestor's own effective boundary (200 -
    // ScrollBar.thickness - ScrollBar.inset = 192) -- i.e. it'd overlap
    // where that ancestor's own scrollbar sits. The trigger is positioned
    // with enough room to its right (60..160, room to spare before 192)
    // that flipping alone fully resolves it without needing the separate
    // left-edge clamp below -- see the next test for that case.
    const root_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = fixedAxis(900), .height = fixedAxis(700) },
        .direction = c.CLAY_LEFT_TO_RIGHT,
    }) orelse return error.RegistryFull;
    const scroll_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, root_id, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(700) },
        .scroll_vertical = true,
    }) orelse return error.RegistryFull;
    _ = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, scroll_id, .{
        .sizing = .{ .width = fixedAxis(60), .height = fixedAxis(30) },
    }) orelse return error.RegistryFull;
    const trigger_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, scroll_id, .{
        .sizing = .{ .width = fixedAxis(100), .height = fixedAxis(30) },
    }) orelse return error.RegistryFull;
    const panel_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, trigger_id, .{
        .sizing = .{ .width = fixedAxis(150), .height = fixedAxis(50) },
        .floating = true,
    }) orelse return error.RegistryFull;

    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    // A flip event means two real Clay_EndLayout calls this recompute.
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    var trigger_rect: c.SDL_FRect = undefined;
    var panel_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == trigger_id) trigger_rect = slot.widget.container.rect;
        if (slot.id == panel_id) panel_rect = slot.widget.container.rect;
    }

    // Opened right-aligned to the trigger, not left-aligned -- proves this
    // is a real flip triggered by the scrolling ancestor's own boundary
    // (window_w=900 alone would never have flipped a 150px-wide panel).
    try std.testing.expect(panel_rect.x < trigger_rect.x);
    try std.testing.expectApproxEqAbs(trigger_rect.x + trigger_rect.w, panel_rect.x + panel_rect.w, 0.5);
    // Fully clear of the scrollbar now, and never needed clamping to do
    // it (there was room -- see the doc comment above).
    try std.testing.expect(panel_rect.x >= 0);
    try std.testing.expect(panel_rect.x + panel_rect.w <= 192.01);
}

test "W18 follow-up: a floating widget too wide to clear a scrolling ancestor's scrollbar even after flipping gets clamped to the window's left edge instead of overflowing it" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);

    // Exactly Quinn's own follow-up report: flipping alone isn't always
    // enough -- the flip logic only ever checks the right/bottom edges it
    // exists to fix, never the opposite edge the flip itself might now
    // cross. Here the trigger sits flush at the scroll ancestor's own left
    // edge (x=0) and the panel (195px) is wider than the room flipping can
    // recover (trigger is only 100px wide), so the flipped position would
    // land at x=-95 -- past the *window's* own left edge. The final clamp
    // step pins it to x=0 instead of leaving it negative. This is
    // explicitly the "not achievable either way" case Quinn accepted as
    // fine for now (real tooltip/popover content is usually far narrower
    // than its own scroll column).
    const root_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = fixedAxis(900), .height = fixedAxis(700) },
        .direction = c.CLAY_LEFT_TO_RIGHT,
    }) orelse return error.RegistryFull;
    const scroll_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, root_id, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(700) },
        .scroll_vertical = true,
    }) orelse return error.RegistryFull;
    const trigger_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, scroll_id, .{
        .sizing = .{ .width = fixedAxis(100), .height = fixedAxis(30) },
    }) orelse return error.RegistryFull;
    const panel_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, trigger_id, .{
        .sizing = .{ .width = fixedAxis(195), .height = fixedAxis(50) },
        .floating = true,
    }) orelse return error.RegistryFull;

    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    var panel_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == panel_id) panel_rect = slot.widget.container.rect;
    }

    // Never negative -- clamped to the window's own left edge, not left
    // to overflow it the way the flip alone would have.
    try std.testing.expectApproxEqAbs(@as(f32, 0), panel_rect.x, 0.01);
}

test "W18 follow-up (round 2): clamping a floating widget also moves its own children by the same amount, not just its own background" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);

    // Exactly the real bug (Quinn's follow-up round): round 1 of the fix
    // clamped the panel's own rect but left a *child* of the panel (here,
    // a plain Container standing in for the Tooltip's real Label) at
    // Clay's original, unclamped resolved position -- Clay computed the
    // child's absolute position during its own real layout pass, based on
    // wherever the panel actually landed per Clay's math, with no idea a
    // clamp would be applied afterward. Same geometry as the previous
    // test (panel wider than the room flipping can recover), but this one
    // also has a child 10px in from the panel's own left edge and checks
    // that the child moved by the exact same delta as the panel did.
    const root_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = fixedAxis(900), .height = fixedAxis(700) },
        .direction = c.CLAY_LEFT_TO_RIGHT,
    }) orelse return error.RegistryFull;
    const scroll_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, root_id, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(700) },
        .scroll_vertical = true,
    }) orelse return error.RegistryFull;
    const trigger_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, scroll_id, .{
        .sizing = .{ .width = fixedAxis(100), .height = fixedAxis(30) },
    }) orelse return error.RegistryFull;
    const panel_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, trigger_id, .{
        .sizing = .{ .width = fixedAxis(195), .height = fixedAxis(50) },
        .padding = .{ .left = 10, .right = 0, .top = 0, .bottom = 0 },
        .floating = true,
    }) orelse return error.RegistryFull;
    const child_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, panel_id, .{
        .sizing = .{ .width = fixedAxis(100), .height = fixedAxis(20) },
    }) orelse return error.RegistryFull;

    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    var panel_rect: c.SDL_FRect = undefined;
    var child_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == panel_id) panel_rect = slot.widget.container.rect;
        if (slot.id == child_id) child_rect = slot.widget.container.rect;
    }

    // The panel itself is clamped to the window's left edge, same as the
    // previous test.
    try std.testing.expectApproxEqAbs(@as(f32, 0), panel_rect.x, 0.01);
    // The child moved along with it, by the exact same amount -- its
    // 10px left padding offset from the panel is preserved, it isn't
    // still sitting wherever Clay originally (and wrongly) resolved it.
    try std.testing.expectApproxEqAbs(panel_rect.x + 10, child_rect.x, 0.01);
}

// W17: pure host-level tests proving `WidgetHost.setStepperValue`/
// `setSegmentedIndex` are wired correctly (finds the right slot by id,
// rejects a mismatched kind, reports the actual resolved value) -- the
// same "insertWithLayout directly, no compiled guest needed" pattern the
// W16 flip tests above already establish. The underlying clamp/wrap/
// clamp-index logic itself is already covered by NumericStepper.zig's and
// SegmentedControl.zig's own pure geometry tests; this only proves
// `main.zig`'s Left/Right keyboard handling (which calls these exact
// functions with an already-delta'd value, see `notifyStepperValue`/
// `notifySegmentedValue`) reaches a real widget correctly.
test "W17: WidgetHost.setStepperValue resolves an out-of-range value and reports what actually got stored" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    // hour 23, wrap=true -- mirrors the Date & time picker's own hour
    // stepper exactly. A Left/Right press computes `value +/- step`
    // (here: 23 + 1 = 24) and hands the raw, unresolved result to
    // setStepperValue, same as `notifyStepperValue` does.
    const id = runtime.widgets.insertWithLayout(io, .{ .numeric_stepper = NumericStepper.init(.{ .x = 0, .y = 0, .w = 90, .h = 24 }, 23, 0, 23, 1, true) }, null, .{}) orelse return error.RegistryFull;

    const resolved = runtime.widgets.setStepperValue(io, id, 24) orelse return error.ValueUnchanged;
    try std.testing.expectEqual(@as(i32, 0), resolved);

    var snap: [4]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == id) try std.testing.expectEqual(@as(i32, 0), slot.widget.numeric_stepper.value);
    }

    // Wrong kind -- a container id was never a numeric_stepper, must
    // report "no change" rather than silently mutating something.
    const other_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{}) orelse return error.RegistryFull;
    try std.testing.expectEqual(@as(?i32, null), runtime.widgets.setStepperValue(io, other_id, 5));
}

test "W17: WidgetHost.setSegmentedIndex clamps an out-of-range index and reports what actually got stored" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    const id = runtime.widgets.insertWithLayout(io, .{ .segmented_control = SegmentedControl.init(.{ .x = 0, .y = 0, .w = 180, .h = 24 }, &.{ "List", "Grid", "Table" }, 2) }, null, .{}) orelse return error.RegistryFull;

    // A Right press at the last segment computes `selected_index + 1`
    // (here: 2 + 1 = 3), same as `notifySegmentedValue` does -- out of
    // range for a 3-segment control, must clamp to the last index (2),
    // not wrap or go out of bounds.
    const resolved = runtime.widgets.setSegmentedIndex(io, id, 3);
    try std.testing.expectEqual(@as(?usize, null), resolved); // unchanged: already at 2, clamps back to 2.

    var snap: [4]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == id) try std.testing.expectEqual(@as(usize, 2), slot.widget.segmented_control.selected_index);
    }

    // A real change: Left from index 2 -> 1.
    const moved = runtime.widgets.setSegmentedIndex(io, id, 1) orelse return error.ValueUnchanged;
    try std.testing.expectEqual(@as(usize, 1), moved);
}

test "W2: natyv_clay_create_container's scroll_vertical/scroll_horizontal round-trip into ClayStyle" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [29]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);

    // The scroll container is the top-level (parent_id == null) container
    // that parents the *most* Label children (its 5 fixed row labels) --
    // the original container also picks up a growing handful of its own
    // demo Labels over time (W10's char-count display, W12's toggle status,
    // and presumably more as future widgets land there), so a fixed
    // threshold ("more than 1", "more than 2", ...) keeps re-breaking every
    // time one more lands -- matching on the max instead ties the check to
    // the scroll container's own real invariant (its row count) rather than
    // an unrelated and ever-growing count on a different container. Still
    // deliberately structural, not `scroll_vertical` itself, to avoid a
    // tautological test.
    var best_id: ?u32 = null;
    var best_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.widget != .container or slot.parent_id != null) continue;
        var label_child_count: usize = 0;
        for (snap[0..n]) |maybe_child| {
            if (maybe_child.parent_id) |pid| {
                if (pid == slot.id and maybe_child.widget == .label) label_child_count += 1;
            }
        }
        if (label_child_count > best_count) {
            best_count = label_child_count;
            best_id = slot.id;
        }
    }
    const scroll_id = best_id orelse return error.MissingScrollContainer;
    for (snap[0..n]) |slot| {
        if (slot.id == scroll_id) {
            try std.testing.expect(slot.clay_style.scroll_vertical);
            try std.testing.expect(!slot.clay_style.scroll_horizontal);
        }
    }
}

// W2's real correctness gate. Clay_UpdateScrollContainers only ever applies
// a wheel delta to whichever scroll container is topmost in
// `context->pointerOverIds` -- which is only populated by the *previous*
// real layout pass's post-EndLayout hit test, using whatever mouse position
// that pass was given. So establishing scroll routing genuinely needs two
// real recomputes: one to declare the scroll container to Clay with the
// mouse already positioned over it (registering it in pointerOverIds), then
// a second that actually carries a nonzero delta. This is inherent to
// Clay's own architecture (confirmed by reading Clay_UpdateScrollContainers'
// real body), not a natyv gap -- see ClayLayout.zig's layoutIfNeeded doc
// comment for the full reasoning.
test "W2: a nonzero scroll delta forces a real Clay recompute even when content generation is unchanged, and moves child rects" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    var clay_layout = try ClayLayout.init(allocator, 600, 200, font_cap.font);
    defer clay_layout.deinit(allocator);

    // Predicted from the fixture's real layout: root is CLAY_LEFT_TO_RIGHT
    // (Clay's own default, unset by main.zig's zeroed root_decl), so the
    // original Fixed(300)x(100) container occupies x:[0,300], and the
    // Fixed(200)x(100) scroll container (created right after it, as a
    // sibling) occupies x:[300,500], both y:[0,100]. Frame 1 must already
    // pass a mouse position over the scroll container -- Clay only
    // registers pointerOverIds from a real EndLayout pass, and this is the
    // only recompute before the scroll-carrying frame below.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 400, 50, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    var snap: [29]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var scroll_container_id: ?u32 = null;
    var row1_id: ?u32 = null;
    var row1_base_y: f32 = undefined;
    for (snap[0..n]) |slot| {
        if (slot.widget != .container or slot.parent_id != null) continue;
        for (snap[0..n]) |maybe_child| {
            if (maybe_child.parent_id) |pid| {
                if (pid == slot.id and maybe_child.widget == .label and std.mem.eql(u8, maybe_child.widget.label.text(), "Scroll Row 1")) {
                    scroll_container_id = slot.id;
                    row1_id = maybe_child.id;
                    row1_base_y = maybe_child.widget.label.rect.y;
                }
            }
        }
    }
    const scid = scroll_container_id orelse return error.MissingScrollContainer;
    const rid = row1_id orelse return error.MissingRow;

    // Defensive sanity check on the layout prediction above, rather than
    // silently trusting it -- if this ever fails, the mouse position fed
    // into frame 1 above needs updating, not the assertions below.
    for (snap[0..n]) |slot| {
        if (slot.id == scid) {
            try std.testing.expectApproxEqAbs(@as(f32, 300), slot.widget.container.rect.x, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 200), slot.widget.container.rect.w, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 100), slot.widget.container.rect.h, 0.01);
        }
    }

    // Content is 5 rows * Fixed(40) = 200px inside a Fixed(100) container --
    // 100px of overflow. A delta far beyond that must clamp exactly to
    // -100, not merely "move some amount."
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 400, 50, false, 0, -1000);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);

    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == rid) {
            try std.testing.expectApproxEqAbs(row1_base_y - 100, slot.widget.label.rect.y, 0.01);
        }
    }
}

// The crux regression test for W2: reproduces the real bug found by reading
// Clay_UpdateScrollContainers' actual implementation (not just its header
// comment) -- calling it on a frame with no real recompute silently evicts
// the scroll container's tracked position, snapping it back to the top a
// couple frames after the user stops scrolling. A shallow "one scroll ->
// rect moved" test (the one above) would still pass even with that bug
// reintroduced; this test specifically exercises a genuine skip frame
// between two real scrolls and asserts position is preserved and
// accumulates, not reset.
test "W2: scroll position survives an intervening frame where nothing else changes, and accumulates rather than resetting" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    var clay_layout = try ClayLayout.init(allocator, 600, 200, font_cap.font);
    defer clay_layout.deinit(allocator);

    // Frame 1: baseline, mouse pre-positioned over the scroll container --
    // see the previous test's identical layout prediction/reasoning.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 400, 50, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    var snap: [29]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);
    var row1_id: ?u32 = null;
    var row1_base_y: f32 = undefined;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Scroll Row 1")) {
            row1_id = slot.id;
            row1_base_y = slot.widget.label.rect.y;
        }
    }
    const rid = row1_id orelse return error.MissingRow;

    // Frame 2: a real, moderate scroll (well short of the -100 clamp found
    // in the previous test) -- recompute #2, row1 shifts up by 30px.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 400, 50, false, 0, -3);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);
    n = runtime.widgets.snapshot(io, &snap);
    var y_after_first_scroll: f32 = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == rid) {
            y_after_first_scroll = slot.widget.label.rect.y;
            try std.testing.expectApproxEqAbs(row1_base_y - 30, y_after_first_scroll, 0.01);
        }
    }

    // Frame 3: a genuine skip frame -- generation unchanged, zero delta.
    // Must NOT recompute, and the scroll position must NOT be reset.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 400, 50, false, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == rid) try std.testing.expectApproxEqAbs(y_after_first_scroll, slot.widget.label.rect.y, 0.01);
    }

    // Frame 4: scroll again by the same moderate amount -- must land at a
    // further, *cumulative* offset from frame 2, not reset toward the top
    // first. If Clay_UpdateScrollContainers had been called on frame 3's
    // skip above, this would land back at -30 from the (wrongly reset) top
    // instead of -60 from the real starting position.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 400, 50, false, 0, -3);
    try std.testing.expectEqual(@as(usize, 3), clay_layout.recompute_count);
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == rid) try std.testing.expectApproxEqAbs(row1_base_y - 60, slot.widget.label.rect.y, 0.01);
    }
}

test "F3: syncTextObjects skips re-syncing a widget's TTF_Text on an unchanged frame, real sync happens on a text change" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("f3-test", 64, 64, c.SDL_WINDOW_HIDDEN) orelse return error.SdlWindowFailed;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    const engine = c.TTF_CreateRendererTextEngine(renderer) orelse return error.TextEngineFailed;
    defer c.TTF_DestroyRendererTextEngine(engine);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    // First sync: nothing cached yet, must create the button's TTF_Text.
    runtime.widgets.syncTextObjects(io, engine, font_cap.font);

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [29]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    // W4: two buttons exist now (the fixture's own "Grow Button" plus the
    // dropdown trigger) -- every button gets synced once on this first
    // call regardless of which, so the sync_count==1 check still holds for
    // both, but `bid` itself must be "Grow Button" specifically: the
    // fixture's own natyv_dispatch fallback always relabels *that* widget
    // (its package-level buttonID), not whichever id the dispatch payload
    // below happens to name.
    var button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button) {
            try std.testing.expectEqual(@as(u32, 1), slot.widget.button.sync_count);
            if (std.mem.eql(u8, slot.widget.button.label(), "Grow Button")) button_id = slot.id;
        }
    }
    const bid = button_id orelse return error.MissingButton;

    // Second sync: label unchanged -- must skip TTF_SetTextString entirely,
    // not just produce the same string again.
    runtime.widgets.syncTextObjects(io, engine, font_cap.font);
    _ = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == bid) try std.testing.expectEqual(@as(u32, 1), slot.widget.button.sync_count);
    }

    // Relabel via the guest's real natyv_dispatch -> natyv_set_text path
    // (same mechanism the L4 test above uses) -- must force a real re-sync
    // on the next call.
    var payload_buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{{\"widget_id\":{d},\"event_type\":\"Grown\"}}", .{bid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;

    runtime.widgets.syncTextObjects(io, engine, font_cap.font);
    _ = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == bid) try std.testing.expectEqual(@as(u32, 2), slot.widget.button.sync_count);
    }
}

// F3 regression: Quinn hit a real crash clicking bookstore's "Add Book"
// button -- refreshBookList destroys every old row's widgets and creates
// new ones, and destroying a widget with a live TTF_Text called
// TTF_DestroyText directly from inside destroyWidgetHostFn, a host function
// that (per Dispatch.zig's own doc comment) runs on the worker thread, not
// the main thread that owns the text engine SDL_ttf requires TTF_Text be
// destroyed on. Fixed by queuing the pointer (`pending_text_destroys`) for
// the main thread to actually destroy instead. This test reproduces the
// real trigger as faithfully as a headless test can: a genuine second OS
// thread (`Dispatch.run`, the exact function `main.zig` spawns) processing
// a real `.click` event off a real `EventQueue` -- not a synchronous
// same-thread `runtime.call` the way the L4/F3 tests above use, which
// wouldn't violate SDL_ttf's thread-affinity rule even with the bug
// present, since everything would happen on the one test thread regardless.
test "F3 regression: destroying a widget's TTF_Text from the real worker thread doesn't crash" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("f3-regression-test", 64, 64, c.SDL_WINDOW_HIDDEN) orelse return error.SdlWindowFailed;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    const engine = c.TTF_CreateRendererTextEngine(renderer) orelse return error.TextEngineFailed;
    defer c.TTF_DestroyRendererTextEngine(engine);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    // Give the initial button a real TTF_Text before triggering the click
    // -- otherwise there'd be nothing for the bug to actually crash on.
    runtime.widgets.syncTextObjects(io, engine, font_cap.font);

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [29]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);
    // W4: must be "Grow Button" specifically, not whichever button the
    // scan finds last -- a real click's widget_id now matters (the
    // dropdown trigger routes to open/close instead of the destroy/
    // recreate behavior this test is actually exercising), not just the
    // "click" event_type string the way it did before real per-widget
    // click routing existed.
    var button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Grow Button")) button_id = slot.id;
    }
    const bid = button_id orelse return error.MissingButton;

    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    // Real second OS thread, same call main.zig itself makes -- the guest's
    // natyv_dispatch (and the natyv_destroy_widget it calls on a click, see
    // clay-fixture's guest/main.go) genuinely runs off this thread, not the
    // test's own, exactly like the real crash Quinn hit.
    const worker = try std.Thread.spawn(.{}, Dispatch.run, .{ &runtime, io, &queue });

    queue.push(io, bid, .click, "", 0);

    // Simulates main.zig's frame loop -- the only thread allowed to
    // actually call TTF_DestroyText/TTF_CreateText for these objects.
    // Polls for the real guest-driven state change (old button destroyed,
    // new one created and labeled) instead of a fixed sleep.
    var relabeled = false;
    var i: u32 = 0;
    while (i < 500 and !relabeled) : (i += 1) {
        runtime.widgets.flushPendingTextDestroys(io);
        runtime.widgets.syncTextObjects(io, engine, font_cap.font);
        n = runtime.widgets.snapshot(io, &snap);
        // Real main.zig draws every frame too -- matching that here, not
        // just polling registry state, since the actual crash may need a
        // concurrent TTF_DrawRendererText touching the same text engine's
        // shared atlas state while the worker thread destroys a text object,
        // not just the destroy call in isolation.
        for (snap[0..n]) |slot| {
            if (slot.widget == .button) slot.widget.button.drawDecorations(renderer);
            if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Recreated Button")) {
                relabeled = true;
            }
        }
        if (!relabeled) try io.sleep(.fromMilliseconds(2), .awake);
    }

    queue.requestShutdown(io);
    worker.join();

    // The real proof this test exists for is that it got this far at all
    // without crashing -- these assertions confirm the guest-visible state
    // ended up correct too, not just that nothing crashed.
    try std.testing.expect(relabeled);
    n = runtime.widgets.snapshot(io, &snap);
    // W4: the fixture now also has a "Select..." dropdown trigger button
    // that has nothing to do with this destroy/recreate cycle -- assert
    // exactly one "Recreated Button" exists (not zero, not duplicated) and
    // that the unrelated trigger is untouched, rather than a bare global
    // button count that broke the moment a second, unrelated button
    // existed in the fixture at all.
    var recreated_count: u32 = 0;
    var trigger_found = false;
    for (snap[0..n]) |slot| {
        if (slot.widget != .button) continue;
        if (std.mem.eql(u8, slot.widget.button.label(), "Recreated Button")) recreated_count += 1;
        if (std.mem.eql(u8, slot.widget.button.label(), "Select...")) trigger_found = true;
    }
    try std.testing.expectEqual(@as(u32, 1), recreated_count);
    try std.testing.expect(trigger_found);
}

test "nextFocusable: empty list returns null regardless of current or direction" {
    try std.testing.expectEqual(@as(?u32, null), WidgetHost.nextFocusable(&.{}, null, true));
    try std.testing.expectEqual(@as(?u32, null), WidgetHost.nextFocusable(&.{}, 5, false));
}

test "nextFocusable: single id wraps to itself both directions" {
    const ids = [_]u32{7};
    try std.testing.expectEqual(@as(?u32, 7), WidgetHost.nextFocusable(&ids, null, true));
    try std.testing.expectEqual(@as(?u32, 7), WidgetHost.nextFocusable(&ids, 7, true));
    try std.testing.expectEqual(@as(?u32, 7), WidgetHost.nextFocusable(&ids, 7, false));
}

test "nextFocusable: forward and backward wrap around the ends of a real list" {
    const ids = [_]u32{ 3, 5, 9 };

    // No current focus: forward starts at the first id, backward at the last.
    try std.testing.expectEqual(@as(?u32, 3), WidgetHost.nextFocusable(&ids, null, true));
    try std.testing.expectEqual(@as(?u32, 9), WidgetHost.nextFocusable(&ids, null, false));

    // Ordinary steps.
    try std.testing.expectEqual(@as(?u32, 5), WidgetHost.nextFocusable(&ids, 3, true));
    try std.testing.expectEqual(@as(?u32, 9), WidgetHost.nextFocusable(&ids, 5, true));
    try std.testing.expectEqual(@as(?u32, 3), WidgetHost.nextFocusable(&ids, 5, false));

    // Wrap at both ends.
    try std.testing.expectEqual(@as(?u32, 3), WidgetHost.nextFocusable(&ids, 9, true));
    try std.testing.expectEqual(@as(?u32, 9), WidgetHost.nextFocusable(&ids, 3, false));
}

test "nextFocusable: current not present in the list is treated like no current focus" {
    const ids = [_]u32{ 10, 20, 30 };
    // e.g. the previously-focused widget was just destroyed.
    try std.testing.expectEqual(@as(?u32, 10), WidgetHost.nextFocusable(&ids, 99, true));
    try std.testing.expectEqual(@as(?u32, 30), WidgetHost.nextFocusable(&ids, 99, false));
}

test "focusableIdsSorted: only Button/TextField ids come back, sorted ascending, Label/Container excluded" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    // Inserted deliberately out of the order they should come back in, to
    // prove this really sorts rather than happening to already be ordered.
    const label_id = runtime.widgets.insertWithLayout(io, .{ .label = Label.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, "hi") }, null, .{}) orelse return error.RegistryFull;
    const textfield_id = runtime.widgets.insertWithLayout(io, .{ .textfield = TextField.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, "") }, null, .{}) orelse return error.RegistryFull;
    const container_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{}) orelse return error.RegistryFull;
    const button_id = runtime.widgets.insertWithLayout(io, .{ .button = Button.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, "go") }, null, .{}) orelse return error.RegistryFull;
    _ = label_id;
    _ = container_id;

    // button_id was created after textfield_id, so ascending id order is
    // {textfield_id, button_id} -- not creation-call order in this test,
    // proving the sort (not insertion order) is what's actually returned.
    try std.testing.expect(textfield_id < button_id);

    var ids: [8]u32 = undefined;
    const n = runtime.widgets.focusableIdsSorted(io, &ids);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(textfield_id, ids[0]);
    try std.testing.expectEqual(button_id, ids[1]);
}

test "W1: selectRadioExclusive keeps exclusivity within a group and leaves other groups alone" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    // Group 0: three radios. Group 1: one distractor -- selecting something
    // in group 0 must never touch it.
    const a = runtime.widgets.insertWithLayout(io, .{ .radio_button = RadioButton.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 0, "A") }, null, .{}) orelse return error.RegistryFull;
    const b = runtime.widgets.insertWithLayout(io, .{ .radio_button = RadioButton.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 0, "B") }, null, .{}) orelse return error.RegistryFull;
    const rc = runtime.widgets.insertWithLayout(io, .{ .radio_button = RadioButton.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 0, "C") }, null, .{}) orelse return error.RegistryFull;
    const distractor = runtime.widgets.insertWithLayout(io, .{ .radio_button = RadioButton.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 1, "D") }, null, .{}) orelse return error.RegistryFull;

    // Select A, then the distractor (its own group, harmless), then C --
    // selecting C must deselect A (the previously-selected sibling in its
    // group) but must not touch the distractor in the other group.
    runtime.widgets.selectRadioExclusive(io, a);
    runtime.widgets.selectRadioExclusive(io, distractor);
    runtime.widgets.selectRadioExclusive(io, rc);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        const checked = slot.widget.radio_button.checked;
        if (slot.id == a) try std.testing.expect(!checked);
        if (slot.id == b) try std.testing.expect(!checked);
        if (slot.id == rc) try std.testing.expect(checked);
        if (slot.id == distractor) try std.testing.expect(checked);
    }
}

test "W1: checkbox/radio/progress bar created and mutated through a real compiled guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [29]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var checkbox_id: ?u32 = null;
    var radio_a_id: ?u32 = null;
    var radio_b_id: ?u32 = null;
    var progress_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        switch (slot.widget) {
            .checkbox => |cb| {
                try std.testing.expectEqualStrings("Enable Feature", cb.label());
                try std.testing.expect(!cb.checked);
                checkbox_id = slot.id;
            },
            .radio_button => |r| {
                if (std.mem.eql(u8, r.label(), "Option A")) {
                    try std.testing.expect(r.checked);
                    radio_a_id = slot.id;
                } else if (std.mem.eql(u8, r.label(), "Option B")) {
                    try std.testing.expect(!r.checked);
                    radio_b_id = slot.id;
                }
            },
            .progress_bar => |p| {
                try std.testing.expectApproxEqAbs(@as(f32, 0.25), p.value, 0.001);
                progress_id = slot.id;
            },
            else => {},
        }
    }
    const cbid = checkbox_id orelse return error.MissingCheckbox;
    const raid = radio_a_id orelse return error.MissingRadioA;
    const rbid = radio_b_id orelse return error.MissingRadioB;
    const prid = progress_id orelse return error.MissingProgressBar;

    // Real guest-routed checkbox toggle (natyv_set_checked via natyv_dispatch).
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"CheckIt\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == cbid) try std.testing.expect(slot.widget.checkbox.checked);
    }

    // Real guest-routed radio selection -- must flip exclusivity: B becomes
    // checked, A (checked since natyv_init) becomes unchecked.
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"SelectRadioB\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == raid) try std.testing.expect(!slot.widget.radio_button.checked);
        if (slot.id == rbid) try std.testing.expect(slot.widget.radio_button.checked);
    }

    // Real guest-routed progress value change.
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"SetProgressHalf\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == prid) try std.testing.expectApproxEqAbs(@as(f32, 0.5), slot.widget.progress_bar.value, 0.001);
    }
}

test "W3: slider created via natyv_clay_create_slider round-trips its value, and natyv_set_value/natyv_get_value work on it through a real guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var snap: [29]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var slider_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .slider) {
            try std.testing.expectApproxEqAbs(@as(f32, 0.4), slot.widget.slider.value, 0.001);
            slider_id = slot.id;
        }
    }
    const sid = slider_id orelse return error.MissingSlider;

    // Real guest-routed slider value change (natyv_set_value via
    // natyv_dispatch), same shape as W1's SetProgressHalf case above.
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"SetSliderQuarter\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == sid) try std.testing.expectApproxEqAbs(@as(f32, 0.25), slot.widget.slider.value, 0.001);
    }
}

test "W4: a dropdown's floating options panel round-trips floating into ClayStyle, positions below its trigger, and select-and-close destroys it through a real guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // 24, not 16: natyv_init's 18 widgets (see the L3 test's comment
    // above, now 31), plus this test opens the dropdown (panel + 2
    // options = 3 more) -- 34 at peak, comfortably under this buffer's
    // 50. Same silent-truncation risk documented at every prior buffer
    // bump in this file -- snapshot() caps at out.len with no error, and
    // this exact test was the one that caught W16's baseline bump not
    // being propagated here (option_count came back 1, not 2 -- one real
    // option button silently truncated away by what was then a
    // too-small [33] buffer).
    var snap: [50]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    var trigger_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Select...")) {
            trigger_id = slot.id;
            trigger_rect = slot.widget.button.rect;
        }
    }
    const tid = trigger_id orelse return error.MissingTrigger;
    // Not yet open -- natyv_init only ever creates the trigger itself (see
    // the fixture's own doc comment), same "closed by default" state a
    // real dropdown starts in.
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != tid);
    }

    // Real guest-routed open (natyv_clay_create_container with
    // floating:true, via natyv_dispatch -- openDropdown).
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"ToggleDropdown\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) {
            // W4 wire round-trip: floating landed in ClayStyle.
            try std.testing.expect(slot.clay_style.floating);
            panel_id = slot.id;
        }
    }
    const pid = panel_id orelse return error.MissingPanel;

    var option_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button) option_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), option_count);

    // Real Clay layout pass already ran (triggered by the container
    // create above bumping layout_generation) -- the floating panel's
    // real computed rect must be positioned below the trigger's bottom
    // edge (CLAY_ATTACH_POINT_LEFT_BOTTOM/LEFT_TOP, see ClayLayout.zig's
    // openChildren), not left at {0,0} the way it would be if floating
    // positioning silently didn't apply.
    for (snap[0..n]) |slot| {
        if (slot.id == pid) {
            const panel_rect = slot.widget.container.rect;
            try std.testing.expectApproxEqAbs(trigger_rect.x, panel_rect.x, 0.5);
            try std.testing.expectApproxEqAbs(trigger_rect.y + trigger_rect.h, panel_rect.y, 0.5);
        }
    }

    // Real guest-routed select-and-close (natyv_set_text on the trigger +
    // natyv_destroy_widget on the panel/options, via natyv_dispatch --
    // closeDropdown), same "destroy old widgets" pattern examples/bookstore
    // and the F3-regression fixture case already established.
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"SelectOption2\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    for (snap[0..n]) |slot| {
        if (slot.id == tid) try std.testing.expectEqualStrings("Option 2", slot.widget.button.label());
        // The panel and its options must be gone entirely, not just
        // hidden -- natyv has no "visible" concept, only exists/doesn't.
        try std.testing.expect(slot.id != pid);
    }
}

test "W5: a modal round-trips modal/background into ClayStyle/Container, centers via a real Clay layout pass, and a real dismiss event destroys it through a real guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    // Unlike the W4 dropdown test above (which never actually runs a real
    // Clay layout pass, so its "positioned below the trigger" comparison
    // holds only because both rects stay at their zeroed insert-time
    // default), this test runs a real layoutIfNeeded pass -- required to
    // prove "centered in the window" as anything more than a trivial
    // {0,0}-equals-{0,0} coincidence. 900x700 matches main.zig's real
    // default window size.
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);

    // natyv_init's baseline is now 31 (see the L3 test's comment above),
    // plus this test opens the modal (panel + message + close button = 3
    // more) -- 34 at peak, comfortably under this buffer's 50. Same
    // silent-truncation risk documented at every prior buffer bump in
    // this file (this exact class of bug is what W16's own dropdown test
    // caught when its buffer went stale -- see that test's comment).
    var snap: [50]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Open Modal")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingTrigger;
    // Not yet open -- natyv_init only ever creates the trigger itself,
    // same "closed by default" state W4's dropdown test already proved.
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != tid);
    }

    // Real guest-routed open (natyv_clay_create_container with modal:true,
    // background:true, via natyv_dispatch -- openModal).
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"OpenModal\"}") orelse return error.CallFailed;
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    var panel_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.widget == .container and slot.clay_style.modal) {
            // W5 wire round-trip: modal and background both landed for
            // real, not just modal (Container.background gates the visible
            // panel fill/border -- see Container.zig).
            try std.testing.expect(slot.widget.container.background);
            panel_id = slot.id;
            panel_rect = slot.widget.container.rect;
        }
    }
    const pid = panel_id orelse return error.MissingPanel;

    var child_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid) child_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), child_count); // message Label + close Button

    // Real Clay layout pass already ran above -- the modal's real computed
    // rect must be centered in the whole window (CLAY_ATTACH_TO_ROOT +
    // CENTER_CENTER/CENTER_CENTER, see ClayLayout.zig's openChildren), not
    // positioned below its trigger the way Dropdown's floating panel is,
    // and not left at {0,0} the way it would be if modal positioning
    // silently didn't apply.
    try std.testing.expectApproxEqAbs(@as(f32, (900 - 240) / 2), panel_rect.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, (700 - 120) / 2), panel_rect.y, 0.5);

    // Real guest-routed dismiss (a real `.dismiss` event targeting the
    // modal's own widget id, exactly as main.zig fires on Escape or a
    // backdrop click -- not a hand-built event type like OpenModal above)
    // -- proving the built-in close affordance half of "built-in + custom
    // close" reaches the guest and that closeModal (the guest's own
    // choice) is what actually destroys the subtree, not the host forcing
    // it.
    var dismiss_buf: [64]u8 = undefined;
    const dismiss_payload = try std.fmt.bufPrint(&dismiss_buf, "{{\"widget_id\":{d},\"event_type\":\"dismiss\"}}", .{pid});
    _ = runtime.call(io, "natyv_dispatch", dismiss_payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    for (snap[0..n]) |slot| {
        // The panel and its children must be gone entirely, not just
        // hidden -- natyv has no "visible" concept, only exists/doesn't.
        try std.testing.expect(slot.id != pid);
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != pid);
    }
}

/// W6: builds a real dispatch envelope the same shape `Dispatch.zig`'s
/// `buildDispatchPayload` produces on the host side -- `payload_json` is
/// embedded as a properly escaped JSON *string* (via `json_util.writeString`,
/// the same helper `Dispatch.zig` itself uses), not a raw nested object,
/// matching the real wire contract `event.Payload` on the guest side
/// expects to `json.Unmarshal` a second time.
fn buildDispatchEnvelope(buf: []u8, widget_id: u32, event_type: []const u8, payload_json: []const u8) ![]u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const a = fba.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{{\"widget_id\":{d},\"event_type\":\"{s}\",\"payload\":", .{ widget_id, event_type });
    try json_util.writeString(&out, a, payload_json);
    try out.append(a, '}');
    return out.items;
}

test "W6: a combobox's .text_changed re-filters, .key_nav moves the highlight and selects, through a real guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // natyv_init's baseline is now 31 (see the L3 test's comment above),
    // plus this test opens the combobox's panel (up to 5 filtered options
    // + the panel itself = 6 more) -- 37 at peak, comfortably under this
    // buffer's 50. Same silent-truncation risk documented at every prior
    // buffer bump in this file.
    var snap: [50]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var field_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        // Exactly one TextField exists in this fixture -- see natyv_init's
        // own doc comments -- so matching by kind alone is unambiguous
        // here, unlike the label-based matches W4/W5's tests need for
        // Button (this fixture has several of those).
        if (slot.widget == .textfield) field_id = slot.id;
    }
    const fid = field_id orelse return error.MissingComboField;
    // Not yet open -- natyv_init only ever creates the TextField itself.
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != fid);
    }

    // Real guest-routed filter (natyv_clay_create_container/_button via
    // natyv_dispatch's "text_changed" case -- renderComboOptions). "an"
    // matches only "Banana" among the fixture's 5-item option list.
    var dispatch_buf: [256]u8 = undefined;
    var payload = try buildDispatchEnvelope(&dispatch_buf, fid, "text_changed", "{\"text\":\"an\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == fid and slot.widget == .container) panel_id = slot.id;
    }
    const pid = panel_id orelse return error.MissingComboPanel;

    var option_id: ?u32 = null;
    var option_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button) {
            option_count += 1;
            option_id = slot.id;
            // W6 wire round-trip: no highlight marker yet -- text_changed
            // resets comboHighlighted to -1 before re-rendering.
            try std.testing.expectEqualStrings("Banana", slot.widget.button.label());
        }
    }
    try std.testing.expectEqual(@as(usize, 1), option_count);
    const oid = option_id orelse return error.MissingComboOption;

    // Real guest-routed highlight move (natyv_set_text on the option via
    // natyv_dispatch's "key_nav" -> "down" case, since destroy/recreate is
    // how this fixture rebuilds the panel on every highlight move too).
    payload = try buildDispatchEnvelope(&dispatch_buf, fid, "key_nav", "{\"key\":\"down\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button) {
            try std.testing.expectEqualStrings("\xe2\x96\xb8 Banana", slot.widget.button.label());
        }
    }
    // Destroyed and recreated (not just relabeled) on the highlight move,
    // same "destroy old widgets, create new ones" pattern as everything
    // else in this project -- the option's own id is not stable across it.
    _ = oid;

    // Real guest-routed select-and-close (natyv_set_text on the TextField
    // + natyv_destroy_widget on the panel/option, via natyv_dispatch's
    // "key_nav" -> "enter" case).
    payload = try buildDispatchEnvelope(&dispatch_buf, fid, "key_nav", "{\"key\":\"enter\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    for (snap[0..n]) |slot| {
        if (slot.id == fid) try std.testing.expectEqualStrings("Banana", slot.widget.textfield.text());
        // The panel and its option must be gone entirely, not just
        // hidden -- natyv has no "visible" concept, only exists/doesn't.
        try std.testing.expect(slot.id != pid);
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != fid);
    }
}

test "W6: a real .blur event closes the combobox panel without selecting anything" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // natyv_init's baseline is now 31 (see the L3 test's comment above),
    // plus this test opens the combobox's panel with up to 5 filtered
    // options -- comfortably under this buffer's 50.
    var snap: [50]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var field_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .textfield) field_id = slot.id;
    }
    const fid = field_id orelse return error.MissingComboField;

    var dispatch_buf: [256]u8 = undefined;
    // "e" matches Cherry/Date/Elderberry -- several options, doesn't matter
    // which for this test, only that the panel is genuinely open first.
    var payload = try buildDispatchEnvelope(&dispatch_buf, fid, "text_changed", "{\"text\":\"e\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == fid and slot.widget == .container) panel_id = slot.id;
    }
    const pid = panel_id orelse return error.MissingComboPanel;

    // Real guest-routed blur -- fired by main.zig's updateFocus to
    // whatever widget just lost focus, on any focus change away from it
    // (see updateFocus's W6 doc comment); synthesized here directly since
    // this test only needs to prove the guest's own "e"vent -> close"
    // wiring, not a real mouse click moving focus elsewhere.
    payload = try buildDispatchEnvelope(&dispatch_buf, fid, "blur", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    for (snap[0..n]) |slot| {
        // No selection happened -- the TextField's own text is still
        // whatever it started as (empty, natyv_init never sets one).
        if (slot.id == fid) try std.testing.expectEqualStrings("", slot.widget.textfield.text());
        try std.testing.expect(slot.id != pid);
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != fid);
    }
}

test "W7: a toast round-trips duration_ms into a real expires_at_ms, and destroyExpiredWidgets cascades to its content, through a real guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // natyv_init's baseline is now 31 (see the L3 test's comment above),
    // plus this test fires one toast (its own Container + a message Label
    // = 2 more) -- 33 at peak, comfortably under this buffer's 50. Same
    // silent-truncation risk documented at every prior buffer bump in
    // this file.
    var snap: [50]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var stack_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        // The persistent toast-stack container is the only widget with
        // clay_style.toast set -- exactly one exists, created once in
        // natyv_init, unambiguous to match on the flag alone.
        if (slot.widget == .container and slot.clay_style.toast) stack_id = slot.id;
    }
    const sid = stack_id orelse return error.MissingToastStack;
    // No toast has been shown yet -- natyv_init only ever creates the
    // stack itself.
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != sid);
    }

    // Real guest-routed toast creation (natyv_clay_create_container with
    // duration_ms:2000, via natyv_dispatch's "ShowToast" case -- showToast).
    const before_ms = timing.nowMs();
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"ShowToast\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var toast_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == sid and slot.widget == .container) {
            // W7 wire round-trip: duration_ms landed as a real
            // expires_at_ms, roughly 2000ms after this call started --
            // and the toast's own Container is NOT itself toast-flagged
            // (only the stack is; individual toasts are plain children).
            try std.testing.expect(!slot.clay_style.toast);
            const exp = slot.expires_at_ms orelse return error.MissingExpiry;
            try std.testing.expect(exp >= before_ms + 1900 and exp <= before_ms + 2100);
            toast_id = slot.id;
        }
    }
    const tid = toast_id orelse return error.MissingToast;

    var message_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .label) message_id = slot.id;
    }
    const mid = message_id orelse return error.MissingToastMessage;

    // Real host-driven expiry -- a fabricated far-future timestamp instead
    // of a real sleep, same deterministic-over-real-waiting preference
    // this project's W2 scroll tests already established. No guest
    // dispatch involved at all here: destroyExpiredWidgets is main.zig's
    // own per-frame call, never guest-triggered.
    runtime.widgets.destroyExpiredWidgets(io, before_ms + 10_000);
    n = runtime.widgets.snapshot(io, &snap);

    var found_toast = false;
    var found_message = false;
    var found_stack = false;
    for (snap[0..n]) |slot| {
        if (slot.id == tid) found_toast = true;
        if (slot.id == mid) found_message = true;
        if (slot.id == sid) found_stack = true;
    }
    // The toast and its message must both be gone -- cascading delete,
    // not just the root -- while the never-expiring stack itself (and
    // everything else natyv_init created) survives untouched.
    try std.testing.expect(!found_toast);
    try std.testing.expect(!found_message);
    try std.testing.expect(found_stack);
}

test "W9: a menu's nested submenu positions correctly, each level's key_nav is independently scoped, and selecting a submenu item closes both levels" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    // Real layout pass, same reasoning W5's own test documents: proving
    // "positions correctly" as anything more than a trivial {0,0}-equals-
    // {0,0} coincidence needs a real Clay recompute, not just a snapshot.
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);

    // natyv_init's baseline is now 45 (see the L3 test's comment above),
    // plus this test opens the top-level menu (panel + 3 items = 4 more)
    // and the submenu (panel + 2 items = 3 more) -- 52 at peak, which
    // silently overflowed the old 50-slot buffer (W19's +7 widget bump).
    // Bumped to 60 for headroom. Same silent-truncation risk documented at
    // every prior buffer bump in this file.
    var snap: [60]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Menu")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingMenuTrigger;

    // Real guest-routed open (natyv_clay_create_container with
    // floating:true, via natyv_dispatch -- openMenu).
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"OpenMenu\"}") orelse return error.CallFailed;
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    var more_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) panel_id = slot.id;
    }
    const pid = panel_id orelse return error.MissingMenuPanel;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "More \xe2\x96\xb8")) more_id = slot.id;
    }
    var mid = more_id orelse return error.MissingMoreItem;

    // W9 follow-up regression test: pressing Enter while "More ▸" is
    // highlighted must open the submenu -- Enter never produces a
    // separate `.key_nav` "enter" event for a focused Button (that stays
    // gated to `.textfield` only), it always produces this same `.click`
    // on the focused widget (main.zig's SDLK_RETURN handling), so
    // synthesizing that `.click` on the trigger is exactly what a real
    // Enter keypress sends. Caught via Quinn's real click-through: the
    // previous version ignored menuHighlighted and just toggled the whole
    // menu closed instead of opening the submenu. "More ▸" is the 2nd
    // top-level item (index 1), so two "down" presses reach it
    // (-1 -> 0 -> 1).
    var dispatch_buf: [256]u8 = undefined;
    var payload: []u8 = undefined;
    for (0..2) |_| {
        payload = try buildDispatchEnvelope(&dispatch_buf, tid, "key_nav", "{\"key\":\"down\"}");
        _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    }
    // Each "down" press re-renders (destroys/recreates, same as
    // Combobox's own highlight moves) *every* top-level item, including
    // "More ▸" itself -- its widget id captured above is stale by now, so
    // it must be looked up fresh before this test can reference it again.
    // A fresh layoutIfNeeded pass is required too: the recreated widgets
    // don't get a real Clay-computed rect until layout runs again, so
    // reading rect before this would capture a stale/default (0,0) rect
    // rather than "More ▸"'s actual on-screen position.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "\xe2\x96\xb8 More \xe2\x96\xb8")) mid = slot.id;
    }
    const more_rect = for (snap[0..n]) |slot| {
        if (slot.id == mid) break slot.widget.button.rect;
    } else return error.MissingMoreItem;

    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var submenu_opened_via_enter = false;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == mid and slot.widget == .container) submenu_opened_via_enter = true;
    }
    try std.testing.expect(submenu_opened_via_enter);

    // Close *just* the submenu back down (a real click on "More ▸" itself
    // -- submenuHighlighted is -1 right after opening, so this hits the
    // click handler's `default: closeSubmenu()` branch) -- the top-level
    // panel (pid) and "More ▸" (mid) stay intact, so the rest of this
    // test can continue via the ordinary real-mouse-click flow below,
    // completely unaffected by this regression check.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{mid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;

    // Real guest-routed submenu open -- a real click on "More ▸" (not a
    // hand-built shortcut), proving the click actually routes to the
    // right widget, not just that openSubmenu itself works.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{mid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    n = runtime.widgets.snapshot(io, &snap);

    var submenu_panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == mid and slot.widget == .container) submenu_panel_id = slot.id;
    }
    const spid = submenu_panel_id orelse return error.MissingSubmenuPanel;

    var sub_item_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == spid and slot.widget == .button) sub_item_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), sub_item_count);

    // Both levels exist simultaneously (real cascading behavior, not
    // replace-in-place) with real, distinct Clay-computed positions --
    // the actual proof nesting positions correctly, not just "doesn't
    // crash." The submenu is parented to (and thus, per its floating
    // attach config, positioned below) the "More ▸" item specifically,
    // not the top-level trigger.
    for (snap[0..n]) |slot| {
        if (slot.id == spid) {
            try std.testing.expectApproxEqAbs(more_rect.x, slot.widget.container.rect.x, 0.5);
            try std.testing.expectApproxEqAbs(more_rect.y + more_rect.h, slot.widget.container.rect.y, 0.5);
        }
    }

    // W9 regression test: a real mouse click on "More ▸" (as sent above)
    // also moves focus onto it, which fires a genuine `.blur` on the
    // previously-focused top-level trigger in the very same frame --
    // `natyv_dispatch` calls in this test only ever send the one event
    // asked for, so this synthesizes the accompanying `.blur` a real
    // click through main.zig's actual event loop would also send (see
    // updateFocus), the same shape `.click` itself already has here.
    // Caught via Quinn's real click-through: without checking where focus
    // actually went, this blur used to destroy the submenu the same
    // frame it opened.
    var blur_payload_buf: [64]u8 = undefined;
    const blur_payload = try std.fmt.bufPrint(&blur_payload_buf, "{{\"new_focus_id\":{d}}}", .{mid});
    payload = try buildDispatchEnvelope(&dispatch_buf, tid, "blur", blur_payload);
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var submenu_survived_blur = false;
    for (snap[0..n]) |slot| {
        if (slot.id == spid) submenu_survived_blur = true;
    }
    try std.testing.expect(submenu_survived_blur);

    // Real guest-routed highlight move, scoped to the submenu specifically
    // (natyv_dispatch's "key_nav" case targeting moreItemID, not
    // menuTriggerID) -- proving per-level scoping actually works, not
    // accidentally cycling the top-level items instead.
    payload = try buildDispatchEnvelope(&dispatch_buf, mid, "key_nav", "{\"key\":\"down\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var other_top_level_marker_found = false;
    var more_still_marked = false;
    var submenu_marker_found = false;
    for (snap[0..n]) |slot| {
        if (slot.widget != .button) continue;
        if (slot.parent_id != null and slot.parent_id.? == pid and std.mem.indexOf(u8, slot.widget.button.label(), "\xe2\x96\xb8 ") != null) {
            if (slot.id == mid) more_still_marked = true else other_top_level_marker_found = true;
        }
        if (slot.parent_id != null and slot.parent_id.? == spid and std.mem.eql(u8, slot.widget.button.label(), "\xe2\x96\xb8 Sub A")) submenu_marker_found = true;
    }
    // Only the submenu's own highlight moved -- the top level's own
    // highlight (still on "More ▸", from before its submenu was even
    // opened) is untouched: neither cleared nor moved to a different
    // top-level item.
    try std.testing.expect(submenu_marker_found);
    try std.testing.expect(more_still_marked);
    try std.testing.expect(!other_top_level_marker_found);

    // Real guest-routed select-and-close-everything (natyv_set_text on
    // the trigger + natyv_destroy_widget on every widget at both levels,
    // via natyv_dispatch -- selectSubmenuItem/closeMenu). The submenu's
    // "Sub A" button was just destroyed/recreated by the key_nav-driven
    // re-render above (same as Combobox), so its widget id must be looked
    // up fresh from the latest snapshot rather than an id captured
    // earlier in this test.
    var live_sub_a_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == spid and slot.widget == .button and std.mem.indexOf(u8, slot.widget.button.label(), "Sub A") != null) live_sub_a_id = slot.id;
    }
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{live_sub_a_id orelse return error.MissingLiveSubA});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    // Compared inline, not stored for after the loop -- `slot` is a
    // per-iteration copy, and a slice from `slot.widget.button.label()`
    // (into that copy's own `label_buf` field) would dangle once the loop
    // moves past this iteration, same lesson every other test in this
    // file's "set a bool inside the loop, check the bool after" pattern
    // already avoids.
    var trigger_relabeled = false;
    var any_menu_widgets_remain = false;
    for (snap[0..n]) |slot| {
        if (slot.id == tid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Menu: Sub A")) trigger_relabeled = true;
        if (slot.id == pid or slot.id == spid) any_menu_widgets_remain = true;
        if (slot.parent_id) |parent| {
            if (parent == pid or parent == spid) any_menu_widgets_remain = true;
        }
    }
    try std.testing.expect(trigger_relabeled);
    // Both levels fully gone -- closeMenu() always closes the entire
    // cascade, not just the innermost one.
    try std.testing.expect(!any_menu_widgets_remain);

    // W9 follow-up regression test: with the submenu opened via Enter
    // (a synthesized `.click` on the still-focused trigger, same as the
    // "submenu_opened_via_enter" check above), pressing "down" must move
    // the *submenu's* highlight -- not the top-level's. Real bug caught
    // via Quinn's click-through: key_nav kept landing on tid (focus never
    // moves to moreItemID unless a real mouse click -- not Enter's
    // synthesized one -- hits it via main.zig's hit-test-driven
    // updateFocus), so arrow keys cycled the top-level highlight instead,
    // which is invisible behind the now-open submenu and looked like
    // arrow keys "did nothing." Self-contained: opens a fresh menu from
    // scratch (everything above was just fully torn down) rather than
    // reusing any state from earlier in this test.
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"OpenMenu\"}") orelse return error.CallFailed;
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    n = runtime.widgets.snapshot(io, &snap);
    var reopened_pid: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) reopened_pid = slot.id;
    }
    const rpid = reopened_pid orelse return error.MissingMenuPanel;

    for (0..2) |_| {
        payload = try buildDispatchEnvelope(&dispatch_buf, tid, "key_nav", "{\"key\":\"down\"}");
        _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    }
    n = runtime.widgets.snapshot(io, &snap);
    var reopened_mid: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == rpid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "\xe2\x96\xb8 More \xe2\x96\xb8")) reopened_mid = slot.id;
    }
    const rmid = reopened_mid orelse return error.MissingMoreItem;

    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    var reopened_spid: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == rmid and slot.widget == .container) reopened_spid = slot.id;
    }
    const rspid = reopened_spid orelse return error.MissingSubmenuPanel;

    payload = try buildDispatchEnvelope(&dispatch_buf, tid, "key_nav", "{\"key\":\"down\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var submenu_marker_found_after_enter_open = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and slot.parent_id != null and slot.parent_id.? == rspid and std.mem.eql(u8, slot.widget.button.label(), "\xe2\x96\xb8 Sub A")) submenu_marker_found_after_enter_open = true;
    }
    try std.testing.expect(submenu_marker_found_after_enter_open);

    // W9 follow-up regression test: pressing Enter (a synthesized `.click`
    // on tid, still the focused widget -- the submenu opened via Enter, so
    // focus never left the trigger) while a submenu item is highlighted
    // must select it. Real bug caught via Quinn's click-through: without
    // checking submenuPanelID first, this click kept re-matching
    // `menuHighlighted == moreItemIndex` (still true -- opening the
    // submenu never resets the top-level highlight) and silently
    // re-opened the (already-open) submenu instead of ever reaching
    // selectSubmenuItem, making Enter look like it did nothing.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var trigger_relabeled_via_submenu_enter = false;
    var menu_widgets_remain_after_submenu_enter = false;
    for (snap[0..n]) |slot| {
        if (slot.id == tid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Menu: Sub A")) trigger_relabeled_via_submenu_enter = true;
        if (slot.id == rpid or slot.id == rspid) menu_widgets_remain_after_submenu_enter = true;
        if (slot.parent_id) |parent| {
            if (parent == rpid or parent == rspid) menu_widgets_remain_after_submenu_enter = true;
        }
    }
    try std.testing.expect(trigger_relabeled_via_submenu_enter);
    try std.testing.expect(!menu_widgets_remain_after_submenu_enter);

    // W9 follow-up regression test: the same "Enter selects the
    // highlighted item" path, but for a plain top-level item (never
    // touching the submenu at all) -- covers Quinn's other click-through
    // report ("hitting enter on a top level selection ... doesn't select
    // it"), and guards against a regression from the submenuPanelID
    // branch just added above (it must never fire when the submenu was
    // never opened). Self-contained: opens a fresh menu from scratch.
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"OpenMenu\"}") orelse return error.CallFailed;
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);

    payload = try buildDispatchEnvelope(&dispatch_buf, tid, "key_nav", "{\"key\":\"down\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    var final_pid: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) final_pid = slot.id;
    }
    const fpid = final_pid orelse return error.MissingMenuPanel;

    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var trigger_relabeled_via_top_level_enter = false;
    var menu_widgets_remain_after_top_level_enter = false;
    for (snap[0..n]) |slot| {
        if (slot.id == tid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Menu: Open")) trigger_relabeled_via_top_level_enter = true;
        if (slot.id == fpid) menu_widgets_remain_after_top_level_enter = true;
        if (slot.parent_id) |parent| {
            if (parent == fpid) menu_widgets_remain_after_top_level_enter = true;
        }
    }
    try std.testing.expect(trigger_relabeled_via_top_level_enter);
    try std.testing.expect(!menu_widgets_remain_after_top_level_enter);
}

test "W10: a textarea's multi-line content flows through host-level mutation, real guest dispatch, and blur" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // 32: natyv_init's 31 widgets (see the L3 test's comment above) --
    // this test never opens anything else on top, well within headroom.
    var snap: [32]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    // Exactly one TextArea exists in this fixture -- see natyv_init's own
    // doc comments -- so matching by kind alone is unambiguous, same
    // precedent the W6 combobox test's TextField match already
    // established.
    var area_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .textarea) area_id = slot.id;
    }
    const aid = area_id orelse return error.MissingTextArea;

    // Host-level mutation: proves multi-line bytes flow through the
    // widget's own storage/generation-counter correctly, the same way
    // main.zig's real SDL_EVENT_TEXT_INPUT/SDLK_RETURN handling would
    // drive it (a literal "\n" is just another string to append -- see
    // appendTextTo's doc comment).
    var text_buf: [TextArea.max_len]u8 = undefined;
    const written = runtime.widgets.appendTextTo(io, aid, "line one\nline two", &text_buf) orelse return error.AppendFailed;
    try std.testing.expectEqualStrings("line one\nline two", text_buf[0..written]);

    // Real guest-routed reaction: synthesizes the exact `.text_changed`
    // envelope main.zig's notifyTextChanged would build for this content
    // (embedded `\n` included), and confirms the guest's OnChange handler
    // (updating notesCountLabelID's text) actually ran -- not just that
    // the host-side buffer holds the right bytes.
    var dispatch_buf: [256]u8 = undefined;
    const payload = try buildDispatchEnvelope(&dispatch_buf, aid, "text_changed", "{\"text\":\"line one\\nline two\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var count_label_updated = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Notes: 17 chars")) count_label_updated = true;
    }
    try std.testing.expect(count_label_updated);

    // Blur: no TextArea-specific handling exists in the fixture (see
    // notesAreaID's doc comment) -- this confirms a real `.blur` dispatch
    // targeting it completes without error, same generic path every other
    // focusable widget's blur already goes through.
    var blur_dispatch_buf: [256]u8 = undefined;
    const blur_payload = try buildDispatchEnvelope(&blur_dispatch_buf, aid, "blur", "{\"new_focus_id\":0}");
    _ = runtime.call(io, "natyv_dispatch", blur_payload) orelse return error.CallFailed;
}

test "W11: a divider exists, is not focusable, and gets real Clay-computed geometry" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);

    // 32: natyv_init's 31 widgets (see the L3 test's comment above) --
    // this test never opens anything else on top, well within headroom.
    var snap: [32]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);

    // Exactly one Divider exists in this fixture -- see natyv_init's own
    // doc comments -- so matching by kind alone is unambiguous, same
    // precedent the W6/W10 tests' own single-of-a-kind matches already
    // established.
    var divider_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .divider) divider_id = slot.id;
    }
    const did = divider_id orelse return error.MissingDivider;

    for (snap[0..n]) |slot| {
        if (slot.id == did) {
            // Never focusable -- confirms Widget.isFocusable's .divider
            // arm, not just that the widget exists.
            try std.testing.expect(!slot.widget.isFocusable());
            // Horizontal: fixed (thin) height, grow-width -- real
            // Clay-computed geometry, not the zeroed rect it was created
            // with (Clay-managed widgets start zeroed until a real
            // layout pass runs, same precedent every other Clay-managed
            // widget's own test already confirms).
            try std.testing.expectApproxEqAbs(@as(f32, 2), slot.widget.divider.rect.h, 0.01);
            try std.testing.expect(slot.widget.divider.rect.w > 100);
        }
    }
}

test "W12: a toggle exists, is focusable, activates via a real click, and natyv_set_checked/natyv_get_checked round-trip through a real guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // 32: natyv_init's 31 widgets (see the L3 test's comment above) --
    // this test never opens anything else on top, well within headroom.
    var snap: [32]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    // Exactly one Toggle exists in this fixture -- see natyv_init's own
    // doc comments -- so matching by kind alone is unambiguous, same
    // precedent the W6/W10/W11 tests' own single-of-a-kind matches
    // already established.
    var toggle_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .toggle) {
            try std.testing.expectEqualStrings("Dark Mode", slot.widget.toggle.label());
            try std.testing.expect(!slot.widget.toggle.checked);
            try std.testing.expect(slot.widget.isFocusable());
            toggle_id = slot.id;
        }
    }
    const tid = toggle_id orelse return error.MissingToggle;

    // Real guest-routed toggle flip (natyv_set_checked via natyv_dispatch),
    // same shape as W1's CheckIt case.
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"ToggleOn\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == tid) try std.testing.expect(slot.widget.toggle.checked);
    }

    // Host-authoritative click activation -- WidgetHost.toggleToggle itself
    // (not routed through the guest), same precedent WidgetHost.toggleCheckbox
    // already exercises for Checkbox: confirms the click/Enter/Space
    // activation path flips it independent of natyv_set_checked.
    runtime.widgets.toggleToggle(io, tid);
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == tid) try std.testing.expect(!slot.widget.toggle.checked);
    }
}

test "W14: three badges exist with their real tones/labels, are not focusable, and get real Clay-computed geometry" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);

    // 32: natyv_init's 31 widgets (see the L3 test's comment above) --
    // this test never opens anything else on top, well within headroom.
    var snap: [32]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);

    // Exactly one Badge per tone exists in this fixture -- see
    // natyv_init's own doc comments -- so matching by (kind, label) is
    // unambiguous, same precedent the W6/W10/W11/W12 tests' own
    // single-of-a-kind matches already established.
    var success_found = false;
    var warning_found = false;
    var danger_found = false;
    for (snap[0..n]) |slot| {
        if (slot.widget != .badge) continue;
        // Never focusable -- confirms Widget.isFocusable's .badge arm, not
        // just that the widget exists.
        try std.testing.expect(!slot.widget.isFocusable());
        // Real Clay-computed geometry, not the zeroed rect it was created
        // with (Clay-managed widgets start zeroed until a real layout pass
        // runs, same precedent every other Clay-managed widget's own test
        // already confirms).
        try std.testing.expectApproxEqAbs(@as(f32, 80), slot.widget.badge.rect.w, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 22), slot.widget.badge.rect.h, 0.01);

        if (slot.widget.badge.tone == .success and std.mem.eql(u8, slot.widget.badge.label(), "Active")) success_found = true;
        if (slot.widget.badge.tone == .warning and std.mem.eql(u8, slot.widget.badge.label(), "Pending")) warning_found = true;
        if (slot.widget.badge.tone == .danger and std.mem.eql(u8, slot.widget.badge.label(), "Expired")) danger_found = true;
    }
    try std.testing.expect(success_found);
    try std.testing.expect(warning_found);
    try std.testing.expect(danger_found);
}

test "W15: a real .hover event creates a floating tooltip through a real guest, and hover-out destroys it, idempotently" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // natyv_init's baseline is now 45 (see the L3 test's comment above),
    // plus this test opens the tooltip (Container + Label = 2 more) -- 47
    // at peak, which silently overflowed the old 40-slot buffer (W19's +7
    // widget bump). Bumped to 55 for headroom. Same silent-truncation risk
    // documented at every prior buffer bump in this file.
    var snap: [55]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var help_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        // Exactly one Button labeled "?" exists in this fixture, unlike
        // every other Button label here -- unambiguous match.
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "?")) help_id = slot.id;
    }
    const hid = help_id orelse return error.MissingHelpButton;
    // Not yet shown -- natyv_init only ever creates the help Button itself.
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != hid);
    }

    // Real guest-routed hover-in (a real `.hover` event with
    // `{"hovering":true}`, exactly as main.zig's hover-hold timer fires it
    // -- not a hand-built event type) -- proves the guest's own choice
    // (the "hover" dispatch case) is what creates the tooltip's
    // Container+Label, not the host doing it on the guest's behalf.
    var dispatch_buf: [256]u8 = undefined;
    var payload = try buildDispatchEnvelope(&dispatch_buf, hid, "hover", "{\"hovering\":true}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == hid and slot.widget == .container) {
            // W15 wire round-trip: floating landed in ClayStyle, same as
            // every other on-demand floating panel in this fixture.
            try std.testing.expect(slot.clay_style.floating);
            panel_id = slot.id;
        }
    }
    const pid = panel_id orelse return error.MissingTooltipPanel;

    var label_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .label) label_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), label_count);

    // Real guest-routed hover-out (`{"hovering":false}`) -- destroys the
    // panel (and its label child cascades with it, same as every other
    // floating-panel teardown in this fixture).
    payload = try buildDispatchEnvelope(&dispatch_buf, hid, "hover", "{\"hovering\":false}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    for (snap[0..n]) |slot| {
        // Gone entirely, not just hidden -- natyv has no "visible" concept,
        // only exists/doesn't (same precedent every other floating-panel
        // teardown test in this file already established).
        try std.testing.expect(slot.id != pid);
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != hid);
    }

    // A second, redundant `{"hovering":false}` -- simulates the coalesced
    // "hover-out arrives with no matching hover-in" edge case EventQueue's
    // own `.hover` doc comment describes. Must be a harmless no-op (the
    // guest's own `tooltipPanelID != 0` guard), not a crash or a spurious
    // destroy-widget error surfacing through natyv_dispatch's response.
    payload = try buildDispatchEnvelope(&dispatch_buf, hid, "hover", "{\"hovering\":false}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != hid);
    }
}

test "W16: a date/time picker's calendar grid matches the real month, and selecting a day closes it with the correct picked value" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // natyv_init's baseline is now 45 (see the L3 test's comment above),
    // plus opening the picker at its fixed default (August 2026) -- a real
    // month, not a hand-picked round number, confirmed independently via
    // `python3 -c "import datetime; print(datetime.date(2026,8,1).weekday())"`
    // (Saturday, weekday 5 in Python's Monday=0 scheme -- 6 in Go's own
    // Sunday=0 `time.Weekday` scheme firstWeekdayOfMonth actually uses)
    // and 31 real days. Peak widget count for the panel: 1 (panel) + 1
    // (header row) + 2 (prev/next) + 1 (month/year label) + 1 (weekday
    // row) + 7 (weekday labels) + 6 (grid rows -- 6 leading blanks + 31
    // days = 37 cells, ceil(37/7)) + 6 (leading blank spacers) + 31 (day
    // buttons) + 1 (time row) + 2 (W17: hour/minute NumericSteppers,
    // replacing the original six-widget Button+Label+Button trio) = 59 --
    // 45 + 59 = 104 at peak, which silently overflowed the old 100-slot
    // buffer (W19's +7 widget bump). Bumped to 115 for headroom.
    var snap: [115]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    var result_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Select date/time...")) trigger_id = slot.id;
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Picked: (none yet)")) result_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingTrigger;
    const rid = result_id orelse return error.MissingResultLabel;
    // Not yet open -- natyv_init only ever creates the trigger itself.
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != tid);
    }
    const baseline = n;

    // Real guest-routed open (a real click on the trigger, via
    // natyv_dispatch -- renderDatePickerPanel).
    var dispatch_buf: [64]u8 = undefined;
    var payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 59), n - baseline);

    // Exactly one Button labeled "15" exists in this fixture (no other
    // widget anywhere in it shares that bare-number label) -- the day-15
    // button, unambiguous to match directly.
    var day15_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "15")) day15_id = slot.id;
    }
    const d15 = day15_id orelse return error.MissingDay15;

    // Real guest-routed selection (a real click on the day-15 button) --
    // proves selectDay commits {year, month, day, hour, minute} into both
    // the trigger's own label and the separate result Label (this is
    // exactly what answers Quinn's "prints out the selected date and
    // time" ask), and closes the whole panel in one step, same precedent
    // Dropdown's option click already established.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{d15});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    try std.testing.expectEqual(baseline, n);
    for (snap[0..n]) |slot| {
        if (slot.id == tid) try std.testing.expectEqualStrings("2026-08-15 12:00", slot.widget.button.label());
        if (slot.id == rid) try std.testing.expectEqualStrings("Picked: 2026-08-15 12:00", slot.widget.label.text());
        // The panel and every one of its descendants must be gone
        // entirely, not just hidden -- natyv has no "visible" concept,
        // only exists/doesn't (same precedent every other floating-panel
        // teardown test in this file already established).
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != tid);
    }
}

test "W16: month navigation regenerates the grid for the real target month, and a time-stepper click adjusts exactly one of hour/minute" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // Bumped from 100 -- same peak-widget-count math as the previous
    // test's own updated comment (W19's +7 widget bump on natyv_init's
    // baseline pushed this picker-open scenario's peak past 100 too).
    var snap: [115]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Select date/time...")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingTrigger;

    // W17: 256, not 64 -- this test now also builds a `.change` envelope
    // via buildDispatchEnvelope (the stepper interaction below), which
    // needs more room than a bare click envelope; same buffer size every
    // other buildDispatchEnvelope-using test in this file already uses.
    var dispatch_buf: [256]u8 = undefined;
    var payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    // Exactly one Button labeled "›" exists while the panel is open --
    // the next-month button.
    var next_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "›")) next_id = slot.id;
    }
    const nid = next_id orelse return error.MissingNextButton;

    // Real guest-routed month navigation (a real click on "›") -- August
    // 2026 -> September 2026. September 1 2026 is a Tuesday (confirmed
    // independently the same way August's was, above) -- 2 leading
    // blanks, 30 real days.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{nid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var header_found = false;
    var day10_id: ?u32 = null;
    var day31_found = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "September 2026")) header_found = true;
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "10")) day10_id = slot.id;
        // September has only 30 days -- a "31" day button must NOT exist
        // in this month's real grid (proves the grid actually
        // regenerated against the new month, not just relabeled the
        // header while leaving August's 31-day grid in place).
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "31")) day31_found = true;
    }
    try std.testing.expect(header_found);
    try std.testing.expect(!day31_found);
    const d10_id = day10_id orelse return error.MissingDay10;

    // W17 follow-up: the hour/minute controls are now real NumericStepper
    // widgets, not Button+Label+Button trios -- there's no "+"-labeled
    // Button to click anymore. Found by `.value` instead of a label: the
    // picker's hour stepper defaults to 12 and this fixture's other
    // NumericStepper (the standalone W17 "Quantity" demo) defaults to 1,
    // so `.value == 12` unambiguously identifies it, with no collision
    // possible against the minute stepper's own default (0) either.
    //
    // A stepper's value change is entirely host-resolved (main.zig's
    // `tryHitWidget`/keyboard handling own the click-zone/arrow-key math,
    // see NumericStepper.zig's file doc comment) -- there's no x/y click
    // simulation available through `natyv_dispatch` the way a Button's
    // `.click` is. Same "guest-routed" test shape every other case in this
    // file already uses (e.g. month nav above): build the exact `.change`
    // envelope main.zig's own `notifyStepperValue` would deliver
    // (`buildDispatchEnvelope`, W6) and let the guest's own dispatch
    // handling (mutating `pickerHour`) do the rest -- this still proves
    // the guest-side half of the mechanism end-to-end, the host-side half
    // (regionAt/keyboard -> resolved value) is covered by RuntimeTest's
    // own pure-host NumericStepper keyboard-adjustment test instead.
    var hour_stepper_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .numeric_stepper and slot.widget.numeric_stepper.value == 12) hour_stepper_id = slot.id;
    }
    const hsid = hour_stepper_id orelse return error.MissingHourStepper;
    payload = try buildDispatchEnvelope(&dispatch_buf, hsid, "change", "{\"value\":13}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    // W17 follow-up: `d10_id` (found above, before the stepper change) is
    // still valid here, unlike the old Button+Label+Button trio's own
    // test, which had to re-find it -- a stepper's value change no longer
    // rebuilds the panel at all (see the dispatch case's own doc comment),
    // so nothing about the grid's widget ids gets invalidated by it.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{d10_id});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    // Indexed directly into `snap` (not through a `for (...) |slot|`
    // by-value copy) so the retained label slice still points into the
    // real, still-alive snapshot array below, not a loop-local copy that
    // goes out of scope at the end of its own iteration.
    var trigger_index: ?usize = null;
    for (0..n) |i| {
        if (snap[i].id == tid) trigger_index = i;
    }
    const ti = trigger_index orelse return error.MissingTrigger;
    try std.testing.expectEqualStrings("2026-09-10 13:00", snap[ti].widget.button.label());
}

test "W18: a popover opens with real content, its own Checkbox toggles, its own Close button closes it, and click-away also closes it" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    // W19 follow-up: bumped from 48 -- natyv_init now creates 45 widgets on
    // its own (see the L3 test's own updated count/comment), and this test
    // opens the popover on top of that (+4), which silently overflowed a
    // 48-slot buffer before this bump (same "snapshot() caps at out.len
    // with no error" risk that comment documents).
    var snap: [56]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Show Popover")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingTrigger;
    // Not yet open -- natyv_init only ever creates the trigger itself.
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.parent_id == null or slot.parent_id.? != tid);
    }
    const baseline = n;

    // Real guest-routed open (a real click on the trigger, via
    // natyv_dispatch -- openPopover).
    var dispatch_buf: [256]u8 = undefined;
    var payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    // panel + label + checkbox + close button = 4 new widgets.
    try std.testing.expectEqual(@as(usize, 4), n - baseline);

    var checkbox_id: ?u32 = null;
    var close_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .checkbox and std.mem.eql(u8, slot.widget.checkbox.label(), "Don't show this again")) checkbox_id = slot.id;
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Close")) close_id = slot.id;
    }
    const cbid = checkbox_id orelse return error.MissingCheckbox;
    const clid = close_id orelse return error.MissingCloseButton;

    // Host-authoritative click activation -- WidgetHost.toggleCheckbox
    // itself (not routed through the guest, same precedent the W12 toggle
    // test already establishes for Toggle) -- confirms the popover's own
    // Checkbox is genuinely interactive, not just static text like a
    // Tooltip's. A real mouse click runs this same function via
    // activateWidget before natyv_dispatch's own "click" event is ever
    // pushed to the guest, so calling it directly here is what a real
    // click on this widget actually does, not a bypass of it.
    for (snap[0..n]) |slot| {
        if (slot.id == cbid) try std.testing.expect(!slot.widget.checkbox.checked);
    }
    runtime.widgets.toggleCheckbox(io, cbid);
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == cbid) try std.testing.expect(slot.widget.checkbox.checked);
    }

    // A real click on the popover's own Close button closes it.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{clid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(baseline, n);

    // Reopen, then close via click-away instead -- a real `.blur` event
    // naming some widget id that isn't part of the popover (the "Grow
    // Button" from W1, unambiguous elsewhere in this fixture), the same
    // shape main.zig's updateFocus fires on a real click outside.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 4), n - baseline);

    var grow_button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Grow Button")) grow_button_id = slot.id;
    }
    const gbid = grow_button_id orelse return error.MissingGrowButton;
    payload = try buildDispatchEnvelope(&dispatch_buf, gbid, "blur", "{\"new_focus_id\":0}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(baseline, n);
}

test "W19: WidgetHost.setActiveTab clamps an out-of-range index and flips panel visible flags" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    const tabs_id = runtime.widgets.insertWithLayout(io, .{ .tabs = Tabs.init(.{ .x = 0, .y = 0, .w = 180, .h = 200 }, &.{ "One", "Two", "Three" }, 0) }, null, .{}) orelse return error.RegistryFull;

    // Register 3 panels the same way createClayTabPanelHostFn does --
    // insert each as a real Clay-managed child of tabs_id, then append its
    // id into the Tabs widget's own panel_ids/panel_count directly. There's
    // no host-function-level entrypoint reachable without a compiled guest,
    // same reasoning the W17 setSegmentedIndex test above uses
    // insertWithLayout directly instead of a round trip through
    // natyv_clay_create_*.
    var panel_ids: [3]u32 = undefined;
    for (0..3) |i| {
        panel_ids[i] = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, tabs_id, .{
            .sizing = .{ .width = fixedAxis(180), .height = fixedAxis(40) },
            .visible = (i == 0),
        }) orelse return error.RegistryFull;
    }
    runtime.widgets.mutex.lockUncancelable(io);
    if (runtime.widgets.findLocked(tabs_id)) |slot| {
        for (0..3) |i| slot.widget.tabs.panel_ids[i] = panel_ids[i];
        slot.widget.tabs.panel_count = 3;
    }
    runtime.widgets.mutex.unlock(io);

    // Out of range for a 3-tab control (index 3) clamps to the last index
    // (2), same shape as setSegmentedIndex's own clamp test.
    const resolved = runtime.widgets.setActiveTab(io, tabs_id, 3) orelse return error.ValueUnchanged;
    try std.testing.expectEqual(@as(usize, 2), resolved);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        for (0..3) |i| {
            if (slot.id == panel_ids[i]) try std.testing.expectEqual(i == 2, slot.clay_style.visible);
        }
    }

    // Calling again with the already-resolved index reports "no change" --
    // same "return null if unchanged" contract setSegmentedIndex/
    // setSliderValue/setStepperValue all share.
    const unchanged = runtime.widgets.setActiveTab(io, tabs_id, 2);
    try std.testing.expectEqual(@as(?usize, null), unchanged);
}

test "W19: switching a Tabs widget's active tab removes the inactive panel from Clay's layout and resizes the Tabs widget's own fit box" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);

    // Fixed width, fit height -- the Tabs widget's own resolved height
    // should track whichever panel is currently visible, not the sum or
    // max of both. If the invisible panel were still contributing to
    // layout (the exact bug ClayStyle.visible's `openChildren` skip exists
    // to prevent), the fit height would never shrink back down after
    // switching to the taller tab and back.
    const tabs_id = runtime.widgets.insertWithLayout(io, .{ .tabs = Tabs.init(.{ .x = 0, .y = 0, .w = 180, .h = 0 }, &.{ "Short", "Tall" }, 0) }, null, .{
        .sizing = .{ .width = fixedAxis(180), .height = .{ .type = c.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = 1e9 } } } },
    }) orelse return error.RegistryFull;

    const short_panel_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, tabs_id, .{
        .sizing = .{ .width = fixedAxis(180), .height = fixedAxis(30) },
        .visible = true,
    }) orelse return error.RegistryFull;
    const tall_panel_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, tabs_id, .{
        .sizing = .{ .width = fixedAxis(180), .height = fixedAxis(150) },
        .visible = false,
    }) orelse return error.RegistryFull;

    runtime.widgets.mutex.lockUncancelable(io);
    if (runtime.widgets.findLocked(tabs_id)) |slot| {
        slot.widget.tabs.panel_ids[0] = short_panel_id;
        slot.widget.tabs.panel_ids[1] = tall_panel_id;
        slot.widget.tabs.panel_count = 2;
    }
    runtime.widgets.mutex.unlock(io);

    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);

    var snap: [8]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);
    var tabs_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == tabs_id) tabs_rect = slot.widget.tabs.rect;
    }
    // Header (36) + short panel (30) -- the tall panel isn't declared to
    // Clay at all this frame, so it can't inflate the fit height.
    try std.testing.expectApproxEqAbs(@as(f32, Tabs.header_height) + 30, tabs_rect.h, 0.5);

    // Switch to the tall tab -- setActiveTab must bump layout_generation
    // (see ClayStyle.visible's doc comment) for this next layoutIfNeeded
    // call to actually pick up the change rather than reusing the cached
    // pre-switch pass.
    _ = runtime.widgets.setActiveTab(io, tabs_id, 1) orelse return error.ValueUnchanged;
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);

    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == tabs_id) tabs_rect = slot.widget.tabs.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, Tabs.header_height) + 150, tabs_rect.h, 0.5);

    // And back down again -- proves it's not a one-way "grow and stay"
    // artifact; the short panel's own height genuinely isn't padded out by
    // the now-hidden tall one.
    _ = runtime.widgets.setActiveTab(io, tabs_id, 0) orelse return error.ValueUnchanged;
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == tabs_id) tabs_rect = slot.widget.tabs.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, Tabs.header_height) + 30, tabs_rect.h, 0.5);
}

test "W19: natyv_clay_create_tabs/_tab_panel round-trip through a real compiled guest, and switching tabs flips the real panel graph's visible flags" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);

    var snap: [56]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var tabs_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .tabs) tabs_id = slot.id;
    }
    const tid = tabs_id orelse return error.MissingTabs;

    // Panel 0's Container (the "Details panel content" Label's own
    // parent) is initially visible; panel 1's ("History panel content"'s
    // parent) is not. Checked on the panel Container itself, not the
    // Label -- `ClayStyle.visible` isn't propagated down to children, only
    // the panel's own flag is ever set; a hidden panel's child Label keeps
    // its own default `visible == true`, it's just never declared to Clay
    // at all because `openChildren` never recurses into its (invisible)
    // parent in the first place -- see that function's own doc comment.
    var details_panel_id: ?u32 = null;
    var history_panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Details panel content")) details_panel_id = slot.parent_id;
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "History panel content")) history_panel_id = slot.parent_id;
    }
    const dpid = details_panel_id orelse return error.MissingDetailsPanel;
    const hpid = history_panel_id orelse return error.MissingHistoryPanel;
    for (snap[0..n]) |slot| {
        if (slot.id == dpid) try std.testing.expect(slot.clay_style.visible);
        if (slot.id == hpid) try std.testing.expect(!slot.clay_style.visible);
    }

    // Switch to tab index 1 ("History") -- same `WidgetHost.setActiveTab`
    // call `notifyTabsValue` makes from a real header click in main.zig
    // (see the W17 setSegmentedIndex test's own doc comment for why this
    // codebase's tests exercise the host mechanism directly rather than
    // synthesizing pixel coordinates just to re-derive the same index).
    // Unlike Popover, Tabs is host-authoritative with no guest dispatch
    // case to route through -- the guest only ever finds out via `.change`
    // if it registered OnChange, which this static demo doesn't.
    const resolved = runtime.widgets.setActiveTab(io, tid, 1);
    try std.testing.expectEqual(@as(?usize, 1), resolved);
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0);

    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == dpid) try std.testing.expect(!slot.clay_style.visible);
        if (slot.id == hpid) try std.testing.expect(slot.clay_style.visible);
    }
}

test "W19 follow-up: WidgetHost.isEffectivelyVisible checks the full ancestor chain, not just a slot's own flag" {
    // Reproduces the real bug Quinn caught via click-through: a Tabs
    // panel's own `visible` flag correctly flips to false on tab switch,
    // but `ClayStyle.visible` is never propagated down to children -- a
    // hidden panel's Label child keeps its own default `visible == true`.
    // main.zig's draw/hit-test loops must walk the parent chain (this
    // function), not just read a slot's own flag, or a switched-away
    // tab's content stays visually stacked on screen using its last real
    // (now-stale) rect instead of disappearing.
    const grandparent: WidgetHost.Slot = .{ .id = 1, .widget = .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, .parent_id = null, .clay_style = .{ .visible = false } };
    const parent: WidgetHost.Slot = .{ .id = 2, .widget = .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, .parent_id = 1, .clay_style = .{ .visible = true } };
    const child: WidgetHost.Slot = .{ .id = 3, .widget = .{ .label = Label.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, "") }, .parent_id = 2, .clay_style = .{ .visible = true } };
    const slots = [_]WidgetHost.Slot{ grandparent, parent, child };

    // The child's own flag is true, but its grandparent's is false -- the
    // whole chain must be treated as not visible.
    try std.testing.expect(!WidgetHost.isEffectivelyVisible(&slots, child));
    // The parent's own flag is true too, but it's under the same hidden
    // grandparent.
    try std.testing.expect(!WidgetHost.isEffectivelyVisible(&slots, parent));
    // The grandparent's own flag alone already makes it invisible.
    try std.testing.expect(!WidgetHost.isEffectivelyVisible(&slots, grandparent));

    // Flip the grandparent visible again -- every level's own flag is now
    // true, so the whole chain resolves to effectively visible.
    var slots2 = slots;
    slots2[0].clay_style.visible = true;
    try std.testing.expect(WidgetHost.isEffectivelyVisible(&slots2, slots2[2]));
}
