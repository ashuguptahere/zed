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

/// The wheel scrolls the *viewport*, so its step must count every screen row
/// the renderer draws — a woven old line and a diff pair's filler included.
/// Counting buffer lines instead made a notch that crossed a hunk travel a
/// different distance than one that did not: the view leapt, which is what
/// "jumping around lines when scrolling past a change" was.
fn wheelOverVirtualRows(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const f = try std.fmt.allocPrint(ctx.gpa, "{s}/f.txt", .{dir});
    defer ctx.gpa.free(f);

    // L01..L40 committed, then L05..L08 deleted: a 4-row block of woven old
    // lines sits above L09, near the top of the screen.
    var orig: std.ArrayList(u8) = .empty;
    defer orig.deinit(ctx.gpa);
    var edited: std.ArrayList(u8) = .empty;
    defer edited.deinit(ctx.gpa);
    var i: usize = 1;
    while (i <= 40) : (i += 1) {
        var b: [16]u8 = undefined;
        const line = std.fmt.bufPrint(&b, "L{d:0>2}\n", .{i}) catch break;
        try orig.appendSlice(ctx.gpa, line);
        if (i < 5 or i > 8) try edited.appendSlice(ctx.gpa, line);
    }
    h.writeFile(ctx.io, f, orig.items);
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "init", "-q" });
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "add", "f.txt" });
    h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "commit", "-q", "-m", "init" });
    h.writeFile(ctx.io, f, edited.items);

    const wheel_down = "\x1b[<65;40;10M";
    // --- the line-by-line weave (one window, virtual rows above L09) --------
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(800);
        s.send(" gl");
        s.drain(800);
        // Notch 1 clears the three rows above the block; notch 2 must step
        // *through* the block (top = L09, five screen rows) rather than over it
        // (top = L11, seven rows — the leap).
        s.send(wheel_down);
        s.drain(350);
        var scr = try snapshot(ctx, &s);
        var top = try scr.rowText(ctx.gpa, 2);
        ctx.check("one wheel notch moves three rows", std.mem.indexOf(u8, top, "L04") != null);
        ctx.gpa.free(top);
        scr.deinit();

        s.send(wheel_down);
        s.drain(350);
        scr = try snapshot(ctx, &s);
        top = try scr.rowText(ctx.gpa, 2);
        ctx.check("a notch crossing a woven block counts its rows", std.mem.indexOf(u8, top, "L09") != null);
        ctx.gpa.free(top);
        scr.deinit();

        s.send(wheel_down);
        s.drain(350);
        scr = try snapshot(ctx, &s);
        top = try scr.rowText(ctx.gpa, 2);
        ctx.check("and the notch after it is three rows again", std.mem.indexOf(u8, top, "L12") != null);
        ctx.gpa.free(top);
        scr.deinit();
        s.send(":q!" ++ "\r");
        s.drain(300);
    }

    // --- the side-by-side pair (fillers in the worktree pane) ---------------
    // The invariant there is levelness: the pair is row-aligned, so after any
    // amount of wheeling a line present on both sides sits on the same row.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(800);
        s.send(" gs");
        s.drain(900);
        var n: usize = 0;
        while (n < 2) : (n += 1) {
            s.send(wheel_down);
            s.drain(350);
        }
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        const top = try scr.rowText(ctx.gpa, 2);
        defer ctx.gpa.free(top);
        // Levelness alone proves nothing here — `syncDiffPanes` derives the
        // other pane's top from this one every frame, so the pair stays aligned
        // whatever the step was. What the notch must get right is the distance:
        // the worktree pane's four filler rows count, so two notches reach L09.
        ctx.check("a notch crossing a pair's fillers counts them", std.mem.indexOf(u8, top, "L09") != null);
        s.send(":qa!" ++ "\r");
        s.drain(300);
    }
}

