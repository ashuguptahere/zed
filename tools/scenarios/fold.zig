//! Folds: `zf{motion}` collapses a range to one row, `zo`/`zc`/`za` open and
//! close it, `zR`/`zM` act on all of them, `zd`/`zE` remove them.
//!
//! Which rows are hidden, and how nesting resolves, is unit-tested in
//! `fold.zig`; what is checked here is the editor's half — that the fold
//! really is one row on screen, that `j`/`k` treat it as one line rather than
//! making you press `j` once per hidden line, and that the text is untouched
//! throughout (a fold hides, it does not edit).

const std = @import("std");
const h = @import("../harness.zig");


const ESC = "\x1b";
const CR = "\r";
const eight = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n";



/// Twelve numbered lines with two nested folds — the outer over 2..11, the
/// inner over 4..7 — both left *open*. `zf` closes what it makes, so each is
/// reopened with `zR` before the next is cut; without that the second `zf`
/// measures its motion over a collapsed view and swallows the first.
const nest_setup = "4Gzf3jzR2Gzf9jzR";

/// Run `keys` over that setup and report which of lines 1..12 are hidden —
/// a line is hidden when it is inside a closed fold but is not its header.
/// nvim answers the same question with `foldclosed()`, which is where the
/// expectations came from.
fn foldCase(ctx: *h.Ctx, dir: []const u8, name: []const u8, keys: []const u8, hidden: []const u8) !void {
    const f = h.join(ctx, dir, "n.txt");
    defer ctx.gpa.free(f);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(ctx.gpa);
    var b: [8]u8 = undefined;
    for (1..13) |i| try body.appendSlice(ctx.gpa, try std.fmt.bufPrint(&b, "L{d:0>2}\n", .{i}));
    h.writeFile(ctx.io, f, body.items);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--lsp", "", "n.txt" }, .cwd = dir });
    defer s.finish();
    s.drain(600);
    s.send(nest_setup);
    s.drain(400);
    s.send(keys);
    s.drain(400);

    var scr = try h.screenOf(ctx, &s, 24, 80);
    defer scr.deinit();
    var ok = true;
    for (1..13) |i| {
        const needle = try std.fmt.bufPrint(&b, "L{d:0>2}", .{i});
        // On screen exactly when it is *not* hidden.
        if (scr.has(ctx.gpa, needle) == containsLine(hidden, i)) ok = false;
    }
    ctx.check(name, ok);
    s.send(":q!" ++ CR);
    s.drain(200);
}

/// Is line `n` listed in a "2,3,5" style set?
fn containsLine(set: []const u8, n: usize) bool {
    var it = std.mem.tokenizeScalar(u8, set, ',');
    while (it.next()) |tok| {
        const v = std.fmt.parseInt(usize, tok, 10) catch continue;
        if (v == n) return true;
    }
    return false;
}

