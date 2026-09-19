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
const ScrollBar = @import("ScrollBar.zig");
const Font = @import("capabilities/Font.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");
const FloatingOrder = @import("FloatingOrder.zig");

test "bookstore example: guest-declared UI end to end through natyv_init + natyv_dispatch" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/bookstore/guest/bookstore.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, ":memory:");
    defer runtime.deinit();
    // L5: bookstore is now laid out entirely via sdk/go/widgets, so its
    // guest only imports natyv_clay_* (never natyv_create_button/etc) --
    // needs clay_enabled=true or plugin creation itself fails with an
    // "unknown import" error before natyv_init ever runs.
    try runtime.loadPlugin(wasm, .{}, true);
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
            .checkbox, .toggle, .radio_button, .progress_bar, .slider, .range_slider, .textarea, .divider, .badge, .numeric_stepper, .segmented_control, .tabs, .spinner => {},
        }
    }

    var text_scratch: [128]u8 = undefined;
    _ = runtime.widgets.insertTextAt(io, author_id orelse return error.MissingAuthorField, "Frank Herbert", &text_scratch);
    _ = runtime.widgets.insertTextAt(io, title_id orelse return error.MissingTitleField, "Dune", &text_scratch);
    _ = runtime.widgets.insertTextAt(io, genre_id orelse return error.MissingGenreField, "Sci-Fi", &text_scratch);

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
    try runtime.loadPlugin(wasm, .{}, true);
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
    _ = runtime.widgets.insertTextAt(io, author_id orelse return error.MissingAuthorField, "Ursula K. Le Guin", &text_scratch);
    _ = runtime.widgets.insertTextAt(io, title_id orelse return error.MissingTitleField, "The Dispossessed", &text_scratch);
    _ = runtime.widgets.insertTextAt(io, genre_id orelse return error.MissingGenreField, "Sci-Fi", &text_scratch);

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
    try runtime.loadPlugin(wasm, .{}, true);
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
    try runtime.loadPlugin(wasm, .{}, false);
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
    try runtime.loadPlugin(wasm, .{}, true);
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
    // Tabs widget, its 3 panels, and each panel's own Label (7 more) + the
    // Accordion demo's 2 sections, each a header Button + content Container
    // + content Label (6 more) + the Tree demo's own fixed widget pool --
    // viewport + top/bottom spacers + a fixed-size row pool (created once
    // and never destroyed/recreated, see tree.go's own doc comment) sized
    // to however many rows fit its fixed 120px viewport at 28px/row (9
    // more) + the Table demo's own fixed widget pool -- wrapper + header
    // row + 3 header buttons + body viewport + top/bottom spacers + a
    // fixed-size row pool (same permanent-pool technique as Tree, see
    // table.go's own doc comment) sized to however many rows fit its fixed
    // 118px body at 24px/row, each pool row a Button + 3 child Label cells
    // (~32 more) -- not hand-derived exactly here since pool sizes depend
    // on int-truncated division, not worth re-deriving by hand when the
    // real snapshot is authoritative -- + the File picker demo's own row
    // Container + 2 trigger Buttons ("Choose File"/"Save As") + status
    // Label (4 more, no dynamic/on-demand widgets at all -- a native OS
    // dialog isn't a natyv widget, see filedialog.go's own doc comment) --
    // 98 widgets total (the dropdown's floating panel, the modal's panel,
    // the combobox's options panel, the menu's panel/submenu, the W15
    // tooltip panel/label, the W16 picker's own panel/grid/steppers, and
    // the W18 popover's own panel/label/checkbox/close-button are all only
    // created on demand, not by natyv_init -- see the W4/W5/W6/W7/W9/W15/
    // W16/W18 tests below; the toast stack itself IS created here, unlike
    // those, but individual toasts inside it aren't -- the W19 Tabs
    // widget and its 3 panels/labels, the Accordion demo's 2 header/
    // content/label triples, and the Tree/Table demos' own full widget
    // pools ARE all created here too, unlike Popover, since none of them
    // have any open/close state, see tabsID's/accordionHeaderIDs'/tree's/
    // table's own doc comments in the fixture guest). Same
    // silent-truncation risk documented at W1's identical bump from 4 to
    // 8 -- snapshot() caps at out.len with no error, so every
    // clay-fixture-loading test's buffer needs auditing whenever
    // natyv_init grows, not just the test being extended.
    // (W22: this baseline's own growth pushed the W16 calendar-grid test's
    // peak widget count genuinely past the old max_widgets=128 cap -- see
    // that constant's own doc comment for the real "widget registry full"
    // failure that caught it and the bump to 192.)
    // (W23: +2 more -- the new outerWrapper (Fit-sized LeftToRight root)
    // and rightColumn Containers this section's own layout restructuring
    // added, see main.go's outerWrapper doc comment for why Table moved
    // into its own column.)
    // (W24: net +6 -- the old ad-hoc Menu demo's single trigger (-1) was
    // replaced by the real widgets.Menu/widgets.MenuBar: a standalone
    // Menu trigger + its own mirrored status Label (+2), and MenuBar's own
    // bar Container + 3 top-level triggers (File/Edit/View) + its own
    // mirrored status Label (+5) -- each Menu's own dropdown panel/items
    // are still only created on demand, same as every other floating
    // widget's baseline exclusion noted above, not part of this count.)
    // (W25: net +0 -- Dropdown/Popover productization, pure extraction, same
    // wire-level widget counts as the fixture's own old hand-wired demos.)
    // (W27: +2 -- a RangeSlider trigger + its own mirrored status Label
    // (priceRangeStatus), placed below Table -- see priceRange's own doc
    // comment in main.go.)
    // (W28: +9 -- Card & Panel, pure guest composition (see card.go/
    // panel.go's own doc comments, no new WidgetKind). Card: panel + title
    // Label + Divider + content Container (4) + the content area's own
    // description Label + cardButton + cardStatus Label (3) = 7. Panel:
    // panel Container + its own description Label = 2. 7 + 2 = 9.)
    // (W29: +1 -- the Spinner itself, a real new WidgetKind but a single
    // widget with no children/status label of its own -- see spinner's own
    // doc comment in main.go.)
    // (Multi-window Stage 5: +1 -- the "Open New Window" trigger only; the
    // second window and its own content are created on demand by a real
    // click, same as the modal trigger's own baseline exclusion -- see
    // openSecondWindow's own doc comment in main.go.)
    // (Styling system Stage 2: +4 -- styleDemoPanel Container + its own
    // title Label + styleApplyButton + styleStatus Label, real end-to-end
    // proof that a resolved stylesheet token can change a widget's
    // rendering at runtime -- see styleDemoPanel's own doc comment in
    // main.go.)
    // (Texture-fill styling system: +1 -- the heroImage Container, real
    // end-to-end proof of drawRoundedRectTexture through a real guest --
    // see heroImage's own doc comment in main.go.)
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 124), n);

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

    // W23: cid itself is no longer top-level -- the fixture's right-column
    // layout change wrapped it (and Table's own new column) in a new
    // LeftToRight root container, so derive *that* one instead (cid's own
    // parent) to confirm the true root, rather than asserting cid's parent
    // is null directly.
    var outer_wrapper_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.id == cid) outer_wrapper_id = slot.parent_id;
    }
    const owid = outer_wrapper_id orelse return error.MissingOuterWrapper;
    var outer_wrapper_is_root = false;
    for (snap[0..n]) |slot| {
        if (slot.id == owid and slot.parent_id == null) outer_wrapper_is_root = true;
    }
    try std.testing.expect(outer_wrapper_is_root);

    for (snap[0..n]) |slot| {
        if (slot.id == cid) {
            try std.testing.expectEqual(@as(?u32, owid), slot.parent_id);
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    var clay_layout = try ClayLayout.init(allocator, 300, 100, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    // First frame: nothing computed yet, so this must run Clay for real.
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0, &scroll_scratch, null);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0, &scroll_scratch, null);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    // Mutating a Clay-managed widget's text bumps layout_generation (see
    // WidgetHost.setTextHostFn) -- the next frame must recompute for real.
    // Routed through the guest's own natyv_dispatch export (which calls
    // natyv_set_text on the button internally), not called directly --
    // natyv_set_text is a host function the guest imports, not a guest
    // export the host can call by name.
    var payload_buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{{\"widget_id\":{d},\"event_type\":\"Grown\"}}", .{bid});
    _ = runtime.call(io, "natyv_test_hook", payload) orelse return error.CallFailed;

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0, &scroll_scratch, null);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);
}

fn fixedAxis(v: f32) c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = v, .max = v } } };
}

fn growAxis() c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = 0, .max = std.math.floatMax(f32) } } };
}

test "2026-09-02 real window resizing: a window-size-only change (no content/scroll change) still forces a real recompute, and a Grow widget reflows to the new size" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 300, 100, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    const grow_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = growAxis(), .height = growAxis() },
    }) orelse return error.RegistryFull;

    // First frame at 300x100: must run Clay for real (nothing computed yet).
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0, &scroll_scratch, null);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == grow_id) {
            try std.testing.expectApproxEqAbs(@as(f32, 300), slot.widget.container.rect.w, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 100), slot.widget.container.rect.h, 0.01);
        }
    }

    // Second frame, same 300x100, nothing else changed either -- must skip
    // the real Clay computation entirely (this is the pre-existing L4
    // behavior, confirmed still intact after adding the resize check).
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0, &scroll_scratch, null);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    // Third frame: window resized to 600x400 -- no widget mutation, no
    // scroll, the one and only thing that changed is the window's own
    // size. Before this fix, content_changed/scrolled would both be false
    // here and this call would wrongly skip, leaving the Grow widget
    // frozen at its old 300x100 rect even though the window is now bigger.
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 400, 0, 0, false, 0, 0, &scroll_scratch, null);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);

    const n2 = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n2]) |slot| {
        if (slot.id == grow_id) {
            try std.testing.expectApproxEqAbs(@as(f32, 600), slot.widget.container.rect.w, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 400), slot.widget.container.rect.h, 0.01);
        }
    }
}