pub fn run(ctx: *h.Ctx) !void {
    try wheelOverVirtualRows(ctx);
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
    try inlineReadOnly(ctx);
    try sideLeadingDeletion(ctx);
    try sideTallGap(ctx);
    try sideDirtyNoChanges(ctx);
    try diffViewsExclusive(ctx);
    try sidePhantomToggle(ctx);
    try inlinePhantomToggle(ctx);
    try lineDiffWeave(ctx);
    try lineDiffRefreshOnSave(ctx);
    try lineDiffExclusive(ctx);
    try lineDiffNoChanges(ctx);
    try lineDiffTotalDeletion(ctx);
    try lineDiffEdgeAnchors(ctx);
    try lineDiffWrapGeometry(ctx);
    try lineDiffTallBlock(ctx);
    try lineDiffSanitized(ctx);
    try lineDiffCleanSaveCloses(ctx);
    try lineDiffSplit(ctx);
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

/// A hunk whose deletion precedes line 1 (`@@ -1,N +0,0 @@`, new-side start 0)
/// puts its old lines *above* buffer row 0 in aligned display space. The pane
/// anchor must show that leading gap: a total deletion used to render an
/// all-tilde index pane, and a first-lines deletion silently hid the old lines.
fn sideLeadingDeletion(ctx: *h.Ctx) !void {
    // Total deletion: every committed line exists only in the index pane.
    {
        const dir = try diffRepo(ctx, "alpha\nbravo\ncharlie\ndelta\necho5\n", "");
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        s.send(" gs");
        s.drain(700);
        {
            var scr = try snapshot(ctx, &s);
            defer scr.deinit();
            // Rows (tab bar = 1): 2-6 FILL|alpha..echo5, 7 the empty worktree line.
            const a = scr.colOf(ctx.gpa, 2, "alpha");
            const e = scr.colOf(ctx.gpa, 6, "echo5");
            ctx.check("total deletion: index pane shows the old lines", a != null and a.? > 40 and
                e != null and e.? > 40);
            ctx.check("total deletion: worktree pane fills the gap", scr.at(2, 20).bg == TINT_DELETE and
                scr.at(6, 20).bg == TINT_DELETE);
        }
        // Moving inside the index pane must not yank the pair off the gap.
        s.send("\x17wjj");
        s.drain(400);
        {
            var scr = try snapshot(ctx, &s);
            defer scr.deinit();
            ctx.check("total deletion: index-pane movement stays anchored", scr.colOf(ctx.gpa, 2, "alpha") != null);
        }
        s.send(" gs"); // toggle closed from the index pane
        s.drain(500);
        {
            var scr = try snapshot(ctx, &s);
            defer scr.deinit();
            ctx.check("total deletion: Space g s still toggles closed", screenCount(&scr, ctx.gpa, "(index)") == 0);
        }
        s.send(":qa\r");
        s.drain(300);
    }
    // First lines deleted with survivors: the old lines show above, and the
    // first surviving line stays level across the panes.
    {
        const dir = try diffRepo(ctx, "alpha\nbravo\ncharlie\ndelta\necho5\n", "charlie\ndelta\necho5\n");
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        s.send(" gs");
        s.drain(700);
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        // Rows: 2 FILL|alpha  3 FILL|bravo  4 charlie|charlie ...
        const a = scr.colOf(ctx.gpa, 2, "alpha");
        const b = scr.colOf(ctx.gpa, 3, "bravo");
        ctx.check("leading deletion: deleted lines visible in the index pane", a != null and a.? > 40 and
            b != null and b.? > 40);
        ctx.check("leading deletion: worktree pane fills the gap", scr.at(2, 20).bg == TINT_DELETE and
            scr.at(3, 20).bg == TINT_DELETE);
        ctx.check("leading deletion: survivors align", rowCount(&scr, ctx.gpa, 4, "charlie") == 2);
        s.send(":qa\r");
        s.drain(300);
    }
}

/// A leading gap taller than the window: the anchor clamps so the cursor (on
/// the worktree's single empty line, below the gap) stays on screen — the tail
/// of the old lines shows, not an empty pane.
fn sideTallGap(ctx: *h.Ctx) !void {
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(ctx.gpa);
    var n: usize = 1;
    while (n <= 40) : (n += 1) {
        var b: [12]u8 = undefined;
        const line = std.fmt.bufPrint(&b, "line{d:0>3}\n", .{n}) catch unreachable;
        try committed.appendSlice(ctx.gpa, line);
    }
    const dir = try diffRepo(ctx, committed.items, "");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gs");
    s.drain(700);
    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    ctx.check("tall gap: the gap's tail is visible (not an empty pane)", screenCount(&scr, ctx.gpa, "line040") >= 1);
    ctx.check("tall gap: clamped to the cursor, so the top is off screen", screenCount(&scr, ctx.gpa, "line001") == 0);
    s.send(":qa\r");
    s.drain(300);
}

/// An emptied but UNSAVED buffer: `git diff` still compares the on-disk file,
/// so the view reports "no changes" and never opens — the same disk-vs-index
/// semantic as the gutter signs (pinned so a future change is deliberate).
fn sideDirtyNoChanges(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\n", "one\ntwo\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send("dG"); // empty the buffer, do not save
    s.drain(300);
    s.send(" gs");
    s.drain(500);
    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    ctx.check("unsaved delete-all: message, no split", s.containsPlain(ctx.gpa, "no changes") and
        screenCount(&scr, ctx.gpa, "(index)") == 0);
    s.send(":q!\r");
    s.drain(300);
}

/// The two diff views are exclusive per file: opening one closes the other
/// first, so they can never stack into a third window — and the tiling
/// orientation always belongs to the view being opened (the side pair
/// re-tiles side by side even after the inline diff's horizontal split).
fn diffViewsExclusive(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\n", "one\nTWO\nthree\nfour\nfive\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gs"); // side pair open
    s.drain(700);
    s.send(" gd"); // must replace it with the inline diff, not add a window
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gd over gs: side pair replaced by the inline diff", screenCount(&scr, ctx.gpa, "(index)") == 0 and
            screenCount(&scr, ctx.gpa, "[diff]") > 0 and screenCount(&scr, ctx.gpa, "@@") > 0);
    }
    s.send(" gd"); // plain toggle: back to a single window
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gd toggle after the swap: single window again", screenCount(&scr, ctx.gpa, "[diff]") == 0 and
            screenCount(&scr, ctx.gpa, "(index)") == 0);
    }
    s.send(" gs"); // the side pair re-tiles in columns despite the earlier horizontal split
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gs over gd: side pair back, side by side", rowCount(&scr, ctx.gpa, 2, "one") == 2 and
            screenCount(&scr, ctx.gpa, "[diff]") == 0);
    }
    s.send(":qa\r");
    s.drain(300);
}