pub fn run(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();
    const f = h.join(ctx, dir, "f.txt");
    defer ctx.gpa.free(f);

    // --- the rest of the fold namespace, against nvim's foldclosed() -----
    // Setup: outer fold 2..11, inner 4..7, both open. "hidden" lists the
    // lines that must *not* be on screen — a closed fold shows its header
    // (its first line) and hides the rest.
    try foldCase(ctx, dir, "nvim#zf1 both open to start", "", "");
    try foldCase(ctx, dir, "nvim#zf2 zM closes the outer", "zM", "3,4,5,6,7,8,9,10,11");
    try foldCase(ctx, dir, "nvim#zf3 zc takes the innermost", "4Gzc", "5,6,7");
    try foldCase(ctx, dir, "nvim#zf4 zC closes recursively", "4GzC", "3,4,5,6,7,8,9,10,11");
    try foldCase(ctx, dir, "nvim#zf5 zo opens only the outer", "zM2Gzo", "5,6,7");
    try foldCase(ctx, dir, "nvim#zf6 zO opens recursively", "zM2GzO", "");
    try foldCase(ctx, dir, "nvim#zf7 zA toggles recursively", "4Gzc2GzA", "3,4,5,6,7,8,9,10,11");
    try foldCase(ctx, dir, "nvim#zf8 zv reveals the cursor line", "zM5Gzv", "");
    // foldlevel: zm closes one level more, zr opens one more.
    try foldCase(ctx, dir, "nvim#zf9 zm closes the inner first", "zm", "5,6,7");
    try foldCase(ctx, dir, "nvim#zf10 zm again takes the outer", "zmzm", "3,4,5,6,7,8,9,10,11");
    try foldCase(ctx, dir, "nvim#zf11 zr opens the outer first", "zMzr", "5,6,7");
    try foldCase(ctx, dir, "nvim#zf12 zr again opens all", "zMzrzr", "");
    // foldenable: zn hides nothing without forgetting the state, zN restores.
    try foldCase(ctx, dir, "nvim#zf13 zn shows everything", "zMzn", "");
    try foldCase(ctx, dir, "nvim#zf14 zN puts it back", "zMznzN", "3,4,5,6,7,8,9,10,11");
    try foldCase(ctx, dir, "nvim#zf15 zi toggles it", "zMzi", "");
    // zD deletes the innermost fold and whatever nests inside it; the outer
    // survives, which a following zM proves.
    try foldCase(ctx, dir, "nvim#zf16 zD leaves the outer", "4GzDzM", "3,4,5,6,7,8,9,10,11");

    // --- zf hides the body and leaves a header ------------------------------
    {
        h.writeFile(ctx.io, f, eight);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        const m = s.mark();
        s.send("jzf3j"); // fold lines 2..5
        s.drain(500);
        ctx.check("zf reports what it folded", s.containsPlainSince(ctx.gpa, m, "folded 4 lines"));
        var scr = try h.screenOf(ctx, &s, 24, 80);
        ctx.check("the fold header names the count", scr.has(ctx.gpa, "4 lines: l2"));
        ctx.check("the folded body is off screen", !scr.has(ctx.gpa, "l3") and !scr.has(ctx.gpa, "l5"));
        ctx.check("lines outside it still show", scr.has(ctx.gpa, "l1") and scr.has(ctx.gpa, "l6"));
        scr.deinit();

        // `j` treats the fold as one line: from the header it lands on l6, not
        // on a hidden line, and `k` comes back to the header.
        s.send("j");
        s.drain(300);
        s.send("x"); // mark where the cursor is
        s.drain(300);
        s.send("kx"); // back onto the fold header, mark it too
        s.drain(300);
        s.send(":wq" ++ CR);
        s.drain(600);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("j steps over a closed fold in one press and k returns to its header",
            std.mem.eql(u8, got, "l1\n2\nl3\nl4\nl5\n6\nl7\nl8\n"));
    }

    // --- zo / zc / za, and zR / zM -----------------------------------------
    {
        h.writeFile(ctx.io, f, eight);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send("jzf3j");
        s.drain(400);
        s.send("zo"); // open it
        s.drain(400);
        var scr = try h.screenOf(ctx, &s, 24, 80);
        ctx.check("zo shows the body again", scr.has(ctx.gpa, "l3") and scr.has(ctx.gpa, "l5"));
        scr.deinit();
        s.send("zc");
        s.drain(400);
        scr = try h.screenOf(ctx, &s, 24, 80);
        ctx.check("zc hides it again", !scr.has(ctx.gpa, "l3"));
        scr.deinit();
        s.send("za");
        s.drain(400);
        scr = try h.screenOf(ctx, &s, 24, 80);
        ctx.check("za toggles it open", scr.has(ctx.gpa, "l3"));
        scr.deinit();
        var m = s.mark();
        s.send("zM"); // close every fold
        s.drain(400);
        ctx.check("zM closes them all", s.containsPlainSince(ctx.gpa, m, "closed 1 folds"));
        m = s.mark();
        s.send("zR");
        s.drain(400);
        ctx.check("zR opens them all", s.containsPlainSince(ctx.gpa, m, "opened 1 folds"));
        // Removing a fold leaves the text alone.
        m = s.mark();
        s.send("zd");
        s.drain(400);
        ctx.check("zd removes the fold", s.containsPlainSince(ctx.gpa, m, "fold removed"));
        m = s.mark();
        s.send("zo");
        s.drain(300);
        ctx.check("and then there is no fold to open", s.containsPlainSince(ctx.gpa, m, "no fold here"));
        s.send(":q" ++ CR); // unmodified: folding never touched the text
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("folding never edited the buffer", std.mem.eql(u8, got, eight));
    }

    // --- a fold survives editing around it ----------------------------------
    {
        h.writeFile(ctx.io, f, eight);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send("3jzfj"); // fold lines 4..5
        s.drain(400);
        s.send("ggOnew" ++ ESC); // insert a line at the very top
        s.drain(500);
        var scr = try h.screenOf(ctx, &s, 24, 80);
        // The fold moved down with its text: l4 is still its header and l5 is
        // still hidden.
        ctx.check("a fold moves with the text an edit above it shifts",
            scr.has(ctx.gpa, "2 lines: l4") and !scr.has(ctx.gpa, "l5"));
        scr.deinit();
        s.send(":q!" ++ CR);
        s.drain(300);
    }
}
