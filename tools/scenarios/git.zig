//! Git change gutter end-to-end: add/change/delete signs render in their
//! colours. Port of tools/git_test.py. Sets up a real git repo in a temp dir,
//! commits a file, makes a working-tree change, opens zedit, and checks the
//! rendered output for the sign colours. Uses .txt files so the only colours
//! present come from the git gutter (no syntax highlighting).

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";

// theme.zig gutter colours (24-bit SGR foreground).
const ADD = "\x1b[38;2;158;206;106m"; // theme.git_add
const CHANGE = "\x1b[38;2;224;175;104m"; // theme.git_change
const DELETE = "\x1b[38;2;247;118;142m"; // theme.git_delete
const BAR = "\xe2\x94\x82"; // U+2502
const LOWBLOCK = "\xe2\x96\x81"; // U+2581

/// `:e` must put the text on screen *before* anything that only decorates it —
/// the rule the first frame follows, applied to every later open. The check is
/// on the order of bytes in the stream, not on timing: the text and the gutter
/// sign arrive in two different frames, and the sign is emitted before the text
/// on any row it shares, so seeing the text first can only mean it came in an
/// earlier frame.
fn paintBeforeDecorating(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const name = "tracked.txt";
    const file = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, name });
    defer ctx.gpa.free(file);
    const other = try std.fmt.allocPrint(ctx.gpa, "{s}/other.txt", .{dir});
    defer ctx.gpa.free(other);

    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "init", "-q" });
    h.writeFile(ctx.io, file, "alpha\nbravo\n");
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "add", name });
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "commit", "-q", "-m", "init" });
    h.writeFile(ctx.io, file, "alpha\nCHANGEDLINE\n"); // a change for the gutter
    h.writeFile(ctx.io, other, "nothing here\n");

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "other.txt" }, .cwd = dir });
    defer s.finish();
    s.drain(500);
    const from = s.mark();
    s.send(":e tracked.txt\r");
    s.drain(700);

    const stream = s.out.items[@min(from, s.out.items.len)..];
    const text = std.mem.indexOf(u8, stream, "CHANGEDLINE");
    const sign = std.mem.indexOf(u8, stream, CHANGE); // the git-change colour
    const ok = text != null and sign != null and text.? < sign.?;
    if (!ok) std.debug.print("       text at {?d}, git sign at {?d}\n", .{ text, sign });
    ctx.check(":e paints the file before decorating it", ok);
    s.send(":q!\r");
    s.drain(200);
}

/// Build a fresh repo with `committed` committed and `modified` in the working
/// tree, open zedit on the file, drain the first frames, run the checks against
/// the live session, then quit and clean up.
fn capture(
    ctx: *h.Ctx,
    committed: []const u8,
    modified: []const u8,
    name: []const u8,
    checks: []const struct { name: []const u8, present: []const []const u8, absent: []const []const u8 },
) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    const file = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, name });
    defer ctx.gpa.free(file);

    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "init", "-q" });
    h.writeFile(ctx.io, file, committed);
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "add", name });
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "commit", "-q", "-m", "init" });
    h.writeFile(ctx.io, file, modified); // working-tree change

    var s = try h.Session.spawn(ctx.gpa, .{
        .argv = &.{ ctx.zedit, name },
        .cwd = dir,
        .term = "xterm-256color",
    });
    defer s.finish();
    s.drain(1500); // no keys: just let it render

    // Run the assertions while the session is alive (it frees its bytes on finish).
    for (checks) |chk| {
        var ok = true;
        for (chk.present) |needle| ok = ok and s.contains(needle);
        for (chk.absent) |needle| ok = ok and !s.contains(needle);
        ctx.check(chk.name, ok);
    }

    s.send(ESC ++ ":q!\r");
    s.drain(300);
}