/// The side toggle keys on a *visible* snapshot the same way: `:bn` (or
/// `:close`) in the index pane leaves the scratch windowless, and the next
/// Space g s must show the pair again — not a phantom "diff closed" that
/// changes nothing on screen.
fn sidePhantomToggle(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "alpha\nbeta\n", "alpha\nBETA\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gs");
    s.drain(700);
    s.send("\x17w:bn\r"); // the index window now shows f.txt; the snapshot lingers windowless
    s.drain(400);
    s.send(" gs");
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gs after :bn shows the pair again (no phantom toggle)", screenCount(&scr, ctx.gpa, "(index)") > 0);
    }
    s.send(" gs"); // and it still toggles closed
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("and the side view toggles closed again", screenCount(&scr, ctx.gpa, "(index)") == 0);
    }
    s.send(":qa\r");
    s.drain(300);
}

/// The inline toggle keys on a *visible* window: a scratch left windowless by
/// `:bn` is stale, and the next Space g d must show the diff again — not a
/// phantom "diff closed" that changes nothing on screen.
fn inlinePhantomToggle(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "alpha\nbeta\n", "alpha\nBETA\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gd");
    s.drain(600);
    s.send(":bn\r"); // the diff window now shows f.txt; the scratch lingers windowless
    s.drain(400);
    s.send(" gd");
    s.drain(600);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gd after :bn shows the diff again (no phantom toggle)", screenCount(&scr, ctx.gpa, "@@") > 0 and
            screenCount(&scr, ctx.gpa, "[diff]") > 0);
    }
    s.send(" gd"); // and it still toggles closed
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("and toggles closed again", screenCount(&scr, ctx.gpa, "@@") == 0 and
            screenCount(&scr, ctx.gpa, "[diff]") == 0);
    }
    s.send(":qa\r");
    s.drain(300);
}

