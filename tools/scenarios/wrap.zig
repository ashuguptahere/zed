//! Soft wrap: a line too long for the window continues on the next screen row
//! (vim's `wrap`, on by default here too), the `gj`/`gk`/`g0`/`g$` motions walk
//! screen rows rather than buffer lines, and `soft_wrap = false` restores the
//! horizontal scrolling zedit used to do.
//!
//! The window is 80 columns wide and the gutter takes 5, so the text is 75
//! columns and a line of 75 `A`s followed by 75 `B`s occupies exactly two
//! screen rows — which is what makes the column arithmetic below checkable.

const std = @import("std");
const h = @import("../harness.zig");

const seg = 75; // text columns in an 80-column window (80 - 5 gutter)
const WRAP_MARK = "\u{21B3}"; // ↳, the continuation-row gutter marker

pub fn run(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();

    const path = try std.fmt.allocPrint(ctx.gpa, "{s}/long.txt", .{dir});
    defer ctx.gpa.free(path);
    const cfg = try std.fmt.allocPrint(ctx.gpa, "{s}/cfg", .{dir});
    defer ctx.gpa.free(cfg);

    // "A" * 75 ++ "B" * 75 ++ "\nsecond\n": exactly two screen rows, then a line.
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(ctx.gpa);
    try content.appendNTimes(ctx.gpa, 'A', seg);
    try content.appendNTimes(ctx.gpa, 'B', seg);
    try content.appendSlice(ctx.gpa, "\nsecond\n");

    // --- rendering --------------------------------------------------------
    {
        h.writeFile(ctx.io, path, content.items);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "long.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(500);
        ctx.check("a long line wraps onto a continuation row", s.containsPlain(ctx.gpa, "BBBBBBBBBB"));
        ctx.check("the continuation row is marked in the gutter", s.contains(WRAP_MARK));
        ctx.check("the next buffer line is still shown below it", s.containsPlain(ctx.gpa, "second"));
        s.send(":q!\r");
        s.drain(200);
    }

    // --- soft_wrap = false: the old horizontal-scrolling behaviour ---------
    {
        h.writeFile(ctx.io, cfg, "soft_wrap = false\n");
        h.writeFile(ctx.io, path, content.items);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg, "long.txt" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(500);
        ctx.check("soft_wrap = false clips the line instead", !s.containsPlain(ctx.gpa, "BBBBBBBBBB"));
        ctx.check("and draws no continuation marker", !s.contains(WRAP_MARK));
        // The view still scrolls sideways to follow the cursor.
        s.send("$");
        s.drain(300);
        ctx.check("soft_wrap = false still scrolls horizontally", s.containsPlain(ctx.gpa, "BBBBBBBBBB"));
        s.send(":q!\r");
        s.drain(200);
    }

    // --- screen-row motions ------------------------------------------------
    // Each case edits the file and compares the bytes, so the assertion is on
    // where the cursor actually was, not on what the screen looked like.
    const Case = struct { name: []const u8, keys: []const []const u8, a: usize, b: usize };
    const cases = [_]Case{
        // `gj` from the start of the line lands on the first B (display column
        // 75 is the start of the second screen row), and `x` removes it.
        .{ .name = "gj steps down one screen row inside a wrapped line", .keys = &.{ "gj", "x" }, .a = seg, .b = seg - 1 },
        // and back up again, to the first A.
        .{ .name = "gk steps back up to the row above", .keys = &.{ "gj", "gk", "x" }, .a = seg - 1, .b = seg },
        // `g$` is the last character of the *screen* row, not of the line.
        .{ .name = "g$ ends at the last character of the screen row", .keys = &.{ "g$", "x" }, .a = seg - 1, .b = seg },
        // `g0` from the far end of the line goes to the start of its row.
        .{ .name = "g0 returns to the first character of the screen row", .keys = &.{ "$", "g0", "x" }, .a = seg, .b = seg - 1 },
        // `j` walks a *screen* row with wrap on — a deliberate divergence from
        // vim, where it always moves a buffer line. From column 0 of a line
        // that fills two rows, one `j` lands on the first B, exactly as `gj`
        // does; vim would have gone to the next buffer line entirely.
        .{ .name = "j steps a screen row with wrap on", .keys = &.{ "j", "x" }, .a = seg, .b = seg - 1 },
    };
    for (cases) |cs| {
        h.writeFile(ctx.io, path, content.items);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "long.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.sendKeys(cs.keys);
        s.drain(250);
        s.send(":wq\r");
        s.drain(400);

        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(ctx.gpa);
        try want.appendNTimes(ctx.gpa, 'A', cs.a);
        try want.appendNTimes(ctx.gpa, 'B', cs.b);
        // Every case now edits the wrapped line itself.
        try want.appendSlice(ctx.gpa, "\nsecond\n");
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        const ok = std.mem.eql(u8, got, want.items);
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check(cs.name, ok);
    }

    // --- an operator keeps `j` linewise -----------------------------------
    // The cursor moves by screen row now, but `dj` must still take two whole
    // lines: a charwise `j` would delete a row's worth of characters instead,
    // which is what `dgj` does in vim and is not what anyone means by `dj`.
    {
        h.writeFile(ctx.io, path, content.items);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--lsp", "", "long.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.send("dj"); // the wrapped line and the one after it
        s.drain(300);
        s.send(":wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        // Linewise takes both lines. A charwise `j` (which is what the cursor
        // motion now is) would have deleted from the start of the wrapped line
        // to the same column one row down, leaving "second" behind.
        ctx.check("dj is still linewise with wrap on", std.mem.indexOf(u8, got, "second") == null);
    }

    // --- what the screen-row rule is gated on -----------------------------
    // zedit switches `j`/`k` to screen rows when the *current line wraps*.
    // AstroNvim — which is where this behaviour comes from at all — instead
    // maps `j` to `v:count == 0 ? 'gj' : 'j'`, gating on whether a count was
    // typed. The two agree on a bare `j` and disagree the moment a count
    // appears, so that is what these two cases pin. It was never written
    // down before; CLAUDE.md called the whole thing "a deliberate divergence
    // from vim" without saying the gate itself diverges from AstroNvim too.
    {
        const three = try std.fmt.allocPrint(ctx.gpa, "{s}/three.txt", .{dir});
        defer ctx.gpa.free(three);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(ctx.gpa);
        try body.appendNTimes(ctx.gpa, 'A', seg);
        try body.appendNTimes(ctx.gpa, 'B', seg); // line 1 fills exactly two rows
        try body.appendSlice(ctx.gpa, "\nsecond\nthird\n");

        // `2j` from the top of the wrapped line: two *screen* rows is the B
        // segment and then "second". Two *buffer* lines would be "third".
        h.writeFile(ctx.io, three, body.items);
        {
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--lsp", "", "three.txt" }, .cwd = dir });
            defer s.finish();
            s.drain(400);
            s.send("2jx:wq\r");
            s.drain(500);
            const got = h.readFile(ctx.gpa, ctx.io, three);
            defer ctx.gpa.free(got);
            ctx.check("a count still counts screen rows on a wrapped line", std.mem.indexOf(u8, got, "\necond\n") != null);
            ctx.check("...so it does not reach the second buffer line", std.mem.indexOf(u8, got, "\nhird\n") == null);
        }
        // The other half of the gate: from a line that does *not* wrap, `j`
        // is an ordinary buffer-line move, so "second" -> "third".
        h.writeFile(ctx.io, three, body.items);
        {
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--lsp", "", "three.txt" }, .cwd = dir });
            defer s.finish();
            s.drain(400);
            s.send("Gkjx:wq\r"); // onto "second", then down one
            s.drain(500);
            const got = h.readFile(ctx.gpa, ctx.io, three);
            defer ctx.gpa.free(got);
            ctx.check("j on an unwrapped line moves a buffer line", std.mem.indexOf(u8, got, "\nhird\n") != null);
        }
    }

    // --- word breaks, indent retention, wrap_column ------------------------
    // A 4-space indent then words; the row must break at a space, the
    // continuation must hang under the indent, and both must be switchable.
    {
        const prose = "    indented alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november\nplain\n";
        h.writeFile(ctx.io, path, prose);

        const Cfg = struct { name: []const u8, text: ?[]const u8, first: []const u8, cont: []const u8 };
        const layouts = [_]Cfg{
            .{
                .name = "wraps at a space and hangs under the indent",
                .text = null,
                .first = "hotel india",
                .cont = "\u{21B3}     juliet kilo", // marker, gutter space, 4 of indent
            },
            .{
                .name = "wrap_indent = false starts the continuation at the edge",
                .text = "wrap_indent = false\n",
                .first = "hotel india",
                .cont = "\u{21B3} juliet kilo",
            },
            .{
                .name = "wrap_column narrows the rows",
                .text = "wrap_column = 40\n",
                .first = "alpha bravo charlie",
                .cont = "\u{21B3}     delta echo",
            },
        };
        for (layouts) |cs| {
            var argv_buf: [5][]const u8 = undefined;
            var argv: [][]const u8 = argv_buf[0..2];
            argv_buf[0] = ctx.zedit;
            if (cs.text) |t| {
                h.writeFile(ctx.io, cfg, t);
                argv_buf[1] = "--config";
                argv_buf[2] = cfg;
                argv_buf[3] = "long.txt";
                argv = argv_buf[0..4];
            } else argv_buf[1] = "long.txt";

            var s = try h.Session.spawn(ctx.gpa, .{ .argv = argv, .cwd = dir });
            defer s.finish();
            s.drain(500);
            const plain = try s.plain(ctx.gpa);
            defer ctx.gpa.free(plain);
            const ok = std.mem.indexOf(u8, plain, cs.first) != null and
                std.mem.indexOf(u8, plain, cs.cont) != null and
                // no word is drawn twice: the row ends at the break, not the edge
                std.mem.indexOf(u8, plain, "india juliet") == null;
            if (!ok) std.debug.print("       looked for \"{s}\" and \"{s}\"\n", .{ cs.first, cs.cont });
            ctx.check(cs.name, ok);
            s.send(":q!\r");
            s.drain(200);
        }

        // The caret follows the indent: gj from the start of the line lands on
        // the first character of the next row, which is a word start.
        h.writeFile(ctx.io, path, prose);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "long.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ "0", "gj", "x" }); // delete whatever the caret lands on
        s.drain(300);
        s.send(":wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        // Column 0 of row 1 is the indent; one row down, that same screen
        // column is the first letter of "juliet".
        const ok = std.mem.indexOf(u8, got, " uliet kilo") != null;
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check("gj keeps the screen column across an indented wrap", ok);
    }

    // --- L counts screen rows, so a wrapped line shortens its reach --------
    // 30 short lines after one that wraps twice: `L` must land on the last
    // line actually on screen, not on `top + rows - 1`.
    {
        var many: std.ArrayList(u8) = .empty;
        defer many.deinit(ctx.gpa);
        try many.appendNTimes(ctx.gpa, 'A', seg * 3); // three screen rows
        try many.append(ctx.gpa, '\n');
        var i: usize = 1;
        while (i <= 40) : (i += 1) {
            var b: [32]u8 = undefined;
            try many.appendSlice(ctx.gpa, std.fmt.bufPrint(&b, "line{d}\n", .{i}) catch break);
        }
        h.writeFile(ctx.io, path, many.items);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "long.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.send("Lx"); // delete the first character of the bottom visible line
        s.drain(250);
        s.send(":wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        // The window has 22 text rows (the title bar takes one). Three go to
        // the wrapped line, so the bottom row shows line19 — where counting
        // buffer lines would have put `L` on line21, below the last visible.
        ctx.check("L lands on the last line on screen, counting wrapped rows", std.mem.indexOf(u8, got, "\nine19\n") != null);
        ctx.check("L did not overshoot past the bottom of the screen", std.mem.indexOf(u8, got, "\nine22\n") == null);
    }
}