test "layoutIfNeeded returns null (not 0) when it skips, distinct from a real recompute with 0 scrolled containers -- main.zig's idle-CPU snapshot-rebuild skip relies on telling these apart" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 300, 100, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    _ = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = growAxis(), .height = growAxis() },
    }) orelse return error.RegistryFull;

    // First call: nothing computed yet -- a real recompute, with 0 scroll
    // containers (there are none in this fixture). Must be `.some(0)`, not
    // `null` -- a caller telling these apart (e.g. to know whether
    // setRect/setScrollData might have run) needs the distinction.
    const first = clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0, &scroll_scratch, null);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(usize, 0), first.?);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    // Second call: same size, no content/scroll change -- genuinely skips.
    // Must be `null`, not `0` -- this is the exact case a `0`-only return
    // couldn't distinguish from the first call above.
    const second = clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false, 0, 0, &scroll_scratch, null);
    try std.testing.expect(second == null);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

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

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

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

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

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

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

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

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

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

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

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

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    var clay_layout = try ClayLayout.init(allocator, 600, 200, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    // Predicted from the fixture's real layout: root is CLAY_LEFT_TO_RIGHT
    // (Clay's own default, unset by main.zig's zeroed root_decl). W23's own
    // right-column layout change wrapped the original Fixed(300)x(640)
    // container in a new Fit()-sized LeftToRight wrapper (that container +
    // Table's own 370px-wide right column, widened from 300 to fit Table's
    // own widened columns -- see main.go's tableColumns doc comment -- + a
    // 16px gap = 686px), so the Fixed(200)x(100) scroll container (still a
    // top-level sibling of that wrapper, untouched by the change -- it was
    // never nested inside the original container to begin with) now
    // occupies x:[686,886], not [300,500] -- see W23's own writeup in
    // project_natyv.md for why moving Table right shifted this. Frame 1
    // must already pass a mouse position over the scroll container -- Clay
    // only registers pointerOverIds from a real EndLayout pass, and this is
    // the only recompute before the scroll-carrying frame below.
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 786, 50, false, 0, 0, &scroll_scratch, null);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
            try std.testing.expectApproxEqAbs(@as(f32, 686), slot.widget.container.rect.x, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 200), slot.widget.container.rect.w, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 100), slot.widget.container.rect.h, 0.01);
        }
    }

    // Content is 5 rows * Fixed(40) = 200px inside a Fixed(100) container --
    // 100px of overflow. A delta far beyond that must clamp exactly to
    // -100, not merely "move some amount."
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 786, 50, false, 0, -1000, &scroll_scratch, null);
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    var clay_layout = try ClayLayout.init(allocator, 600, 200, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    // Frame 1: baseline, mouse pre-positioned over the scroll container --
    // see the previous test's identical layout prediction/reasoning (W23's
    // right-column change moved it to x:[686,886]).
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 786, 50, false, 0, 0, &scroll_scratch, null);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 786, 50, false, 0, -3, &scroll_scratch, null);
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
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 786, 50, false, 0, 0, &scroll_scratch, null);
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
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 786, 50, false, 0, -3, &scroll_scratch, null);
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    // First sync: nothing cached yet, must create the button's TTF_Text.
    // Multi-window Stage 3: syncTextObjects now takes an explicit allowed-id
    // list (see its own doc comment) -- this test has no window_root widget
    // at all, so every widget in the registry qualifies.
    {
        var pre_snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
        const pre_n = runtime.widgets.snapshot(io, &pre_snap);
        var pre_ids: [WidgetHost.max_widgets]u32 = undefined;
        for (pre_snap[0..pre_n], 0..) |s, i| pre_ids[i] = s.id;
        runtime.widgets.syncTextObjects(io, engine, font_cap.font, pre_ids[0..pre_n]);
    }

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    // not just produce the same string again. Multi-window Stage 3: `snap`
    // still holds every id from the snapshot just above (text-only mutation
    // never changes the registry's id set), so it's a valid allowed-id list.
    var all_ids: [WidgetHost.max_widgets]u32 = undefined;
    for (snap[0..n], 0..) |s, i| all_ids[i] = s.id;
    runtime.widgets.syncTextObjects(io, engine, font_cap.font, all_ids[0..n]);
    _ = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == bid) try std.testing.expectEqual(@as(u32, 1), slot.widget.button.sync_count);
    }

    // Relabel via the guest's real natyv_dispatch -> natyv_set_text path
    // (same mechanism the L4 test above uses) -- must force a real re-sync
    // on the next call.
    var payload_buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{{\"widget_id\":{d},\"event_type\":\"Grown\"}}", .{bid});
    _ = runtime.call(io, "natyv_test_hook", payload) orelse return error.CallFailed;

    runtime.widgets.syncTextObjects(io, engine, font_cap.font, all_ids[0..n]);
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    // Give the initial button a real TTF_Text before triggering the click
    // -- otherwise there'd be nothing for the bug to actually crash on.
    // Multi-window Stage 3: see the identical comment on the sibling test
    // above -- no window_root widget here, so every registry id qualifies.
    {
        var pre_snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
        const pre_n = runtime.widgets.snapshot(io, &pre_snap);
        var pre_ids: [WidgetHost.max_widgets]u32 = undefined;
        for (pre_snap[0..pre_n], 0..) |s, i| pre_ids[i] = s.id;
        runtime.widgets.syncTextObjects(io, engine, font_cap.font, pre_ids[0..pre_n]);
    }

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
        // Multi-window Stage 3: the worker thread may have destroyed/created
        // widgets since the last iteration's snapshot, so the allowed-id
        // list needs a fresh structural snapshot each pass, not `snap` from
        // outside the loop -- see syncTextObjects' own doc comment.
        var sync_ids: [WidgetHost.max_widgets]u32 = undefined;
        var sync_snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
        const sync_n = runtime.widgets.snapshot(io, &sync_snap);
        for (sync_snap[0..sync_n], 0..) |s, si| sync_ids[si] = s.id;
        runtime.widgets.syncTextObjects(io, engine, font_cap.font, sync_ids[0..sync_n]);
        n = runtime.widgets.snapshot(io, &snap);
        // Real main.zig draws every frame too -- matching that here, not
        // just polling registry state, since the actual crash may need a
        // concurrent TTF_DrawRendererText touching the same text engine's
        // shared atlas state while the worker thread destroys a text object,
        // not just the destroy call in isolation.
        for (snap[0..n]) |slot| {
            if (slot.widget == .button) slot.widget.button.drawDecorations(renderer, WidgetHost.effectiveTextPadding(slot.clay_style.padding));
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // 16, not 8 -- see the L3 test's identical comment above (W2 bump).
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"CheckIt\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == cbid) try std.testing.expect(slot.widget.checkbox.checked);
    }

    // Real guest-routed radio selection -- must flip exclusivity: B becomes
    // checked, A (checked since natyv_init) becomes unchecked.
    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"SelectRadioB\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == raid) try std.testing.expect(!slot.widget.radio_button.checked);
        if (slot.id == rbid) try std.testing.expect(slot.widget.radio_button.checked);
    }

    // Real guest-routed progress value change.
    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"SetProgressHalf\"}") orelse return error.CallFailed;
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"SetSliderQuarter\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == sid) try std.testing.expectApproxEqAbs(@as(f32, 0.25), slot.widget.slider.value, 0.001);
    }
}

test "W27: a range slider created via natyv_clay_create_range_slider round-trips its min/max, and natyv_set_range works on it through a real guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    // Exactly one range_slider exists in this fixture -- matching by kind
    // alone is unambiguous, same precedent the W6 combobox test's TextField
    // match already established.
    var range_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .range_slider) {
            try std.testing.expectApproxEqAbs(@as(f32, 0), slot.widget.range_slider.min, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 1), slot.widget.range_slider.max, 0.001);
            range_id = slot.id;
        }
    }
    const rid = range_id orelse return error.MissingRangeSlider;

    // Real guest-routed range change (natyv_set_range via natyv_dispatch,
    // priceRange.SetRange -- see main.go's own "SetPriceRange" test-hook
    // case), same shape as W3's own SetSliderQuarter case above.
    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"SetPriceRange\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == rid) {
            try std.testing.expectApproxEqAbs(@as(f32, 0.2), slot.widget.range_slider.min, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 0.8), slot.widget.range_slider.max, 0.001);
        }
    }
}

test "W28: a Card's title/content structure round-trips, and a real click inside its content updates the mirrored status Label" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    // The title Label -- exactly one Label reads "Card Demo" in this
    // fixture -- unambiguous to match directly.
    var title_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Card Demo")) title_id = slot.id;
    }
    const tid = title_id orelse return error.MissingCardTitle;

    // The panel itself (the title's own parent) must have its background
    // fill on -- Card is a Panel under the hood (see card.go's own doc
    // comment).
    var panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.id == tid) panel_id = slot.parent_id;
    }
    const pid = panel_id orelse return error.MissingCardPanel;
    for (snap[0..n]) |slot| {
        if (slot.id == pid) try std.testing.expect(slot.widget.container.background);
    }

    // Exactly one Button labeled "Click Me" exists -- real guest-routed
    // click (natyv_dispatch), not a test hook, proves Card.ContentID()'s
    // own parenting actually works end to end, not just that the panel/
    // title exist.
    var click_id: ?u32 = null;
    var status_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Click Me")) click_id = slot.id;
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Clicked: 0")) status_id = slot.id;
    }
    const cid = click_id orelse return error.MissingCardButton;
    const sid = status_id orelse return error.MissingCardStatus;

    var dispatch_buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{cid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == sid) try std.testing.expectEqualStrings("Clicked: 1", slot.widget.label.text());
    }

    // The title-less Panel demo also exists, with its own background fill
    // on and its own descriptive Label as a real child -- proves Panel
    // itself (not just Card, which wraps it) round-trips correctly too.
    var panel_demo_label_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "A plain Panel -- just a background + border, no title row.")) {
            panel_demo_label_id = slot.id;
        }
    }
    const plid = panel_demo_label_id orelse return error.MissingPanelDemoLabel;
    var panel_demo_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.id == plid) panel_demo_id = slot.parent_id;
    }
    const pdid = panel_demo_id orelse return error.MissingPanelDemo;
    for (snap[0..n]) |slot| {
        if (slot.id == pdid) try std.testing.expect(slot.widget.container.background);
    }
}

test "W29: a spinner exists, is not focusable, gets real Clay-computed geometry, and its own dotScale math is not part of this test (pure, unit-tested directly in Spinner.zig)" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);

    // Exactly one Spinner exists in this fixture -- matching by kind alone
    // is unambiguous, same precedent the W11 divider test already
    // established.
    var spinner_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .spinner) spinner_id = slot.id;
    }
    const sid = spinner_id orelse return error.MissingSpinner;

    for (snap[0..n]) |slot| {
        if (slot.id == sid) {
            // Never focusable -- confirms Widget.isFocusable's .spinner
            // arm, not just that the widget exists (Quinn's own explicit
            // requirement: purely visual, no focus at all).
            try std.testing.expect(!slot.widget.isFocusable());
            // Real Clay-computed geometry, not the zeroed rect it was
            // created with -- same precedent every other Clay-managed
            // widget's own test already confirms.
            try std.testing.expectApproxEqAbs(@as(f32, 60), slot.widget.spinner.rect.w, 0.5);
            try std.testing.expectApproxEqAbs(@as(f32, 16), slot.widget.spinner.rect.h, 0.5);
        }
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
    try runtime.loadPlugin(wasm, .{}, true);
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
    // Bumped from 50 -- natyv_init's baseline grew to 51 with the
    // Accordion demo (see the L3 test's comment above), so this buffer
    // needs headroom past that plus whatever this test opens on top.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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

    // Real guest-routed open -- a real click on the trigger (natyv_dispatch
    // -- Menu.onTriggerClick, the productized Dropdown's own underlying
    // Menu), not a test hook -- proves the click actually routes through
    // it, not just that Open() itself works.
    var dispatch_buf: [256]u8 = undefined;
    var payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
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

    // Real guest-routed select-and-close -- a real click on "Option 2"
    // itself (natyv_set_text on the trigger + natyv_destroy_widget on the
    // panel/options, via natyv_dispatch -- Menu.selectItem), same "destroy
    // old widgets" pattern examples/bookstore and the F3-regression fixture
    // case already established.
    var option2_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Option 2")) option2_id = slot.id;
    }
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{option2_id orelse return error.MissingOption2});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    for (snap[0..n]) |slot| {
        if (slot.id == tid) try std.testing.expectEqualStrings("Option 2", slot.widget.button.label());
        // The panel and its options must be gone entirely, not just
        // hidden -- natyv has no "visible" concept, only exists/doesn't.
        try std.testing.expect(slot.id != pid);
    }
}