pub fn run(ctx: *h.Ctx) !void {
    try paintBeforeDecorating(ctx);

    // changed + added line
    try capture(ctx, "alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\nadded\n", "f.txt", &.{
        .{ .name = "changed line shows change sign", .present = &.{ CHANGE, BAR }, .absent = &.{} },
        .{ .name = "added line shows add sign", .present = &.{ADD}, .absent = &.{} },
    });

    // deleted line
    try capture(ctx, "one\ntwo\nthree\n", "one\nthree\n", "f.txt", &.{
        .{ .name = "deleted line shows delete sign", .present = &.{ DELETE, LOWBLOCK }, .absent = &.{} },
    });

    // unchanged file
    try capture(ctx, "same\nlines\n", "same\nlines\n", "f.txt", &.{
        .{ .name = "unchanged file shows no sign colours", .present = &.{}, .absent = &.{ CHANGE, ADD, DELETE } },
    });

    try sideFocusReadonlyToggle(ctx);
    try sideAlignment(ctx);
    try sideEdges(ctx);
    try sideLockstep(ctx);
    try sideOpenKeepsPlace(ctx);
    try sideThirdWindowFocus(ctx);
    try sideNoChanges(ctx);
    try inlineToggle(ctx);
}

// === side-by-side diff view (Space g s) =====================================

// Filler-row tints: mixColor(tokyonight bg, git colour, 25%).
const TINT_ADD = h.rgb(59, 71, 55);
const TINT_DELETE = h.rgb(81, 49, 64);

/// A fresh repo with `committed` committed and `modified` in the worktree as
/// f.txt. Caller frees the returned dir (and removes the tree).
fn diffRepo(ctx: *h.Ctx, committed: []const u8, modified: []const u8) ![]u8 {
    const dir = try h.tempDir(ctx.gpa);
    const f = h.join(ctx, dir, "f.txt");
    defer ctx.gpa.free(f);
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "init", "-q" });
    h.writeFile(ctx.io, f, committed);
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "add", "f.txt" });
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "commit", "-q", "-m", "init" });
    h.writeFile(ctx.io, f, modified);
    return dir;
}

/// How many times `needle` occurs in screen row `row`. Twice on one row means
/// the two panes show the text side by side — the alignment assertion.
fn rowCount(scr: *h.Screen, gpa: std.mem.Allocator, row: usize, needle: []const u8) usize {
    const text = scr.rowText(gpa, row) catch return 0;
    defer gpa.free(text);
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, needle)) |at| {
        n += 1;
        i = at + needle.len;
    }
    return n;
}

/// Occurrences of `needle` anywhere on the final screen.
fn screenCount(scr: *h.Screen, gpa: std.mem.Allocator, needle: []const u8) usize {
    var n: usize = 0;
    var row: usize = 1;
    while (row <= scr.rows) : (row += 1) n += rowCount(scr, gpa, row, needle);
    return n;
}

/// The current screen state: the whole captured stream replayed into a model.
fn snapshot(ctx: *h.Ctx, s: *h.Session) !h.Screen {
    var scr = try h.Screen.init(ctx.gpa, 24, 80);
    scr.apply(s.out.items);
    return scr;
}