// === line-diff view (Space g l) =============================================

// Changed-line tint: mixColor(tokyonight bg, git_change, 25%).
const TINT_CHANGE = h.rgb(75, 64, 54);

/// Whether `needle` starts exactly at 1-based column `want` of `row`.
fn colIs(scr: *h.Screen, gpa: std.mem.Allocator, row: usize, needle: []const u8, want: usize) bool {
    const col = scr.colOf(gpa, row, needle) orelse return false;
    return col == want;
}

/// The weave itself. Repo: committed one..six; worktree changes "two" to
/// "TWO-C", deletes "four"/"five" and appends "added7". Expected rows (tab
/// bar = 1, gutter 5 wide, text from col 6):
///   2 one   3 -two(virtual)   4 TWO-C   5 three
///   6 -four(virtual)   7 -five(virtual)   8 six   9 added7
/// Deleted text renders red-tinted at those positions with a `-` gutter and
/// no line number; added/changed real rows tint; `j` steps real line to real
/// line (the cursor can never land on a woven row); the toggle closes the
/// view; :qa stays unblocked (the weave is pure rendering).
fn lineDiffWeave(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\nfive\nsix\n", "one\nTWO-C\nthree\nsix\nadded7\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gl");
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("line view: changed-from text weaves above its line", colIs(&scr, ctx.gpa, 3, "two", 6) and
            colIs(&scr, ctx.gpa, 4, "TWO-C", 6));
        ctx.check("line view: deleted lines weave in order above the survivor", colIs(&scr, ctx.gpa, 6, "four", 6) and
            colIs(&scr, ctx.gpa, 7, "five", 6) and colIs(&scr, ctx.gpa, 8, "six", 6));
        ctx.check("line view: woven rows are red-tinted", scr.at(3, 6).bg == TINT_DELETE and
            scr.at(6, 6).bg == TINT_DELETE and scr.at(7, 6).bg == TINT_DELETE);
        ctx.check("line view: woven rows have a - gutter, no line number", scr.at(3, 1).cp == '-' and
            scr.at(3, 4).cp == ' ' and scr.at(6, 1).cp == '-' and scr.at(6, 4).cp == ' ');
        ctx.check("line view: real rows keep their numbers", scr.at(2, 4).cp == '1' and
            scr.at(4, 4).cp == '1'); // absolute on the cursor line, relative below
        ctx.check("line view: changed and added rows tint", scr.at(4, 6).bg == TINT_CHANGE and
            scr.at(9, 6).bg == TINT_ADD);
        ctx.check("line view: cursor starts on the first real row", scr.cur_row == 2);
    }
    s.send("j"); // one -> TWO-C: must skip the woven "two"
    s.drain(300);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("line view: j skips a woven row", scr.cur_row == 4);
    }
    s.send("jj"); // three -> six: must skip the two woven deletions
    s.drain(300);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("line view: j skips a woven block", scr.cur_row == 8);
    }
    const m = s.mark();
    s.send(" gl"); // toggle the weave off
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("line view: toggle closes the weave", s.containsPlainSince(ctx.gpa, m, "diff closed") and
            screenCount(&scr, ctx.gpa, "four") == 0 and screenCount(&scr, ctx.gpa, "five") == 0);
    }
    s.send(":qa\r");
    s.drain(500);
    ctx.check("line view: :qa is not blocked", s.contains("\x1b[?1049l"));
}