// Real crash regression (Quinn's own real click-through on `clay-fixture`,
// caught live, not by any prior unit test): `WidgetHostFunctions.
// destroyWidgetHostFn` -- `natyv_destroy_widget`'s own single-widget,
// no-cascade destroy path, distinct from `destroySubtreeLocked`'s cascading
// one -- nulled a slot directly without removing its `id_to_index` entry
// when that map was first added. Every prior test that exercised this exact
// path (including the dropdown-select test right above) only ever checked
// that the destroyed id was gone from a fresh `snapshot()` (which reads the
// raw `slots` array directly, never consulting `id_to_index` at all), so
// none of them actually exercised a *second* lookup by the now-stale id --
// which is exactly what `ClayLayout.layoutIfNeeded`'s real writeback loop
// does every frame via `WidgetHost.setRect`, racing the dispatch worker
// thread's own destroys in the real app. Reproduced here deterministically,
// with no threading needed at all: the underlying bug is a plain data
// inconsistency (a stale map entry pointing at a now-null slot), not
// something that only manifests under real concurrency -- the race in the
// real app just decides *when* a second lookup lands on a freshly-destroyed
// id, not *whether* one crashes once it does.
test "Real crash regression: WidgetHost.setRect on an id destroyed via natyv_destroy_widget's single-widget path is a safe no-op, not a panic" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Select...")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingTrigger;

    var dispatch_buf: [256]u8 = undefined;
    var payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    var option2_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) panel_id = slot.id;
    }
    const pid = panel_id orelse return error.MissingPanel;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Option 2")) option2_id = slot.id;
    }
    const oid = option2_id orelse return error.MissingOption2;

    // Real click on "Option 2" -- destroys the panel and both option
    // buttons via `natyv_destroy_widget` (Menu.selectItem), the exact
    // single-widget destroy path this test targets.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{oid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;

    // Before the fix, this second lookup on the now-destroyed `pid`/`oid`
    // would panic inside `findLocked` on `self.slots[idx].?` -- a stale
    // `id_to_index` entry pointing at a slot that's already been nulled.
    // Simply not crashing is the real assertion here; `setRect` becoming a
    // no-op for a missing id is `findLocked`'s own documented contract.
    runtime.widgets.setRect(io, pid, .{ .x = 1, .y = 1, .w = 1, .h = 1 });
    runtime.widgets.setRect(io, oid, .{ .x = 1, .y = 1, .w = 1, .h = 1 });

    // The registry itself must still be healthy afterward -- a fresh
    // create still gets served correctly, and neither destroyed id is
    // still resolvable by id.
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.id != pid);
        try std.testing.expect(slot.id != oid);
    }
}

// Migration follow-up (Quinn's real click-through feedback): Dropdown's
// original v1 scope deliberately had no arrow-key cycling or click-away
// close (see Combobox's own doc comment contrasting itself with this).
// Brought up to Combobox's own level -- this proves both new real
// interactions end to end through a real guest.
test "Dropdown follow-up: arrow-key cycling + Enter selects the highlighted option, and a real click-away closes the panel" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);
    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Select...")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingTrigger;

    var dispatch_buf: [256]u8 = undefined;
    var payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) panel_id = slot.id;
    }
    const pid = panel_id orelse return error.MissingDropdownPanel;

    // Two "down" presses (-1 -> 0 -> 1) reach "Option 2", proving the
    // marker actually moves via SetLabel, not a destroy/recreate churn.
    for (0..2) |_| {
        payload = try buildDispatchEnvelope(&dispatch_buf, tid, "key_nav", "{\"key\":\"down\"}");
        _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    }
    n = runtime.widgets.snapshot(io, &snap);
    var option2_marked = false;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "\xe2\x96\xb8 Option 2")) option2_marked = true;
    }
    try std.testing.expect(option2_marked);

    // A focused Button's Enter always fires a real `.click` on the trigger
    // (never a separate `.key_nav` "enter" -- see main.zig's own SDLK_RETURN
    // handling), so that's what confirms the highlighted option, same shape
    // Menu's own Enter-while-highlighted regression test already uses.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == tid) try std.testing.expectEqualStrings("Option 2", slot.widget.button.label());
        try std.testing.expect(slot.id != pid);
    }

    // Reopen, then close via a real click-away -- a `.blur` on the trigger
    // naming a new_focus_id that isn't part of the dropdown (the "Grow
    // Button" from W1, unambiguous elsewhere in this fixture).
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    var reopened_panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) reopened_panel_id = slot.id;
    }
    const rpid = reopened_panel_id orelse return error.MissingDropdownPanel;

    var grow_button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Grow Button")) grow_button_id = slot.id;
    }
    const gbid = grow_button_id orelse return error.MissingGrowButton;
    var blur_payload_buf: [32]u8 = undefined;
    payload = try buildDispatchEnvelope(&dispatch_buf, tid, "blur", try std.fmt.bufPrint(&blur_payload_buf, "{{\"new_focus_id\":{d}}}", .{gbid}));
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        try std.testing.expect(slot.id != rpid);
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
    try runtime.loadPlugin(wasm, .{}, true);
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    // natyv_init's baseline is now 31 (see the L3 test's comment above),
    // plus this test opens the modal (panel + message + close button = 3
    // more) -- 34 at peak, comfortably under this buffer's 50. Same
    // silent-truncation risk documented at every prior buffer bump in
    // this file (this exact class of bug is what W16's own dropdown test
    // caught when its buffer went stale -- see that test's comment).
    // Bumped from 50 -- natyv_init's baseline grew to 51 with the
    // Accordion demo (see the L3 test's comment above), so this buffer
    // needs headroom past that plus whatever this test opens on top.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"OpenModal\"}") orelse return error.CallFailed;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // natyv_init's baseline is now 31 (see the L3 test's comment above),
    // plus this test opens the combobox's panel (up to 5 filtered options
    // + the panel itself = 6 more) -- 37 at peak, comfortably under this
    // buffer's 50. Same silent-truncation risk documented at every prior
    // buffer bump in this file.
    // Bumped from 50 -- natyv_init's baseline grew to 51 with the
    // Accordion demo (see the L3 test's comment above), so this buffer
    // needs headroom past that plus whatever this test opens on top.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // natyv_init's baseline is now 31 (see the L3 test's comment above),
    // plus this test opens the combobox's panel with up to 5 filtered
    // options -- comfortably under this buffer's 50.
    // Bumped from 50 -- natyv_init's baseline grew to 51 with the
    // Accordion demo (see the L3 test's comment above), so this buffer
    // needs headroom past that plus whatever this test opens on top.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    // wiring, not a real mouse click moving focus elsewhere. A real
    // `.blur` always carries a `{"new_focus_id":N}` payload (see
    // blurPayload on the guest side, decoded unconditionally by the SDK's
    // own dispatch for every `.blur`, not just ones a handler happens to
    // read) -- 0 here means focus moved to nothing in particular.
    payload = try buildDispatchEnvelope(&dispatch_buf, fid, "blur", "{\"new_focus_id\":0}");
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // natyv_init's baseline is now 31 (see the L3 test's comment above),
    // plus this test fires one toast (its own Container + a message Label
    // = 2 more) -- 33 at peak, comfortably under this buffer's 50. Same
    // silent-truncation risk documented at every prior buffer bump in
    // this file.
    // Bumped from 50 -- natyv_init's baseline grew to 51 with the
    // Accordion demo (see the L3 test's comment above), so this buffer
    // needs headroom past that plus whatever this test opens on top.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"ShowToast\"}") orelse return error.CallFailed;
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

test "Menu (productized): a real click opens the dropdown, key_nav highlights the item, a synthesized Enter selects it and closes the menu, and a real .blur closes an open one unconditionally" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Menu")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingMenuTrigger;

    // Real guest-routed open (a real click, not the test hook -- proves the
    // click actually routes through onTriggerClick, not just that Open()
    // itself works).
    var dispatch_buf: [256]u8 = undefined;
    var payload = try buildDispatchEnvelope(&dispatch_buf, tid, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) panel_id = slot.id;
    }
    const pid = panel_id orelse return error.MissingMenuPanel;

    var item_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button) item_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), item_count); // Open/Save/Exit

    // One "down" press highlights the first item ("Open", index 0).
    payload = try buildDispatchEnvelope(&dispatch_buf, tid, "key_nav", "{\"key\":\"down\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var open_marked = false;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "\xe2\x96\xb8 Open")) open_marked = true;
    }
    try std.testing.expect(open_marked);

    // Enter never produces a separate key_nav "enter" event for a focused
    // Button (that stays gated to .textfield only) -- it always produces
    // this same .click on the focused widget (main.zig's SDLK_RETURN
    // handling), so synthesizing that .click on the still-focused trigger
    // is exactly what a real Enter keypress sends, same convention every
    // other floating widget's own test in this file already uses.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var selected_seen = false;
    var panel_remains = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Menu selected: Open")) selected_seen = true;
        if (slot.id == pid) panel_remains = true;
        if (slot.parent_id) |parent| {
            if (parent == pid) panel_remains = true;
        }
    }
    try std.testing.expect(selected_seen);
    try std.testing.expect(!panel_remains);

    // Re-open (via the test hook this time, proving Open() itself works
    // too, not just the click path above), then a real .blur closes it
    // unconditionally -- no submenu-focus exception exists in this
    // productized v1 (see menu.go's own doc comment for why that's a
    // deliberate cut, not an oversight).
    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"OpenMenu\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    var reopened_pid: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) reopened_pid = slot.id;
    }
    const rpid = reopened_pid orelse return error.MissingMenuPanel;

    const blur_payload = "{\"new_focus_id\":0}";
    payload = try buildDispatchEnvelope(&dispatch_buf, tid, "blur", blur_payload);
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var panel_survived_blur = false;
    for (snap[0..n]) |slot| {
        if (slot.id == rpid) panel_survived_blur = true;
        if (slot.parent_id) |parent| {
            if (parent == rpid) panel_survived_blur = true;
        }
    }
    try std.testing.expect(!panel_survived_blur);
}
// Submenu capability restored per Quinn's follow-up (2026-08-19): the
// first W24 pass deliberately cut cascading submenus from Menu's v1 scope
// (see menu.go's own type doc comment); this proves the restored one-level
// submenu positions/scopes/closes correctly, adapted from the fixture's
// own original W9 test (same real dispatch style, same "Sub A"/"Sub B"
// data), now driven through MenuItem's generalized shape instead of a
// single hard-coded "more" index.
test "Menu (productized) submenu: opening a submenu-triggering item's own dropdown positions correctly below it, key_nav is scoped to whichever level is open, a real .blur while focus is on the submenu trigger keeps it open, and selecting a submenu leaf reports (itemIndex, subIndex) and closes both levels" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Menu")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingMenuTrigger;

    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"OpenMenu\"}") orelse return error.CallFailed;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
    n = runtime.widgets.snapshot(io, &snap);

    var panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) panel_id = slot.id;
    }
    const pid = panel_id orelse return error.MissingMenuPanel;

    // "More ▸" is the 2nd entry (index 1: Open, More, Exit) -- two "down"
    // presses reach it (-1 -> 0 -> 1).
    var dispatch_buf: [256]u8 = undefined;
    var payload: []u8 = undefined;
    for (0..2) |_| {
        payload = try buildDispatchEnvelope(&dispatch_buf, tid, "key_nav", "{\"key\":\"down\"}");
        _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    }
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
    n = runtime.widgets.snapshot(io, &snap);

    var more_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == pid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "\xe2\x96\xb8 More \xe2\x96\xb8")) more_id = slot.id;
    }
    const mid = more_id orelse return error.MissingMoreItem;
    const more_rect = for (snap[0..n]) |slot| {
        if (slot.id == mid) break slot.widget.button.rect;
    } else return error.MissingMoreItem;

    // Enter (synthesized as another .click on the still-focused trigger,
    // same convention as the flat-selection test above) opens the submenu
    // since the highlighted entry has Items.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
    n = runtime.widgets.snapshot(io, &snap);

    var submenu_pid: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == mid and slot.widget == .container) submenu_pid = slot.id;
    }
    const spid = submenu_pid orelse return error.MissingSubmenuPanel;

    var sub_item_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == spid and slot.widget == .button) sub_item_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), sub_item_count);

    // Real, distinct Clay-computed position -- the submenu is parented to
    // (and positioned below) "More ▸" specifically, not the top-level
    // trigger.
    for (snap[0..n]) |slot| {
        if (slot.id == spid) {
            try std.testing.expectApproxEqAbs(more_rect.x, slot.widget.container.rect.x, 0.5);
            try std.testing.expectApproxEqAbs(more_rect.y + more_rect.h, slot.widget.container.rect.y, 0.5);
        }
    }

    // A real click on "More ▸" also moves focus onto it, firing a genuine
    // .blur on the trigger in the same frame -- synthesized here the same
    // way every other real-dispatch test in this file hand-assembles what
    // main.zig's actual event loop would send. Proves onTriggerBlur's own
    // exception (new focus is the open submenu's own trigger item) keeps
    // the cascade open, not just that it happens to still exist.
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

    // key_nav dispatched directly to mid (not tid) -- proving the item's
    // own OnKeyNav wiring (added specifically so arrow keys keep working
    // once focus has genuinely moved off the trigger) actually routes,
    // scoped to the submenu level.
    payload = try buildDispatchEnvelope(&dispatch_buf, mid, "key_nav", "{\"key\":\"down\"}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var sub_a_marked = false;
    var top_level_marker_found = false;
    for (snap[0..n]) |slot| {
        if (slot.widget != .button) continue;
        if (slot.parent_id != null and slot.parent_id.? == spid and std.mem.eql(u8, slot.widget.button.label(), "\xe2\x96\xb8 Sub A")) sub_a_marked = true;
        if (slot.parent_id != null and slot.parent_id.? == pid and std.mem.indexOf(u8, slot.widget.button.label(), "\xe2\x96\xb8 ") != null and slot.id != mid) top_level_marker_found = true;
    }
    try std.testing.expect(sub_a_marked);
    try std.testing.expect(!top_level_marker_found);

    // A real click on "Sub A" selects it -- both levels close, and the
    // mirrored status Label reflects "More > Sub A", proving OnSelect's
    // own (itemIndex=1, subIndex=0) reached the guest's own
    // menuSelectionLabel helper correctly.
    var sub_a_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == spid and slot.widget == .button and std.mem.indexOf(u8, slot.widget.button.label(), "Sub A") != null) sub_a_id = slot.id;
    }
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{sub_a_id orelse return error.MissingSubA});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var status_seen = false;
    var any_menu_widgets_remain = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Menu selected: More > Sub A")) status_seen = true;
        if (slot.id == pid or slot.id == spid) any_menu_widgets_remain = true;
        if (slot.parent_id) |parent| {
            if (parent == pid or parent == spid) any_menu_widgets_remain = true;
        }
    }
    try std.testing.expect(status_seen);
    try std.testing.expect(!any_menu_widgets_remain);
}