/// Focus lands in the worktree pane (typing edits the FILE), the index pane
/// rejects edits and `:w <name>`, Space g s toggles the view closed from the
/// index pane, and :qa is never blocked by an untouched diff view.
fn sideFocusReadonlyToggle(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\nfive\nsix\n", "one\nTWO-C\nthree\nadd1\nadd2\nfour\nsix\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const f = h.join(ctx, dir, "f.txt");
    defer ctx.gpa.free(f);
    const leak = h.join(ctx, dir, "leak.txt");
    defer ctx.gpa.free(leak);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gs");
    s.drain(700);

    // The first keys after opening must land in the FILE: pin it by editing
    // and writing, then reading the file back from disk.
    s.send("x:w\r");
    s.drain(600);
    const saved = h.readFile(ctx.gpa, ctx.io, f);
    defer ctx.gpa.free(saved);
    ctx.check("side view: focus lands in the worktree pane", std.mem.startsWith(u8, saved, "ne\n"));

    // The index pane refuses edits with a message, and the text stays intact.
    s.send("\x17w"); // Ctrl-w w -> index pane
    s.drain(300);
    const m1 = s.mark();
    s.send("ix"); // insert and delete both refused (never leaves normal mode)
    s.drain(300);
    ctx.check("index pane rejects edits", s.containsPlainSince(ctx.gpa, m1, "index snapshot is read-only"));
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("index pane text is untouched", rowCount(&scr, ctx.gpa, 2, "ne") >= 2); // both panes still pair
    }

    // `:w <name>` must not write the snapshot out.
    s.send("j"); // motion: clears the previous message so the next one re-renders
    s.drain(200);
    const m2 = s.mark();
    s.send(":w leak.txt\r");
    s.drain(400);
    const leaked = h.readFile(ctx.gpa, ctx.io, leak);
    defer ctx.gpa.free(leaked);
    ctx.check("index pane refuses :w <name>", s.containsPlainSince(ctx.gpa, m2, "index snapshot is read-only") and leaked.len == 0);

    // Space g s from the index pane closes the split AND the scratch.
    s.send(" gs");
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("Space g s toggles the view closed", screenCount(&scr, ctx.gpa, "(index)") == 0);
    }

    // A third press reopens it; :qa quits without an unsaved-changes complaint.
    s.send(" gs");
    s.drain(600);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("Space g s reopens the view", screenCount(&scr, ctx.gpa, "(index)") > 0);
    }
    s.send(":qa\r");
    s.drain(500);
    ctx.check(":qa is not blocked by the diff view", s.contains("\x1b[?1049l")); // left the alt screen = clean exit
}

/// Filler rows put matching text on the same screen row in both panes: green
/// (git-add) fillers in the index pane under added lines, red (git-delete)
/// fillers in the worktree pane where lines were deleted — with a blank
/// gutter. Soft wrap is forced off in the panes (the 60-char changed line
/// would otherwise wrap and shear every row below it).
fn sideAlignment(ctx: *h.Ctx) !void {
    const long = "W" ** 60;
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\nfive\nsix\n", "one\n" ++ long ++ "\nthree\nadd1\nadd2\nfour\nsix\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gs");
    s.drain(800);

    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    // Screen rows (tab bar = 1, panes at cols 1-40 | 41-80):
    //   2 one|one  3 WWW…|two  4 three|three  5 add1|FILL  6 add2|FILL
    //   7 four|four  8 FILL|five  9 six|six
    ctx.check("common lines align across the panes", rowCount(&scr, ctx.gpa, 4, "three") == 2 and
        rowCount(&scr, ctx.gpa, 9, "six") == 2);
    ctx.check("lines after an addition re-align", rowCount(&scr, ctx.gpa, 7, "four") == 2);
    ctx.check("a changed long line stays on one row (wrap off in panes)", rowCount(&scr, ctx.gpa, 3, "WWWWW") > 0 and
        rowCount(&scr, ctx.gpa, 3, "two") == 1);

    // Pure addition: the index pane shows add-tinted fillers beside add1/add2.
    const add1_col = scr.colOf(ctx.gpa, 5, "add1");
    ctx.check("added lines sit in the worktree pane", add1_col != null and add1_col.? < 41 and
        scr.colOf(ctx.gpa, 6, "add2") != null);
    ctx.check("index pane shows add-tinted fillers", scr.at(5, 60).bg == TINT_ADD and scr.at(6, 60).bg == TINT_ADD);
    ctx.check("fillers have a blank gutter (no line number)", scr.at(5, 42).cp == ' ' and scr.at(5, 60).cp == ' ');

    // Pure deletion: the worktree pane shows a delete-tinted filler beside "five".
    const five_col = scr.colOf(ctx.gpa, 8, "five");
    ctx.check("deleted line sits in the index pane", five_col != null and five_col.? > 40);
    ctx.check("worktree pane shows a delete-tinted filler", scr.at(8, 20).bg == TINT_DELETE and scr.at(8, 20).cp == ' ');

    s.send(":qa\r");
    s.drain(300);
}