/// The weave reflects the file as last saved (the gutter-sign contract):
/// inserting a line above every hunk and writing re-anchors the woven rows
/// one line down, and the new line gets its added tint.
fn lineDiffRefreshOnSave(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\nfive\nsix\n", "one\nTWO-C\nthree\nsix\nadded7\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gl");
    s.drain(700);
    s.send("ggOzzz\x1b"); // a new first line, above every hunk
    s.drain(400);
    s.send(":w\r");
    s.drain(700);
    s.send("j"); // off the zzz row, so its tint is not hidden by the cursorline
    s.drain(300);
    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    // Rows now: 2 zzz  3 one  4 -two(virtual)  5 TWO-C  ...
    ctx.check("saved edit re-anchors the weave", colIs(&scr, ctx.gpa, 5, "TWO-C", 6) and
        colIs(&scr, ctx.gpa, 4, "two", 6) and scr.at(4, 6).bg == TINT_DELETE and scr.at(4, 1).cp == '-');
    ctx.check("saved new line tints as added", scr.at(2, 6).bg == TINT_ADD);
    s.send(":qa\r");
    s.drain(300);
}

/// Three-way exclusivity: opening any diff view closes the line-diff weave,
/// and Space g l closes whichever of the other two is open — both ways for
/// both, with the weave's deleted text as the witness ("four"/"five" exist
/// only in the weave, the diff scratch, or the index pane).
fn lineDiffExclusive(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\nfive\nsix\n", "one\nTWO-C\nthree\nsix\nadded7\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gl"); // weave on
    s.drain(700);
    s.send(" gd"); // the unified-diff scratch must replace the weave
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gd over gl: scratch opens", screenCount(&scr, ctx.gpa, "[diff]") > 0);
    }
    s.send(" gd"); // plain toggle: if gl's weave survived, "four" would still show
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gd over gl: the weave was closed, not stacked", screenCount(&scr, ctx.gpa, "[diff]") == 0 and
            screenCount(&scr, ctx.gpa, "four") == 0);
    }
    s.send(" gl"); // weave on again
    s.drain(700);
    s.send(" gs"); // the side pair must replace the weave
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gs over gl: pair opens", screenCount(&scr, ctx.gpa, "(index)") > 0);
        // The deleted lines now live in the index pane only — a leftover
        // weave would put "four" in the left (worktree) half too.
        var left_four = false;
        var row: usize = 2;
        while (row <= 23) : (row += 1) {
            if (scr.colOf(ctx.gpa, row, "four")) |col| {
                if (col < 41) left_four = true;
            }
        }
        ctx.check("gs over gl: deleted text only in the index pane", !left_four);
    }
    s.send(" gs"); // toggle the pair closed
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gs over gl: weave closed too", screenCount(&scr, ctx.gpa, "(index)") == 0 and
            screenCount(&scr, ctx.gpa, "four") == 0);
    }
    // Reverse direction: gl closes an open scratch / pair.
    s.send(" gd");
    s.drain(700);
    s.send("\x17w"); // back to the file window (the scratch has no path)
    s.drain(300);
    s.send(" gl");
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gl over gd: scratch closed, weave on", screenCount(&scr, ctx.gpa, "[diff]") == 0 and
            colIs(&scr, ctx.gpa, 6, "four", 6) and scr.at(6, 6).bg == TINT_DELETE);
    }
    s.send(" gl"); // weave off again
    s.drain(400);
    s.send(" gs");
    s.drain(700);
    s.send(" gl");
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("gl over gs: pair closed, weave on", screenCount(&scr, ctx.gpa, "(index)") == 0 and
            colIs(&scr, ctx.gpa, 6, "four", 6) and scr.at(6, 6).bg == TINT_DELETE);
    }
    s.send(":qa\r");
    s.drain(300);
}