// Repro carried over from the fixture's own pre-productization Menu (see
// updateLabels' own doc comment in menu.go for the original bug this
// caught: a naive destroy/recreate on every arrow-key highlight move
// visibly went blank under rapid real key repeat, even though the widget
// registry itself stayed correct throughout). The productized Menu keeps
// the exact same "relabel existing Buttons in place, never destroy/
// recreate on a highlight move" design, so this regression is worth
// re-proving against it directly rather than assuming the port preserved
// the fix.
test "Menu (productized) migration repro: many rapid key_nav presses, with a real layout pass after each, never leave a row blank or stale" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);
    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Menu")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingMenuTrigger;

    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"OpenMenu\"}") orelse return error.CallFailed;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
    n = runtime.widgets.snapshot(io, &snap);
    var panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == tid and slot.widget == .container) panel_id = slot.id;
    }
    const pid = panel_id orelse return error.MissingMenuPanel;

    var dispatch_buf: [256]u8 = undefined;
    const keys = [_][]const u8{ "down", "down", "down", "down", "down", "up", "down", "up", "up", "down" };
    for (keys, 0..) |key, step| {
        var key_payload_buf: [32]u8 = undefined;
        const key_json = try std.fmt.bufPrint(&key_payload_buf, "{{\"key\":\"{s}\"}}", .{key});
        const payload = try buildDispatchEnvelope(&dispatch_buf, tid, "key_nav", key_json);
        _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;

        // Real layout pass after *every* press -- what a real held key
        // would get between repeats too.
        _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
        n = runtime.widgets.snapshot(io, &snap);

        var item_count: usize = 0;
        for (snap[0..n]) |slot| {
            if (slot.parent_id == null or slot.parent_id.? != pid or slot.widget != .button) continue;
            item_count += 1;
            if (slot.widget.button.label().len == 0) {
                std.debug.print("[menu-repro] step={d} key={s}: BLANK LABEL on widget {d}\n", .{ step, key, slot.id });
                return error.BlankMenuItemLabel;
            }
            if (slot.widget.button.rect.w == 0 or slot.widget.button.rect.h == 0) {
                std.debug.print("[menu-repro] step={d} key={s}: ZEROED RECT on widget {d} label=\"{s}\"\n", .{ step, key, slot.id, slot.widget.button.label() });
                return error.ZeroedMenuItemRect;
            }
        }
        if (item_count != 3) {
            std.debug.print("[menu-repro] step={d} key={s}: expected 3 top-level items, found {d}\n", .{ step, key, item_count });
            return error.WrongMenuItemCount;
        }
    }
}

// Menu bar's own real value over just using Menu directly N times: real
// click coverage that "only one bar menu open at a time" needs zero
// bar-level coordination code (see menubar.go's own doc comment) -- the
// host's existing single global focused_widget_id already fires .blur on
// whichever trigger was previously focused before a different one's own
// .click runs, and Menu.onTriggerBlur already closes unconditionally on
// any blur. This test proves that composition actually works end-to-end,
// not just that it should in theory.
test "Menu bar: a real click on a second bar item closes whichever one was already open, purely via the same blur mechanism every other floating widget already uses" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var file_id: ?u32 = null;
    var edit_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "File")) file_id = slot.id;
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Edit")) edit_id = slot.id;
    }
    const fid = file_id orelse return error.MissingFileTrigger;
    const eid = edit_id orelse return error.MissingEditTrigger;

    // Real click opens File's own dropdown.
    var dispatch_buf: [256]u8 = undefined;
    var payload = try buildDispatchEnvelope(&dispatch_buf, fid, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var file_panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == fid and slot.widget == .container) file_panel_id = slot.id;
    }
    const file_pid = file_panel_id orelse return error.MissingFilePanel;

    var file_item_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == file_pid and slot.widget == .button) file_item_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), file_item_count); // New/Open/Save/Export/Exit

    // A real click on Edit while File's dropdown is open: main.zig's own
    // event loop would fire .blur on File's trigger (carrying Edit's own id
    // as new_focus_id) before Edit's own .click runs (see main.zig's
    // updateFocus) -- synthesized here in that same order, same "hand-
    // assemble what the real event loop would send" convention every other
    // real-dispatch test in this file already uses.
    var blur_payload_buf: [64]u8 = undefined;
    const blur_payload = try std.fmt.bufPrint(&blur_payload_buf, "{{\"new_focus_id\":{d}}}", .{eid});
    payload = try buildDispatchEnvelope(&dispatch_buf, fid, "blur", blur_payload);
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    payload = try buildDispatchEnvelope(&dispatch_buf, eid, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var file_panel_gone = true;
    var edit_panel_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.id == file_pid) file_panel_gone = false;
        if (slot.parent_id) |parent| {
            if (parent == file_pid) file_panel_gone = false;
        }
        if (slot.parent_id != null and slot.parent_id.? == eid and slot.widget == .container) edit_panel_id = slot.id;
    }
    try std.testing.expect(file_panel_gone);
    const edit_pid = edit_panel_id orelse return error.MissingEditPanel;

    var edit_item_count: usize = 0;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == edit_pid and slot.widget == .button) edit_item_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), edit_item_count); // Cut/Copy/Paste

    // Real click on one of Edit's own items selects it and closes Edit's
    // dropdown, mirrored into the bar's shared status Label with both the
    // header and item name -- proves MenuBar.OnSelect's own barIndex
    // wiring reaches the right entry, not just that *a* selection fired.
    var cut_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.parent_id != null and slot.parent_id.? == edit_pid and slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Cut")) cut_id = slot.id;
    }
    payload = try buildDispatchEnvelope(&dispatch_buf, cut_id orelse return error.MissingCutItem, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var status_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Menu bar selected: Edit > Cut")) status_seen = true;
    }
    try std.testing.expect(status_seen);
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // 32: natyv_init's 31 widgets (see the L3 test's comment above) --
    // this test never opens anything else on top, well within headroom.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    // drive it (a literal "\n" is just another string to insert -- see
    // insertTextAt's doc comment).
    var text_buf: [TextArea.max_len]u8 = undefined;
    const written = runtime.widgets.insertTextAt(io, aid, "line one\nline two", &text_buf) orelse return error.AppendFailed;
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    // 32: natyv_init's 31 widgets (see the L3 test's comment above) --
    // this test never opens anything else on top, well within headroom.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // 32: natyv_init's 31 widgets (see the L3 test's comment above) --
    // this test never opens anything else on top, well within headroom.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    _ = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"ToggleOn\"}") orelse return error.CallFailed;
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    // 32: natyv_init's 31 widgets (see the L3 test's comment above) --
    // this test never opens anything else on top, well within headroom.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // natyv_init's baseline is now 45 (see the L3 test's comment above),
    // plus this test opens the tooltip (Container + Label = 2 more) -- 47
    // at peak, which silently overflowed the old 40-slot buffer (W19's +7
    // widget bump). Bumped to 55 for headroom. Same silent-truncation risk
    // documented at every prior buffer bump in this file.
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    try runtime.loadPlugin(wasm, .{}, true);
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
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // Bumped from 100 -- same peak-widget-count math as the previous
    // test's own updated comment (W19's +7 widget bump on natyv_init's
    // baseline pushed this picker-open scenario's peak past 100 too).
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    // W19 follow-up: bumped from 48 -- natyv_init now creates 45 widgets on
    // its own (see the L3 test's own updated count/comment), and this test
    // opens the popover on top of that (+4), which silently overflowed a
    // 48-slot buffer before this bump (same "snapshot() caps at out.len
    // with no error" risk that comment documents).
    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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

    // Reopen, then close via click-away instead -- a real `.blur` event on
    // the trigger itself (the widget a real click that opened the popover
    // would have actually focused), naming a new_focus_id (the "Grow
    // Button" from W1, unambiguous elsewhere in this fixture) that isn't
    // part of the popover -- the same shape main.zig's updateFocus fires on
    // a real click outside. Each popover-owned widget registers its own
    // OnBlur (see openPopover), so the blur must target one of *those*
    // widgets to be observed at all -- unlike the old hand-rolled dispatch,
    // which (harmlessly, but non-selectively) listened to literally any
    // blur while the panel was open, regardless of which widget it named.
    payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{tid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 4), n - baseline);

    var grow_button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Grow Button")) grow_button_id = slot.id;
    }
    const gbid = grow_button_id orelse return error.MissingGrowButton;
    var blur_payload_buf: [32]u8 = undefined;
    payload = try buildDispatchEnvelope(&dispatch_buf, tid, "blur", try std.fmt.bufPrint(&blur_payload_buf, "{{\"new_focus_id\":{d}}}", .{gbid}));
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

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

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

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
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == tabs_id) tabs_rect = slot.widget.tabs.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, Tabs.header_height) + 150, tabs_rect.h, 0.5);

    // And back down again -- proves it's not a one-way "grow and stay"
    // artifact; the short panel's own height genuinely isn't padded out by
    // the now-hidden tall one.
    _ = runtime.widgets.setActiveTab(io, tabs_id, 0) orelse return error.ValueUnchanged;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
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
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
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
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

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
    const index = WidgetHost.SnapshotIndex.build(&slots);

    // The child's own flag is true, but its grandparent's is false -- the
    // whole chain must be treated as not visible.
    try std.testing.expect(!WidgetHost.isEffectivelyVisible(&slots, index, child));
    // The parent's own flag is true too, but it's under the same hidden
    // grandparent.
    try std.testing.expect(!WidgetHost.isEffectivelyVisible(&slots, index, parent));
    // The grandparent's own flag alone already makes it invisible.
    try std.testing.expect(!WidgetHost.isEffectivelyVisible(&slots, index, grandparent));

    // Flip the grandparent visible again -- every level's own flag is now
    // true, so the whole chain resolves to effectively visible.
    var slots2 = slots;
    slots2[0].clay_style.visible = true;
    const index2 = WidgetHost.SnapshotIndex.build(&slots2);
    try std.testing.expect(WidgetHost.isEffectivelyVisible(&slots2, index2, slots2[2]));
}