/// The panes scroll as one: Ctrl-d in the worktree pane brings a landmark
/// line into view level in BOTH panes; Ctrl-b in the index pane takes both
/// back to the top.
fn sideLockstep(ctx: *h.Ctx) !void {
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(ctx.gpa);
    var modified: std.ArrayList(u8) = .empty;
    defer modified.deinit(ctx.gpa);
    var n: usize = 1;
    while (n <= 40) : (n += 1) {
        var b: [8]u8 = undefined;
        const line = std.fmt.bufPrint(&b, "L{d:0>2}\n", .{n}) catch unreachable;
        try committed.appendSlice(ctx.gpa, line);
        if (n == 2) {
            try modified.appendSlice(ctx.gpa, "L02CHANGED\n");
        } else if (n != 5) { // L05 deleted
            try modified.appendSlice(ctx.gpa, line);
        }
        if (n == 3) try modified.appendSlice(ctx.gpa, "A1\nA2\n"); // added after L03
    }
    const dir = try diffRepo(ctx, committed.items, modified.items);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gs");
    s.drain(700);

    s.send("\x04\x04"); // Ctrl-d twice in the worktree pane: both panes scroll
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        var paired = false;
        var row: usize = 2;
        while (row <= 22) : (row += 1) {
            const c = rowCount(&scr, ctx.gpa, row, "L20");
            if (c > 0) paired = c == 2; // on screen: must be level in both panes
            if (c > 0) break;
        }
        ctx.check("Ctrl-d in the worktree pane scrolls both panes", paired);
    }

    s.send("\x17w"); // focus the index pane
    s.drain(300);
    s.send("\x02"); // Ctrl-b: page back up — the worktree pane must follow
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("Ctrl-b in the index pane scrolls both panes back", rowCount(&scr, ctx.gpa, 2, "L01") == 2 and
            screenCount(&scr, ctx.gpa, "L20") == 0);
    }
    s.send(":qa\r");
    s.drain(300);
}

/// Hunks at the file's edges: a change on line 1 and a deletion at EOF (the
/// worktree file is shorter than the window) still align, with the fillers —
/// then `~` — closing out the shorter pane.
fn sideEdges(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\nfive\nsix\n", "ONE\ntwo\nthree\nfour\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gs");
    s.drain(700);

    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    // Rows: 2 ONE|one  3-5 two/three/four  6 FILL|five  7 FILL|six  8 ~|~
    const one_wt = scr.colOf(ctx.gpa, 2, "ONE");
    const one_ix = scr.colOf(ctx.gpa, 2, "one");
    ctx.check("a hunk on line 1 aligns", one_wt != null and one_wt.? < 41 and one_ix != null and one_ix.? > 40);
    ctx.check("common lines after it stay level", rowCount(&scr, ctx.gpa, 5, "four") == 2);
    const five_col = scr.colOf(ctx.gpa, 6, "five");
    ctx.check("EOF deletion: index pane keeps its lines", five_col != null and five_col.? > 40 and
        scr.colOf(ctx.gpa, 7, "six") != null);
    ctx.check("EOF deletion: worktree pane fills to match", scr.at(6, 20).bg == TINT_DELETE and
        scr.at(7, 20).bg == TINT_DELETE);
    ctx.check("past both panes: end-of-buffer rows", scr.at(8, 1).cp == '~');

    s.send(":qa\r");
    s.drain(300);
}

/// Opening the side-by-side view keeps the cursor (and viewport) where the
/// user was — it must not yank the pair to the top of the file.
fn sideOpenKeepsPlace(ctx: *h.Ctx) !void {
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(ctx.gpa);
    var modified: std.ArrayList(u8) = .empty;
    defer modified.deinit(ctx.gpa);
    var n: usize = 1;
    while (n <= 40) : (n += 1) {
        var b: [8]u8 = undefined;
        const line = std.fmt.bufPrint(&b, "L{d:0>2}\n", .{n}) catch unreachable;
        try committed.appendSlice(ctx.gpa, line);
        try modified.appendSlice(ctx.gpa, if (n == 2) "L02CHANGED\n" else line);
    }
    const dir = try diffRepo(ctx, committed.items, modified.items);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send("G"); // bottom of the file
    s.drain(300);
    s.send(" gs");
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("opening the view keeps the cursor's place", screenCount(&scr, ctx.gpa, "L40") == 2 and
            screenCount(&scr, ctx.gpa, "L01") == 0);
    }
    // Crossing into the index pane lands on the aligned row: nothing moves.
    s.send("\x17w");
    s.drain(400);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("crossing the pair afterwards stays put", screenCount(&scr, ctx.gpa, "L40") == 2 and
            screenCount(&scr, ctx.gpa, "L01") == 0);
    }
    s.send(":qa\r");
    s.drain(300);
}