/// A file with no changes reports so and never enters the view: the second
/// press must say "no changes" again, not "diff closed".
fn lineDiffNoChanges(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "same\nlines\n", "same\nlines\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gl");
    s.drain(500);
    ctx.check("line view: no changes reports", s.containsPlain(ctx.gpa, "no changes"));
    s.send("j"); // motion: clears the message so the next one re-renders
    s.drain(200);
    const m = s.mark();
    s.send(" gl");
    s.drain(500);
    ctx.check("line view: no changes never entered the view", s.containsPlainSince(ctx.gpa, m, "no changes") and
        !s.containsPlainSince(ctx.gpa, m, "diff closed"));
    s.send(":qa\r");
    s.drain(300);
}

/// A total deletion: every committed line weaves above the single empty
/// line the worktree file still has, and the cursor sits below the block.
fn lineDiffTotalDeletion(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "alpha\nbravo\ncharlie\ndelta\necho5\n", "");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gl");
    s.drain(700);
    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    ctx.check("total deletion: all old lines weave above row 0", colIs(&scr, ctx.gpa, 2, "alpha", 6) and
        colIs(&scr, ctx.gpa, 6, "echo5", 6) and scr.at(2, 6).bg == TINT_DELETE and scr.at(6, 6).bg == TINT_DELETE);
    ctx.check("total deletion: the real (empty) line keeps its number", scr.at(7, 4).cp == '1');
    ctx.check("total deletion: cursor sits on the real line below the block", scr.cur_row == 7);
    s.send(":qa\r");
    s.drain(500);
    ctx.check("total deletion: :qa exits cleanly", s.contains("\x1b[?1049l"));
}

/// The weave's edge anchors: a change of line 1 puts its old line *above*
/// row 0 (leading block, before the first real row), and a deletion at EOF
/// weaves after the last real line, before the `~` rows.
fn lineDiffEdgeAnchors(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\n", "ONE\ntwo\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gl");
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("edge anchors: line-1 old text weaves above the first row", colIs(&scr, ctx.gpa, 2, "one", 6) and
            scr.at(2, 6).bg == TINT_DELETE and scr.at(2, 1).cp == '-' and colIs(&scr, ctx.gpa, 3, "ONE", 6));
        ctx.check("edge anchors: EOF deletion weaves after the last line", colIs(&scr, ctx.gpa, 5, "three", 6) and
            colIs(&scr, ctx.gpa, 6, "four", 6) and scr.at(5, 6).bg == TINT_DELETE and scr.at(7, 1).cp == '~');
        ctx.check("edge anchors: cursor starts below the leading block", scr.cur_row == 3);
    }
    s.send("G"); // to the last real line: lands between the woven blocks
    s.drain(300);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("edge anchors: G lands on the last real line", scr.cur_row == 4 and
            colIs(&scr, ctx.gpa, 4, "two", 6));
    }
    s.send(":qa\r");
    s.drain(300);
}

/// Soft wrap stays on in the weave: a wrapped real line fills its rows and
/// the cursor's screen row counts woven rows *and* wrap segments above it.
fn lineDiffWrapGeometry(ctx: *h.Ctx) !void {
    const long = "wrapme " ** 20; // 140 display columns: two rows in an 80-col window
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\n", "one\n" ++ long ++ "\nTHREE\nfour\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gl");
    s.drain(700);
    s.send("jjj"); // one -> wrapped line -> THREE -> four
    s.drain(300);
    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    // Rows: 2 one, 3 -two, 4 -three, 5+6 the wrapped line, 7 THREE, 8 four.
    ctx.check("wrap geometry: woven rows then the wrapped line", colIs(&scr, ctx.gpa, 3, "two", 6) and
        colIs(&scr, ctx.gpa, 4, "three", 6) and colIs(&scr, ctx.gpa, 5, "wrapme", 6) and
        scr.at(6, 6).cp != '~' and colIs(&scr, ctx.gpa, 7, "THREE", 6));
    ctx.check("wrap geometry: cursor row counts woven + wrap rows", scr.cur_row == 8 and
        colIs(&scr, ctx.gpa, 8, "four", 6));
    s.send(":qa\r");
    s.drain(300);
}