test "Accordion: WidgetHost.setVisible flips a plain widget's visible flag, bumps layout_generation only on a real change, and fails for a missing id" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    // Unlike Tabs (host-owned, needs its own WidgetKind), Accordion is
    // guest-composed -- setVisible works on any Clay-managed widget at all,
    // so a plain Container (no Accordion-specific type in the registry) is
    // enough to exercise it.
    const content_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(50) },
    }) orelse return error.RegistryFull;

    const gen_after_insert = runtime.widgets.layout_generation;

    try std.testing.expect(runtime.widgets.setVisible(io, content_id, false));
    var snap: [4]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == content_id) try std.testing.expect(!slot.clay_style.visible);
    }
    try std.testing.expectEqual(gen_after_insert +% 1, runtime.widgets.layout_generation);

    // A repeated identical call (already false) is a no-op -- same
    // "return without bumping generation" contract setActiveTab's own
    // no-op-call test proves.
    const gen_before_repeat = runtime.widgets.layout_generation;
    try std.testing.expect(runtime.widgets.setVisible(io, content_id, false));
    try std.testing.expectEqual(gen_before_repeat, runtime.widgets.layout_generation);

    // Flipping back to true bumps again -- proves the guard is
    // "did the value change," not "only false->? counts."
    try std.testing.expect(runtime.widgets.setVisible(io, content_id, true));
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == content_id) try std.testing.expect(slot.clay_style.visible);
    }
    try std.testing.expectEqual(gen_before_repeat +% 1, runtime.widgets.layout_generation);

    // A missing id fails cleanly (the host function surfaces this as a
    // "no such widget" error to the guest, see setVisibleHostFn) rather
    // than silently no-oping.
    try std.testing.expect(!runtime.widgets.setVisible(io, content_id + 999, false));
}

test "Accordion: a Container hidden via setVisible is dropped from Clay's layout entirely -- a fit-sized parent stops accounting for it" {
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    // A fit-height column holding a header (fixed 32) and a content panel
    // (fixed 50) -- same "fit height tracks exactly what's currently
    // declared to Clay" proof W19's own Tabs regression test uses, just
    // with a plain Container parent instead of a dedicated WidgetKind,
    // since Accordion has no host-owned widget of its own to check.
    const section_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = fixedAxis(200), .height = .{ .type = c.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = 1e9 } } } },
        .direction = c.CLAY_TOP_TO_BOTTOM,
    }) orelse return error.RegistryFull;
    _ = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, section_id, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(32) },
    }) orelse return error.RegistryFull;
    const content_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, section_id, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(50) },
    }) orelse return error.RegistryFull;

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    var snap: [8]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);
    var section_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == section_id) section_rect = slot.widget.container.rect;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 32 + 50), section_rect.h, 0.5);

    // Collapse the content panel -- setVisible must bump layout_generation
    // for this next layoutIfNeeded to actually re-run Clay instead of
    // reusing the cached pre-collapse pass.
    try std.testing.expect(runtime.widgets.setVisible(io, content_id, false));
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == section_id) section_rect = slot.widget.container.rect;
    }
    // Only the header's 32 remains -- the content panel isn't declared to
    // Clay at all this frame, so it can't inflate the fit height, the same
    // proof the W19 Tabs test uses for its own switched-away panel.
    try std.testing.expectApproxEqAbs(@as(f32, 32), section_rect.h, 0.5);
}

test "Accordion: natyv_set_visible round-trips through a real compiled guest, and clicking either section header toggles its own content independently" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var header0_id: ?u32 = null;
    var header1_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget != .button) continue;
        const label = slot.widget.button.label();
        if (std.mem.eql(u8, label, "v Description")) header0_id = slot.id;
        if (std.mem.eql(u8, label, "> Specs")) header1_id = slot.id;
    }
    const h0 = header0_id orelse return error.MissingHeader0;
    const h1 = header1_id orelse return error.MissingHeader1;

    // Initial state, proven through the real compiled guest, not just
    // WidgetHost.setVisible directly: section 0 starts expanded (its
    // header already reads "v ", set at natyv_init time), section 1 starts
    // collapsed -- set via one real natyv_set_visible call in natyv_init,
    // not by never creating its content.
    // The header and its content Container are siblings under the same
    // parent, not parent/child of each other (see accordionHeaderIDs' own
    // doc comment) -- found via each content's own Label text instead, same
    // "identify a panel via its known-text child, then take that child's
    // parent_id" shape the W19 Tabs Pattern B test above already uses for
    // its own panels.
    var content0_id: ?u32 = null;
    var content1_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget != .label) continue;
        const text = slot.widget.label.text();
        if (std.mem.startsWith(u8, text, "Starts expanded")) content0_id = slot.parent_id;
        if (std.mem.startsWith(u8, text, "Starts collapsed")) content1_id = slot.parent_id;
    }
    const c0 = content0_id orelse return error.MissingContent0;
    const c1 = content1_id orelse return error.MissingContent1;
    for (snap[0..n]) |slot| {
        if (slot.id == c0) try std.testing.expect(slot.clay_style.visible);
        if (slot.id == c1) try std.testing.expect(!slot.clay_style.visible);
    }

    // A real click on section 1's header -- routed through the actual
    // EventQueue/Dispatch.run pipeline, same "click" EventType every real
    // mouse click produces, not a hand-built event type.
    var dispatch_buf: [256]u8 = undefined;
    const payload = try buildDispatchEnvelope(&dispatch_buf, h1, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        // Section 1 expanded...
        if (slot.id == c1) try std.testing.expect(slot.clay_style.visible);
        // ...and section 0 is untouched -- each section's toggle is fully
        // independent, unlike Tabs' mutual exclusivity.
        if (slot.id == c0) try std.testing.expect(slot.clay_style.visible);
        if (slot.id == h1) try std.testing.expectEqualStrings("v Specs", slot.widget.button.label());
    }

    // A real click on section 0's header now -- collapses it while section
    // 1 (already toggled open above) stays untouched, proving independence
    // holds in both directions, not just "opening one doesn't affect the
    // other."
    const payload2 = try buildDispatchEnvelope(&dispatch_buf, h0, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload2) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == c0) try std.testing.expect(!slot.clay_style.visible);
        if (slot.id == c1) try std.testing.expect(slot.clay_style.visible);
        if (slot.id == h0) try std.testing.expectEqualStrings("> Description", slot.widget.button.label());
    }
}

test "Scroll-into-view: WidgetHost.queueScrollIntoView/takePendingScrollIntoView hand off one pending target at a time" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    // Nothing queued yet.
    try std.testing.expectEqual(@as(?u32, null), runtime.widgets.takePendingScrollIntoView(io));

    runtime.widgets.queueScrollIntoView(io, 42);
    try std.testing.expectEqual(@as(?u32, 42), runtime.widgets.takePendingScrollIntoView(io));
    // Drained -- a second take returns null, doesn't repeat the same value.
    try std.testing.expectEqual(@as(?u32, null), runtime.widgets.takePendingScrollIntoView(io));

    // A second queue before the first is drained just overwrites -- no
    // ordering guarantee needed for this (see the field's own doc comment).
    runtime.widgets.queueScrollIntoView(io, 1);
    runtime.widgets.queueScrollIntoView(io, 2);
    try std.testing.expectEqual(@as(?u32, 2), runtime.widgets.takePendingScrollIntoView(io));
}

test "File picker: WidgetHost.queueFileDialogRequest/takePendingFileDialogRequest hand off one pending request at a time" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();

    // Nothing queued yet.
    try std.testing.expectEqual(@as(?WidgetHost.PendingFileDialogRequest, null), runtime.widgets.takePendingFileDialogRequest(io));

    runtime.widgets.queueFileDialogRequest(io, .{ .kind = .open, .widget_id = 7, .allow_many = true });
    const req = runtime.widgets.takePendingFileDialogRequest(io) orelse return error.MissingRequest;
    try std.testing.expectEqual(WidgetHost.PendingFileDialogRequest{ .kind = .open, .widget_id = 7, .allow_many = true }, req);
    // Drained -- a second take returns null, doesn't repeat the same request.
    try std.testing.expectEqual(@as(?WidgetHost.PendingFileDialogRequest, null), runtime.widgets.takePendingFileDialogRequest(io));

    // A second queue before the first is drained just overwrites -- same
    // "no ordering guarantee needed" reasoning queueScrollIntoView already
    // established, and realistic use only ever has one dialog open at a
    // time regardless (see the field's own doc comment).
    runtime.widgets.queueFileDialogRequest(io, .{ .kind = .open, .widget_id = 1, .allow_many = false });
    runtime.widgets.queueFileDialogRequest(io, .{ .kind = .save, .widget_id = 2, .allow_many = false });
    const second = runtime.widgets.takePendingFileDialogRequest(io) orelse return error.MissingRequest;
    try std.testing.expectEqual(WidgetHost.PendingFileDialogRequest{ .kind = .save, .widget_id = 2, .allow_many = false }, second);
}

test "Scroll-into-view: ClayLayout.applyScrollIntoView scrolls an off-screen child into view, is a no-op on an already-visible one, and its correction is picked up by the next real layout pass" {
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
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    // A fixed 200x100 scroll_vertical container holding 3 fixed-60-tall
    // children (180px of content, 80px of overflow) -- same "known,
    // predictable geometry" shape the W2 scroll tests already establish,
    // just built directly rather than through a compiled guest.
    const scroll_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(100) },
        .direction = c.CLAY_TOP_TO_BOTTOM,
        .scroll_vertical = true,
    }) orelse return error.RegistryFull;
    var child_ids: [3]u32 = undefined;
    for (0..3) |i| {
        child_ids[i] = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, scroll_id, .{
            .sizing = .{ .width = fixedAxis(200), .height = fixedAxis(60) },
        }) orelse return error.RegistryFull;
    }

    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    // Child 3 (y:[120,180]) starts entirely below the 100px-tall viewport --
    // sanity check the geometry prediction before trusting the assertions
    // below on it.
    var snap: [8]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == child_ids[2]) try std.testing.expectApproxEqAbs(@as(f32, 120), slot.widget.container.rect.y, 0.5);
    }

    ClayLayout.applyScrollIntoView(snap[0..n], &runtime.widgets, child_ids[2]);
    // Clamped to exactly -80 (content_h 180 - container_h 100), not merely
    // "moved some amount" -- same clamp-exactness discipline the W2 scroll
    // test above already holds itself to.
    var sd = clay_layout.scrollContainerData(scroll_id) orelse return error.MissingScrollData;
    try std.testing.expectApproxEqAbs(@as(f32, -80), sd.scroll_offset_y, 0.5);

    // The correction is live in Clay's own storage immediately, but `.rect`
    // is only a snapshot as of the last real recompute -- a second real
    // pass (forced by the layout_generation bump applyScrollIntoView just
    // made) must pick it up.
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == child_ids[2]) try std.testing.expectApproxEqAbs(@as(f32, 40), slot.widget.container.rect.y, 0.5);
    }

    // Child 3 (now at y:[40,100], exactly filling the rest of the scrolled
    // viewport) is already fully visible -- calling applyScrollIntoView on
    // it *again* must be a genuine no-op, not "helpfully" re-center it or
    // reset the scroll position. (Child 1, by contrast, just scrolled
    // *out* of view above the fold as a direct consequence of the scroll
    // above -- a 100px viewport can't show all 180px of content at once --
    // so it's not a valid "already visible" case to test here.)
    ClayLayout.applyScrollIntoView(snap[0..n], &runtime.widgets, child_ids[2]);
    sd = clay_layout.scrollContainerData(scroll_id) orelse return error.MissingScrollData;
    try std.testing.expectApproxEqAbs(@as(f32, -80), sd.scroll_offset_y, 0.5);
}