/// Entering a diff pane from a *third* window (no direct pair crossing, so no
/// cursor remap) must not yank the lockstepped pair back to the pane's stale
/// cursor row: each frame pulls the unfocused pane's bookmark into the synced
/// viewport.
fn sideThirdWindowFocus(ctx: *h.Ctx) !void {
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(ctx.gpa);
    var modified: std.ArrayList(u8) = .empty;
    defer modified.deinit(ctx.gpa);
    var n: usize = 1;
    while (n <= 40) : (n += 1) {
        var b: [8]u8 = undefined;
        const line = std.fmt.bufPrint(&b, "L{d:0>2}\n", .{n}) catch unreachable;
        try committed.appendSlice(ctx.gpa, line);
        try modified.appendSlice(ctx.gpa, if (n == 2) "L02CHANGED\n" else line);
    }
    const dir = try diffRepo(ctx, committed.items, modified.items);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const g = h.join(ctx, dir, "g.txt");
    defer ctx.gpa.free(g);
    h.writeFile(ctx.io, g, "gfile\n");

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gs"); // pair: [wt, ix]
    s.drain(700);
    s.send(":vsplit\r:e g.txt\r"); // third window between the panes
    s.drain(500);
    s.send("\x17h"); // back into the worktree pane
    s.drain(300);
    s.send("G"); // bottom: the pair lockspeps to L40
    s.drain(400);
    s.send("\x17l\x17l"); // wt -> g.txt -> ix pane (never crossing the pair)
    s.drain(400);
    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    ctx.check("focusing a pane from a third window stays put", screenCount(&scr, ctx.gpa, "L40") == 2 and
        screenCount(&scr, ctx.gpa, "L01") == 0);
    s.send(":qa\r");
    s.drain(300);
}

/// A file with no changes vs the index: a status message, never a split.
fn sideNoChanges(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "same\nlines\n", "same\nlines\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gs");
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("no changes: message, no split", s.containsPlain(ctx.gpa, "no changes") and
            screenCount(&scr, ctx.gpa, "(index)") == 0);
    }
    // A brand-new (untracked) file has no index version to compare against.
    const g = h.join(ctx, dir, "g.txt");
    defer ctx.gpa.free(g);
    h.writeFile(ctx.io, g, "brand\nnew\n");
    s.send(":e g.txt\r gs");
    s.drain(600);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("untracked file: message, no split", s.containsPlain(ctx.gpa, "not tracked by git") and
            screenCount(&scr, ctx.gpa, "(index)") == 0);
    }
    s.send(":qa\r");
    s.drain(300);
}

/// Space g d toggles the inline diff too — including from inside the diff
/// buffer itself, which has no file path of its own.
fn inlineToggle(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "alpha\nbeta\n", "alpha\nBETA\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gd");
    s.drain(600);
    ctx.check("inline diff opens", s.containsPlain(ctx.gpa, "[diff] f.txt"));

    s.send(" gd"); // focus sits in the diff scratch: still a toggle
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("Space g d toggles the inline diff closed", screenCount(&scr, ctx.gpa, "[diff]") == 0);
    }
    s.send(" gd"); // and from the file it reopens
    s.drain(600);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("Space g d reopens the inline diff", screenCount(&scr, ctx.gpa, "[diff]") > 0);
    }
    s.send(":qa\r");
    s.drain(300);
}