/// A deleted block taller than the window: no crash, only the block's head
/// shows (buffer-row top — the documented limit), and j/k across it land on
/// the right lines with the view following.
fn lineDiffTallBlock(ctx: *h.Ctx) !void {
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(ctx.gpa);
    var worktree: std.ArrayList(u8) = .empty;
    defer worktree.deinit(ctx.gpa);
    var i: usize = 1;
    while (i <= 205) : (i += 1) { // delete lines 3..202: a 200-line block
        var lb: [16]u8 = undefined;
        const line = std.fmt.bufPrint(&lb, "line{d}\n", .{i}) catch unreachable;
        try committed.appendSlice(ctx.gpa, line);
        if (i <= 2 or i >= 203) try worktree.appendSlice(ctx.gpa, line);
    }
    const dir = try diffRepo(ctx, committed.items, worktree.items);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(600);
    s.send(" gl");
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("tall block: head fills the window below its anchor", colIs(&scr, ctx.gpa, 3, "line2", 6) and
            colIs(&scr, ctx.gpa, 4, "line3", 6) and colIs(&scr, ctx.gpa, 23, "line22", 6) and
            scr.at(4, 6).bg == TINT_DELETE and scr.at(23, 6).bg == TINT_DELETE);
    }
    s.send("jj"); // line1 -> line2 -> line203: crossing jumps the view
    s.drain(300);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("tall block: j across it lands past the block", scr.cur_row == 2 and
            colIs(&scr, ctx.gpa, 2, "line203", 6));
    }
    s.send("k"); // back across: line2 on top, the block below again
    s.drain(300);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("tall block: k back across shows the head again", scr.cur_row == 2 and
            colIs(&scr, ctx.gpa, 2, "line2", 6) and colIs(&scr, ctx.gpa, 3, "line3", 6));
    }
    s.send("G\x15\x04"); // G, Ctrl-u, Ctrl-d: stress the paging paths
    s.drain(400);
    s.send(":qa\r");
    s.drain(500);
    ctx.check("tall block: :qa exits cleanly", s.contains("\x1b[?1049l"));
}

/// Woven text is untrusted (git output): a committed line holding a raw
/// ESC/CSI renders it as `?`, never as a live escape — the raw stream since
/// the weave opened must not contain the committed sequence.
fn lineDiffSanitized(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\n\x1b[31mred\ntwo\n", "one\ntwo\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    const m = s.mark();
    s.send(" gl");
    s.drain(700);
    ctx.check("sanitize: the committed ESC never reaches the terminal", std.mem.indexOf(u8, s.out.items[m..], "\x1b[31m") == null);
    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    ctx.check("sanitize: the woven row shows ? for the ESC byte", colIs(&scr, ctx.gpa, 3, "?[31mred", 6) and
        scr.at(3, 6).bg == TINT_DELETE);
    s.send(":qa\r");
    s.drain(300);
}

/// Saving a buffer edited back to the committed text closes the weave (no
/// hunks left) and clears the gutter signs with it — the refresh derives
/// the signs from the weave's own diff run.
fn lineDiffCleanSaveCloses(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\nthree\n", "one\nTWO\nthree\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gl");
    s.drain(700);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("clean save: the weave is up first", colIs(&scr, ctx.gpa, 3, "two", 6) and
            scr.at(3, 6).bg == TINT_DELETE);
    }
    s.send("jciwtwo\x1b"); // restore the committed text
    s.drain(300);
    s.send(":w\r");
    s.drain(700);
    s.send("gg"); // off the row: the cursorline bg must not mask a stale tint
    s.drain(300);
    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    ctx.check("clean save: the weave closes with nothing to show", screenCount(&scr, ctx.gpa, "two") == 1 and
        colIs(&scr, ctx.gpa, 3, "two", 6) and scr.at(3, 6).bg != TINT_DELETE and scr.at(3, 1).cp != '-');
    // The refresh derived the (empty) signs from the weave's diff run: a
    // stale sign would leave its bar glyph in the gutter's sign column.
    ctx.check("clean save: the gutter sign cleared with it", scr.at(3, 1).cp == ' ' and
        scr.at(3, 6).bg != TINT_CHANGE);
    s.send(":qa\r");
    s.drain(300);
}