test "Scroll-into-view: natyv_get_scroll_position's Slot.scroll_data mirror matches ClayLayout.scrollContainerData's own live read, through a real compiled guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 600, 200, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    // Same fixture geometry/mouse-position prediction the W2 scroll tests
    // above already establish and trust: the nested scroll container sits
    // at x:[686,886], y:[0,100] in a 600x200 window with the mouse at
    // (786,50) -- W23's right-column change shifted this from its old
    // x:[300,500]/mouse(400,50), see those tests' own doc comments. Frame 1
    // registers the pointer over it; frame 2's -1000 vertical delta clamps
    // to the container's real -100px of overflow.
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 786, 50, false, 0, 0, &scroll_scratch, null);
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 600, 200, 786, 50, false, 0, -1000, &scroll_scratch, null);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    var scroll_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget != .container or slot.parent_id != null) continue;
        for (snap[0..n]) |maybe_child| {
            if (maybe_child.parent_id) |pid| {
                if (pid == slot.id and maybe_child.widget == .label and std.mem.eql(u8, maybe_child.widget.label.text(), "Scroll Row 1")) {
                    scroll_id = slot.id;
                }
            }
        }
    }
    const scid = scroll_id orelse return error.MissingScrollContainer;

    const live = clay_layout.scrollContainerData(scid) orelse return error.MissingScrollData;
    var mirrored: ?ScrollBar.Data = null;
    for (snap[0..n]) |slot| {
        if (slot.id == scid) mirrored = slot.scroll_data;
    }
    const m = mirrored orelse return error.MissingMirroredScrollData;

    // The mirror `natyv_get_scroll_position` actually reads must match
    // Clay's own live truth exactly -- not just "close," since both were
    // captured from the very same real recompute above.
    try std.testing.expectApproxEqAbs(live.scroll_offset_y, m.scroll_offset_y, 0.01);
    try std.testing.expectApproxEqAbs(live.container_h, m.container_h, 0.01);
    try std.testing.expectApproxEqAbs(live.content_h, m.content_h, 0.01);
    // And confirms the real clamp this mirror must also reflect: -100, not
    // an unclamped -1000.
    try std.testing.expectApproxEqAbs(@as(f32, -100), m.scroll_offset_y, 0.5);
}

test "Scroll-into-view: clicking an off-screen Accordion header through a real compiled guest scrolls its section into view" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    var font_cap = try Font.init();
    defer font_cap.deinit();
    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var header1_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "> Specs")) header1_id = slot.id;
    }
    const h1 = header1_id orelse return error.MissingHeader1;

    // Find "Specs"' own nearest scroll_vertical ancestor by walking its
    // parent_id chain -- the same walk applyScrollIntoView itself does
    // (rather than a separate "any top-level scroll container" scan, which
    // would wrongly match every other real scroll container this fixture's
    // many other demos also declare, e.g. the W2/W16 nested ones).
    var header1_slot: ?WidgetHost.Slot = null;
    for (snap[0..n]) |slot| {
        if (slot.id == h1) header1_slot = slot;
    }
    var root_id: ?u32 = null;
    var current: ?u32 = (header1_slot orelse return error.MissingHeader1).parent_id;
    while (current) |pid| {
        var parent: ?WidgetHost.Slot = null;
        for (snap[0..n]) |slot| {
            if (slot.id == pid) parent = slot;
        }
        const p = parent orelse break;
        if (p.clay_style.scroll_vertical) {
            root_id = p.id;
            break;
        }
        current = p.parent_id;
    }
    const rid = root_id orelse return error.MissingRootScrollContainer;

    var root_rect: c.SDL_FRect = undefined;
    var header_rect: c.SDL_FRect = undefined;
    for (snap[0..n]) |slot| {
        if (slot.id == rid) root_rect = slot.widget.container.rect;
        if (slot.id == h1) header_rect = slot.widget.button.rect;
    }
    // Regression-proof setup check: this fixture has 16+ milestones' worth
    // of demo content stacked above the Accordion section inside a fixed
    // 640px-tall scroll viewport -- the "Specs" header must genuinely start
    // below the fold at the default scroll position, not merely assumed to.
    try std.testing.expect(header_rect.y > root_rect.y + root_rect.h);

    const scroll_before = clay_layout.scrollContainerData(rid) orelse return error.MissingScrollData;

    var dispatch_buf: [256]u8 = undefined;
    const payload = try buildDispatchEnvelope(&dispatch_buf, h1, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;

    // Same ordering `main.zig`'s real per-frame loop uses: a real layout
    // pass first (picks up SetVisible's layout_generation bump, resolving
    // "Specs"' content to its real, now-visible rect), then drain and apply
    // whatever scroll-into-view request the click's dispatch handler queued.
    _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
    n = runtime.widgets.snapshot(io, &snap);
    if (runtime.widgets.takePendingScrollIntoView(io)) |wid| {
        ClayLayout.applyScrollIntoView(snap[0..n], &runtime.widgets, wid);
    } else {
        return error.NoScrollIntoViewQueued;
    }

    const scroll_after = clay_layout.scrollContainerData(rid) orelse return error.MissingScrollData;
    // The real regression proof: the click didn't just reveal the content
    // (already covered by the plain Accordion Pattern B test above), it
    // also actually moved the viewport -- not left it clipped off-screen,
    // which is the bug Quinn's own click-through caught.
    try std.testing.expect(scroll_after.scroll_offset_y != scroll_before.scroll_offset_y);
}

test "Tree view: a real click expands a root and reveals children while collapsed siblings stay unassigned to any pool row, another click moves selection to a leaf, and a real .scroll event slides the pool's window" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    // Nothing is Expanded at init -- flatten() returns just the 3 category
    // roots (Fruits/Vegetables/Grains). Tree's row pool is a fixed 6 real
    // Buttons (viewportHeight/rowHeight + 2 overscan, created once and
    // never destroyed -- see tree.go's own doc comment), so all 6 already
    // exist as widgets regardless of content -- but only 3 of them are
    // populated with a real node's label and set visible; the other 3 sit
    // hidden with their original empty label, never having been assigned
    // any of the tree's 18 total nodes.
    var fruits_id: ?u32 = null;
    var apple_seen_at_init = false;
    for (snap[0..n]) |slot| {
        if (slot.widget != .button) continue;
        const label = slot.widget.button.label();
        if (std.mem.eql(u8, label, "> Fruits")) fruits_id = slot.id;
        if (std.mem.indexOf(u8, label, "Apple") != null) apple_seen_at_init = true;
    }
    const fid = fruits_id orelse return error.MissingFruitsRoot;
    try std.testing.expect(!apple_seen_at_init);

    // Real guest-routed click (a real `.click` event, exactly as a real
    // mouse click dispatches -- same convention as the Accordion click test
    // above). Fruits has children, so this both expands and selects it --
    // Tree's own OnClick always sets selection regardless of whether the
    // node has children (see tree.go), so the row becomes "* v Fruits", not
    // just "v Fruits".
    var dispatch_buf: [256]u8 = undefined;
    var payload = try buildDispatchEnvelope(&dispatch_buf, fid, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var expanded_and_selected_fruits_seen = false;
    var apple_id: ?u32 = null;
    var viewport_id: ?u32 = null;
    var vegetables_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget != .button) continue;
        const label = slot.widget.button.label();
        if (std.mem.eql(u8, label, "* v Fruits")) expanded_and_selected_fruits_seen = true;
        if (std.mem.eql(u8, label, "    Apple")) {
            apple_id = slot.id;
            viewport_id = slot.parent_id;
        }
        if (std.mem.indexOf(u8, label, "Vegetables") != null) vegetables_seen = true;
    }
    // Expanding Fruits grows the flattened list to 8 rows (3 roots + 5
    // children), but the fixed 120px-tall/28px-row pool only holds 6 rows
    // at once -- Vegetables and Grains aren't assigned to any pool row at
    // all right now, not just visually clipped -- the real proof this is
    // virtualized, not an Accordion-style show/hide of widgets that already
    // exist for every node.
    try std.testing.expect(expanded_and_selected_fruits_seen);
    try std.testing.expect(!vegetables_seen);
    const aid = apple_id orelse return error.MissingAppleChild;
    const vpid = viewport_id orelse return error.MissingViewportParent;

    // A second real click, on a leaf this time -- moves selection without
    // touching Fruits' own Expanded state, proving OnClick's `len(n.
    // Children) > 0` guard actually gates the expand half independently of
    // the always-runs selection half.
    payload = try buildDispatchEnvelope(&dispatch_buf, aid, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var fruits_still_expanded_not_selected = false;
    var apple_marked = false;
    var selected_label_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "v Fruits")) fruits_still_expanded_not_selected = true;
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "*     Apple")) apple_marked = true;
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Selected: Apple")) selected_label_seen = true;
    }
    try std.testing.expect(fruits_still_expanded_not_selected);
    try std.testing.expect(apple_marked);
    try std.testing.expect(selected_label_seen);

    // Real `.scroll` event targeting the viewport itself, with the exact
    // payload shape main.zig's own post-layout push builds (see the
    // `.scroll` EventQueue.EventType's own doc comment) -- scrolled down 2
    // rows' worth. Proves Tree's real internal.RegisterScroll wiring
    // re-renders the window on a live host-detected scroll, not just on its
    // own row clicks.
    payload = try buildDispatchEnvelope(&dispatch_buf, vpid, "scroll", "{\"scroll_offset_x\":0,\"scroll_offset_y\":-56}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var apple_gone = true;
    var vegetables_now_seen = false;
    var grains_now_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget != .button) continue;
        const label = slot.widget.button.label();
        if (std.mem.indexOf(u8, label, "Apple") != null) apple_gone = false;
        if (std.mem.indexOf(u8, label, "Vegetables") != null) vegetables_now_seen = true;
        if (std.mem.indexOf(u8, label, "Grains") != null) grains_now_seen = true;
    }
    try std.testing.expect(apple_gone);
    try std.testing.expect(vegetables_now_seen);
    try std.testing.expect(grains_now_seen);
}

test "Table view: real header labels and row-1 cell content exist right after init, a real header click sorts by Name both directions, a real row click selects it, and a real .scroll event slides the pool's window" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    // The direct check against a real "the table looked empty" report: a
    // real cell Label with row 0's unsorted Name ("Widget A", the demo
    // data's own first entry) must exist right after natyv_init, same as
    // the 3 header Buttons -- render(0) runs inside CreateTable itself, not
    // deferred to some later event.
    var name_header_id: ?u32 = null;
    var category_header_seen = false;
    var price_header_seen = false;
    var widget_a_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Name")) name_header_id = slot.id;
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Category")) category_header_seen = true;
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Price")) price_header_seen = true;
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Widget A")) widget_a_seen = true;
    }
    const name_hid = name_header_id orelse return error.MissingNameHeader;
    try std.testing.expect(category_header_seen);
    try std.testing.expect(price_header_seen);
    try std.testing.expect(widget_a_seen);

    // Real guest-routed click on the "Name" header -- sorts ascending
    // (Go's plain byte-wise string `<`, so "Adapter" -- the alphabetical
    // minimum among the demo's 30 names, hand-verified against the real
    // dataset in main.go, not assumed -- must land in the pool's very
    // first slot).
    var dispatch_buf: [256]u8 = undefined;
    var payload = try buildDispatchEnvelope(&dispatch_buf, name_hid, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var name_header_ascending = false;
    var adapter_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Name ^")) name_header_ascending = true;
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Adapter")) adapter_seen = true;
    }
    try std.testing.expect(name_header_ascending);
    try std.testing.expect(adapter_seen);

    // A second click on the same header toggles to descending -- "Wrench"
    // (the alphabetical maximum) now lands first, "Tape Measure" (6th from
    // the end, exactly the pool's own 6-row capacity) is the last row
    // still inside the window, and "Sensor Kit" (7th from the end) is
    // *not* -- the real proof this is virtualized, not just re-sorted in
    // place with everything still materialized.
    payload = try buildDispatchEnvelope(&dispatch_buf, name_hid, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var name_header_descending = false;
    var wrench_id: ?u32 = null;
    var viewport_id: ?u32 = null;
    var tape_measure_seen = false;
    var sensor_kit_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Name v")) name_header_descending = true;
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Wrench")) {
            wrench_id = slot.parent_id;
        }
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Tape Measure")) tape_measure_seen = true;
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Sensor Kit")) sensor_kit_seen = true;
    }
    try std.testing.expect(name_header_descending);
    try std.testing.expect(tape_measure_seen);
    try std.testing.expect(!sensor_kit_seen);
    const wid = wrench_id orelse return error.MissingWrenchRow;

    // Find the row Button's own viewport parent (needed for the real
    // `.scroll` dispatch below) by walking up from the row Button itself,
    // same technique the Tree test above already uses.
    for (snap[0..n]) |slot| {
        if (slot.id == wid) viewport_id = slot.parent_id;
    }
    const vpid = viewport_id orelse return error.MissingViewportParent;

    // A real click on the row currently showing "Wrench" -- selects it,
    // marking the first cell and mirroring into the status Label, same
    // "* " marker + mirrored-label precedent Tree's own selection already
    // established.
    payload = try buildDispatchEnvelope(&dispatch_buf, wid, "click", "");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var wrench_marked = false;
    var selected_label_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "* Wrench")) wrench_marked = true;
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Table selected: Wrench")) selected_label_seen = true;
    }
    try std.testing.expect(wrench_marked);
    try std.testing.expect(selected_label_seen);

    // Real `.scroll` event on the body viewport -- scrolled down 6 rows'
    // worth (the pool's own full capacity), so the entire previous window
    // scrolls out. "Wrench"/"Tape Measure" (the old window's first/last
    // rows) must both be gone, "Sensor Kit" (previously just outside the
    // window) and "Pliers" (the new window's own last row, 12th from the
    // end) must both now be present.
    payload = try buildDispatchEnvelope(&dispatch_buf, vpid, "scroll", "{\"scroll_offset_x\":0,\"scroll_offset_y\":-144}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    // Exact match, not substring -- a scrolled-out-but-still-selected row's
    // marker never appears anywhere once it isn't populated into any pool
    // slot, but the mirrored status Label itself still legitimately reads
    // "Table selected: Wrench" (selection is sticky across scrolling, same as
    // Tree's own selected node staying selected while off-window) --
    // substring-matching "Wrench" against every Label would false-positive
    // on that status Label and was the actual bug here, not Table itself
    // (confirmed by temporarily dumping every Label's id/parent/text: the
    // real cell content was already correct -- Sensor Kit through Pliers,
    // no "Wrench" cell anywhere).
    var wrench_gone = true;
    var tape_measure_gone = true;
    var sensor_kit_now_seen = false;
    var pliers_now_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget != .label) continue;
        const text = slot.widget.label.text();
        if (std.mem.eql(u8, text, "Wrench") or std.mem.eql(u8, text, "* Wrench")) wrench_gone = false;
        if (std.mem.eql(u8, text, "Tape Measure")) tape_measure_gone = false;
        if (std.mem.eql(u8, text, "Sensor Kit")) sensor_kit_now_seen = true;
        if (std.mem.eql(u8, text, "Pliers")) pliers_now_seen = true;
    }
    try std.testing.expect(wrench_gone);
    try std.testing.expect(tape_measure_gone);
    try std.testing.expect(sensor_kit_now_seen);
    try std.testing.expect(pliers_now_seen);
}

test "File picker: a real .file_selected event reaches OnFileSelected for the right trigger and updates the mirrored status Label, and an empty paths array reads as cancelled" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    // Two real trigger Buttons exist right after natyv_init -- this demo
    // never opens a real dialog itself (that's SDL/main.zig's job, not
    // something a Zig-level unit test can safely trigger), only registers
    // OnFileSelected against each trigger's own widget id up front.
    var choose_file_id: ?u32 = null;
    var save_as_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget != .button) continue;
        const label = slot.widget.button.label();
        if (std.mem.eql(u8, label, "Choose File")) choose_file_id = slot.id;
        if (std.mem.eql(u8, label, "Save As")) save_as_id = slot.id;
    }
    const cid = choose_file_id orelse return error.MissingChooseFileButton;
    const sid = save_as_id orelse return error.MissingSaveAsButton;

    // Real guest-routed `.file_selected` event, exactly the payload shape
    // `fileDialogCallback` (main.zig) builds from a real SDL result --
    // targeting the "Choose File" trigger's own widget id, same as a real
    // dialog result would.
    var dispatch_buf: [256]u8 = undefined;
    var payload = try buildDispatchEnvelope(&dispatch_buf, cid, "file_selected", "{\"paths\":[\"/tmp/example.txt\"]}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var open_status_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Open: example.txt")) open_status_seen = true;
    }
    try std.testing.expect(open_status_seen);

    // An empty paths array (cancelled dialog, or a real host-side error --
    // the wire contract doesn't distinguish the two, see EventQueue.
    // EventType's own doc comment) targeting the *other* trigger -- real
    // proof the event actually routes by widget id, not just whichever
    // handler happened to run last (both triggers mirror into the same
    // shared status Label, so this also overwrites the "Open: ..." text
    // from above -- expected, not a bug, same single-shared-status-line
    // convention every other demo section's own mirrored label uses).
    payload = try buildDispatchEnvelope(&dispatch_buf, sid, "file_selected", "{\"paths\":[]}");
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);

    var save_cancelled_seen = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.eql(u8, slot.widget.label.text(), "Save: cancelled")) save_cancelled_seen = true;
    }
    try std.testing.expect(save_cancelled_seen);
}

test "Multi-window Stage 2: two ClayLayout instances alive at once don't clobber each other's Clay context" {
    // Real regression catcher for the bug this stage fixes: `ClayLayout.init`
    // used to discard `Clay_Initialize`'s real context handle entirely, and
    // neither `layoutIfNeeded` nor `scrollContainerData` ever called
    // `Clay_SetCurrentContext` to select a specific instance -- silently
    // correct only because exactly one `ClayLayout` had ever existed in the
    // process. This creates two, back-to-back, and interleaves real layout
    // passes on both -- provable *before* main.zig ever runs two at once
    // (that's Stage 3). If context switching were still missing, running
    // instance B's own Clay_BeginLayout/EndLayout in between A's two passes
    // would corrupt or misattribute A's own state (Clay's "current context"
    // is process-global C state), showing up here as A's geometry silently
    // becoming wrong or Clay's own error handler firing after B runs.
    //
    // Deliberately synthetic widgets (`insertWithLayout`, same pattern the
    // W16 flip tests above already use), not the real clay-fixture wasm --
    // a single GROW-width child with no siblings is a known, deterministic
    // relationship to whatever window_w gets passed, unlike the real app's
    // widgets (e.g. "Grow Button" lives inside a *fixed*-width 300px
    // column, so varying window_w wouldn't move it at all and would prove
    // nothing either way -- caught by this test's own first draft actually
    // failing that comparison, not by inspection).
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime_a = try Runtime.init(allocator, null);
    defer runtime_a.deinit();
    var runtime_b = try Runtime.init(allocator, null);
    defer runtime_b.deinit();

    var font_cap = try Font.init();
    defer font_cap.deinit();

    // Different widths (300 vs 600) so a real mixup between the two
    // instances is directly observable -- a lone GROW-width child of the
    // synthetic root has no siblings/fixed-width ancestors to absorb the
    // extra space, so it must track window_w exactly.
    var clay_layout_a = try ClayLayout.init(allocator, 300, 100, font_cap.font);
    defer clay_layout_a.deinit(allocator);
    var clay_layout_b = try ClayLayout.init(allocator, 600, 100, font_cap.font);
    defer clay_layout_b.deinit(allocator);

    const grow_axis: c.Clay_Sizing = .{ .width = .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = 0, .max = std.math.floatMax(f32) } } }, .height = fixedAxis(50) };
    const child_a_id = runtime_a.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = grow_axis,
    }) orelse return error.RegistryFull;
    const child_b_id = runtime_b.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) }, null, .{
        .sizing = grow_axis,
    }) orelse return error.RegistryFull;

    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    // Interleaved on purpose -- A, then B, then A again -- so any state
    // leakage between the two would have a chance to show up on A's second
    // pass, not just on whichever instance happened to run last.
    _ = clay_layout_a.layoutIfNeeded(&runtime_a.widgets, io, 300, 100, 0, 0, false, 0, 0, &scroll_scratch, null);
    _ = clay_layout_b.layoutIfNeeded(&runtime_b.widgets, io, 600, 100, 0, 0, false, 0, 0, &scroll_scratch, null);
    _ = clay_layout_a.layoutIfNeeded(&runtime_a.widgets, io, 300, 100, 0, 0, false, 0, 0, &scroll_scratch, null);

    var snap_a: [8]WidgetHost.Slot = undefined;
    const n_a = runtime_a.widgets.snapshot(io, &snap_a);
    var width_a: ?f32 = null;
    for (snap_a[0..n_a]) |slot| {
        if (slot.id == child_a_id) width_a = slot.widget.container.rect.w;
    }
    const rect_a_w = width_a orelse return error.MissingChildA;

    var snap_b: [8]WidgetHost.Slot = undefined;
    const n_b = runtime_b.widgets.snapshot(io, &snap_b);
    var rect_b_w: ?f32 = null;
    for (snap_b[0..n_b]) |slot| {
        if (slot.id == child_b_id) rect_b_w = slot.widget.container.rect.w;
    }
    const width_b = rect_b_w orelse return error.MissingChildB;

    // A's third pass (run *after* B's real Clay_BeginLayout/EndLayout ran
    // in between) still tracked its own 300px window, not B's 600px one or
    // some corrupted mix of the two -- and B independently tracked its own.
    try std.testing.expectApproxEqAbs(@as(f32, 300), rect_a_w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 600), width_b, 0.01);
}