/// The weave is document state: a split shows it in both windows, and it
/// stays put when the buffer cycles away and back.
fn lineDiffSplit(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "one\ntwo\nthree\nfour\nfive\nsix\n", "one\nTWO-C\nthree\nsix\nadded7\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gl");
    s.drain(700);
    s.send(":vsplit\r");
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        // Woven "four" shows once per pane, on the same screen row.
        ctx.check("split: both panes weave", screenCount(&scr, ctx.gpa, "four") == 2 and
            rowCount(&scr, ctx.gpa, 6, "four") == 2);
    }
    s.send(":close\r");
    s.drain(400);
    s.send(":bn\r"); // away (single buffer: stays put) and prove the weave is still on
    s.drain(300);
    var scr = try snapshot(ctx, &s);
    defer scr.deinit();
    ctx.check("split: the weave survives window churn", colIs(&scr, ctx.gpa, 6, "four", 6) and
        scr.at(6, 6).bg == TINT_DELETE);
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

/// The unified-diff scratch is read-only, like the index pane: edits, pastes
/// and `:w <name>` are refused with "diff view is read-only", so a viewed
/// diff can never turn into a dirty buffer that blocks `:qa`.
fn inlineReadOnly(ctx: *h.Ctx) !void {
    const dir = try diffRepo(ctx, "alpha\nbeta\n", "alpha\nBETA\n");
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const leak = h.join(ctx, dir, "leak.txt");
    defer ctx.gpa.free(leak);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(500);
    s.send(" gd"); // focus lands in the scratch
    s.drain(600);

    // Insert and delete are both refused with the message (never leaves
    // normal mode: the following x would otherwise become text).
    const m1 = s.mark();
    s.send("ix");
    s.drain(300);
    ctx.check("diff scratch rejects edits", s.containsPlainSince(ctx.gpa, m1, "diff view is read-only"));
    s.send("dd");
    s.drain(300);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("diff scratch text is untouched", screenCount(&scr, ctx.gpa, "@@") > 0 and
            screenCount(&scr, ctx.gpa, "BETA") > 0);
    }

    // A bracketed paste into the scratch inserts nothing.
    s.send("\x1b[200~ZZZ\x1b[201~");
    s.drain(300);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("diff scratch rejects pastes", screenCount(&scr, ctx.gpa, "ZZZ") == 0);
    }

    // `:w <name>` must not write the scratch out.
    s.send("j"); // motion: clears the previous message so the next one re-renders
    s.drain(200);
    const m2 = s.mark();
    s.send(":w leak.txt\r");
    s.drain(400);
    const leaked = h.readFile(ctx.gpa, ctx.io, leak);
    defer ctx.gpa.free(leaked);
    ctx.check("diff scratch refuses :w <name>", s.containsPlainSince(ctx.gpa, m2, "diff view is read-only") and leaked.len == 0);

    // The toggle still works from the scratch, and :qa was never blocked.
    s.send(" gd");
    s.drain(500);
    {
        var scr = try snapshot(ctx, &s);
        defer scr.deinit();
        ctx.check("read-only scratch still toggles closed", screenCount(&scr, ctx.gpa, "[diff]") == 0);
    }
    s.send(" gd");
    s.drain(600);
    s.send(":qa\r");
    s.drain(500);
    ctx.check(":qa is not blocked after viewing the diff", s.contains("\x1b[?1049l"));
}