// Multi-window Stage 4: the fixture guest's own "CreateWindowTest"/
// "DestroyWindowTest" natyv_test_hook cases (see clay-fixture/guest/main.go's
// own doc comment on them) exist purely so these two tests can exercise
// natyv_clay_create_window/natyv_destroy_window through a real compiled
// guest -- real JSON over real guest memory (host_fn_util.readGuestBytes/
// writeGuestBytes need a real ExtismCurrentPlugin*, which only exists during
// an actual plugin call), not a hand-constructed Extism call a host-side-only
// unit test could fake. No sdk/go/widgets/window.go wrapper exists yet
// (that's Stage 5) -- the fixture declares its own minimal
// //go:wasmimport natyv_clay_create_window/natyv_destroy_window instead,
// same low-level shape every real sdk/go/widgets/*.go file already uses.
const CreateWindowTestResponse = struct { widget_id: u32, child_id: u32 };

test "Multi-window Stage 4: natyv_clay_create_window returns a usable widget_id immediately, and its subtree resolves through FloatingOrder like any other window" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    const resp_bytes = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"CreateWindowTest\"}") orelse return error.CallFailed;
    const parsed = try std.json.parseFromSlice(CreateWindowTestResponse, allocator, resp_bytes, .{});
    defer parsed.deinit();
    const window_id = parsed.value.widget_id;
    const child_id = parsed.value.child_id;

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);

    var window_slot: ?WidgetHost.Slot = null;
    var child_slot: ?WidgetHost.Slot = null;
    for (snap[0..n]) |slot| {
        if (slot.id == window_id) window_slot = slot;
        if (slot.id == child_id) child_slot = slot;
    }
    const ws = window_slot orelse return error.MissingWindow;
    const cs = child_slot orelse return error.MissingChild;

    // The window_root marker flag round-tripped, `parent_id` is always
    // null (a real OS window can't be a Clay child), and sizing was forced
    // to Fixed(400, 300) -- the fixture's own createWindowTest request
    // values, see main.go's own doc comment on the test-hook case.
    try std.testing.expect(ws.clay_style.window_root);
    try std.testing.expectEqual(@as(?u32, null), ws.parent_id);
    try std.testing.expectEqual(c.CLAY__SIZING_TYPE_FIXED, ws.clay_style.sizing.width.type);
    try std.testing.expectApproxEqAbs(@as(f32, 400), ws.clay_style.sizing.width.size.minMax.min, 0.01);
    try std.testing.expectEqual(c.CLAY__SIZING_TYPE_FIXED, ws.clay_style.sizing.height.type);
    try std.testing.expectApproxEqAbs(@as(f32, 300), ws.clay_style.sizing.height.size.minMax.min, 0.01);

    // The child button was parented under the window's own widget_id --
    // proves a guest can parent children onto a just-created window
    // immediately, before the real OS window has even materialized on the
    // main thread (that only happens once main.zig's frame loop drains
    // WidgetHost.pending_window_requests, which never runs in this
    // headless test at all).
    try std.testing.expectEqual(@as(?u32, window_id), cs.parent_id);

    // surface_id resolution: FloatingOrder.surfaceIdFor recognizes
    // window_root the same way it already recognizes modal -- the window's
    // own widget_id is its own surface_id, and its child's surface_id
    // resolves to the same window, not 0 (root/main surface).
    const surface_index = WidgetHost.SnapshotIndex.build(snap[0..n]);
    try std.testing.expectEqual(window_id, FloatingOrder.surfaceIdFor(snap[0..n], surface_index, window_id));
    try std.testing.expectEqual(window_id, FloatingOrder.surfaceIdFor(snap[0..n], surface_index, child_id));

    // windowSubset returns exactly this window's own root + child, nothing
    // from the fixture's own baseline (original-window) content.
    var subset_ids: [WidgetHost.max_widgets]u32 = undefined;
    const subset_n = FloatingOrder.windowSubset(snap[0..n], window_id, &subset_ids);
    try std.testing.expectEqual(@as(usize, 2), subset_n);
    try std.testing.expect(std.mem.indexOfScalar(u32, subset_ids[0..subset_n], window_id) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, subset_ids[0..subset_n], child_id) != null);
}

test "Multi-window Stage 4: natyv_destroy_window cascades to the whole window subtree, mirroring destroyWindowSubtree's own contract" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);

    const create_resp = runtime.call(io, "natyv_test_hook", "{\"widget_id\":0,\"event_type\":\"CreateWindowTest\"}") orelse return error.CallFailed;
    const parsed = try std.json.parseFromSlice(CreateWindowTestResponse, allocator, create_resp, .{});
    defer parsed.deinit();
    const window_id = parsed.value.widget_id;
    const child_id = parsed.value.child_id;

    var before_snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    const before_n = runtime.widgets.snapshot(io, &before_snap);

    var buf: [64]u8 = undefined;
    const destroy_payload = try std.fmt.bufPrint(&buf, "{{\"widget_id\":{d},\"event_type\":\"DestroyWindowTest\"}}", .{window_id});
    _ = runtime.call(io, "natyv_test_hook", destroy_payload) orelse return error.CallFailed;

    var after_snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    const after_n = runtime.widgets.snapshot(io, &after_snap);

    // Exactly the window's own root + its one child are gone -- nothing
    // else in the registry (the fixture's own large baseline content) was
    // touched, same "narrowly-scoped cascade" contract destroyWindowSubtree
    // documents for itself.
    try std.testing.expectEqual(before_n - 2, after_n);
    for (after_snap[0..after_n]) |slot| {
        try std.testing.expect(slot.id != window_id);
        try std.testing.expect(slot.id != child_id);
    }
}

test "Multi-window Stage 4: a synthetic .window_close_requested event round-trips through EventQueue like any other discrete event" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    // Discrete, not coalesced -- pushing it twice for the same widget_id
    // must leave both entries queued, same "every request matters" reasoning
    // .dismiss already established (see EventType's own doc comment).
    queue.push(io, 7, .window_close_requested, "", 7);
    queue.push(io, 7, .window_close_requested, "", 7);

    const first = queue.pop(io) orelse return error.MissingEvent;
    defer queue.freeEntry(first);
    try std.testing.expectEqual(@as(u32, 7), first.widget_id);
    try std.testing.expectEqual(EventQueue.EventType.window_close_requested, first.event_type);
    try std.testing.expectEqualStrings("", first.payload);
    try std.testing.expectEqual(@as(u32, 7), first.surface_id);

    const second = queue.pop(io) orelse return error.MissingEvent;
    defer queue.freeEntry(second);
    try std.testing.expectEqual(EventQueue.EventType.window_close_requested, second.event_type);
}

// Follow-up coverage for the `findLocked`/`destroyWidgetHostFn` crash fix
// above, from a different, more realistic angle: a real nested Menu ->
// submenu selection (Close() destroys the submenu items+panel, then the
// top-level items+panel, then the guest's OnSelect handler runs) under the
// exact real conditions that originally caught the crash -- a real worker
// thread running `natyv_dispatch` concurrently with a real `layoutIfNeeded`
// writeback loop on this thread. Prompted by Quinn's own real click-through
// report of the selection seemingly "not saving" after the crash fix landed
// -- this test (plus a plain synchronous version tried first) couldn't
// reproduce that, and Quinn's own follow-up suggested it was likely just
// not looking at the right label initially, not a real regression. Kept as
// permanent coverage regardless: it's real, valuable proof that a multi-
// widget destroy cascade followed by a cross-widget `SetText` survives the
// exact race the earlier crash needed, not just a single destroy in
// isolation.
test "Menu: a nested submenu selection destroys both panel levels and still delivers OnSelect correctly under real concurrent dispatch + layout" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("menu-diag-test", 900, 700, c.SDL_WINDOW_HIDDEN) orelse return error.SdlWindowFailed;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    const engine = c.TTF_CreateRendererTextEngine(renderer) orelse return error.TextEngineFailed;
    defer c.TTF_DestroyRendererTextEngine(engine);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    var clay_layout = try ClayLayout.init(allocator, 900, 700, font_cap.font);
    defer clay_layout.deinit(allocator);

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    var snap: [WidgetHost.max_widgets]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var trigger_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Menu")) trigger_id = slot.id;
    }
    const tid = trigger_id orelse return error.MissingTrigger;

    var queue = EventQueue.init(allocator);
    defer queue.deinit();
    var scroll_scratch: [WidgetHost.max_widgets]u32 = undefined;

    // Real second OS thread, same call main.zig itself makes -- matches
    // Quinn's own real report exactly: destroy+create+SetText all happen on
    // this thread's `natyv_dispatch`, concurrently with the "frame loop"
    // below's own `layoutIfNeeded` writeback (the exact function the
    // earlier real crash raced against).
    const worker = try std.Thread.spawn(.{}, Dispatch.run, .{ &runtime, io, &queue });

    queue.push(io, tid, .click, "", 0);

    var more_id: ?u32 = null;
    var i: u32 = 0;
    while (i < 500 and more_id == null) : (i += 1) {
        runtime.widgets.flushPendingTextDestroys(io);
        var sync_ids: [WidgetHost.max_widgets]u32 = undefined;
        n = runtime.widgets.snapshot(io, &snap);
        for (snap[0..n], 0..) |s, si| sync_ids[si] = s.id;
        runtime.widgets.syncTextObjects(io, engine, font_cap.font, sync_ids[0..n]);
        _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
        n = runtime.widgets.snapshot(io, &snap);
        for (snap[0..n]) |slot| {
            if (slot.widget == .button and std.mem.indexOf(u8, slot.widget.button.label(), "More") != null) more_id = slot.id;
        }
        if (more_id == null) try io.sleep(.fromMilliseconds(2), .awake);
    }
    const mid = more_id orelse return error.MissingMore;

    queue.push(io, mid, .click, "", 0);

    var sub_a_id: ?u32 = null;
    i = 0;
    while (i < 500 and sub_a_id == null) : (i += 1) {
        runtime.widgets.flushPendingTextDestroys(io);
        var sync_ids: [WidgetHost.max_widgets]u32 = undefined;
        n = runtime.widgets.snapshot(io, &snap);
        for (snap[0..n], 0..) |s, si| sync_ids[si] = s.id;
        runtime.widgets.syncTextObjects(io, engine, font_cap.font, sync_ids[0..n]);
        _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
        n = runtime.widgets.snapshot(io, &snap);
        for (snap[0..n]) |slot| {
            if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Sub A")) sub_a_id = slot.id;
        }
        if (sub_a_id == null) try io.sleep(.fromMilliseconds(2), .awake);
    }
    const said = sub_a_id orelse return error.MissingSubA;

    queue.push(io, said, .click, "", 0);

    var final_text: [64]u8 = undefined;
    var final_len: usize = 0;
    i = 0;
    while (i < 500) : (i += 1) {
        runtime.widgets.flushPendingTextDestroys(io);
        var sync_ids: [WidgetHost.max_widgets]u32 = undefined;
        n = runtime.widgets.snapshot(io, &snap);
        for (snap[0..n], 0..) |s, si| sync_ids[si] = s.id;
        runtime.widgets.syncTextObjects(io, engine, font_cap.font, sync_ids[0..n]);
        _ = clay_layout.layoutIfNeeded(&runtime.widgets, io, 900, 700, 0, 0, false, 0, 0, &scroll_scratch, null);
        n = runtime.widgets.snapshot(io, &snap);
        for (snap[0..n]) |slot| {
            if (slot.widget == .label and std.mem.startsWith(u8, slot.widget.label.text(), "Menu selected:")) {
                const t = slot.widget.label.text();
                final_len = @min(t.len, final_text.len);
                @memcpy(final_text[0..final_len], t[0..final_len]);
            }
        }
        if (std.mem.eql(u8, final_text[0..final_len], "Menu selected: More > Sub A")) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    try std.testing.expectEqualStrings("Menu selected: More > Sub A", final_text[0..final_len]);

    queue.requestShutdown(io);
    worker.join();
}
