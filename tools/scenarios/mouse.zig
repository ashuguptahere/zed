//! Mouse: the input-boundary carry that makes drag bursts safe, mouse mode
//! 1002 (button + motion-while-pressed), click-to-move-the-cursor,
//! drag-to-select, the multi-click gestures and the wheel, plus the `mouse`
//! and `mousetime` config keys.
//!
//! The vim-shaped semantics (operator-pending, counts, visual, curswant, the
//! jumplist, what a double click selects, Insert Visual) are pinned against
//! real nvim in `vim_compat`; what lives here is everything nvim has no
//! equivalent for — zedit's gutter, wrapped rows, diff panes, splits, the
//! explorer, the picker, the statusline label — plus the protocol itself and
//! the timing window, which a keystroke-driven suite cannot express.
//!
//! Clicks are sent as press+release pairs, the way a real terminal reports
//! them. In an 80-column window the title bar takes screen row 1 and the
//! gutter the first 5 columns, so buffer line `l` (1-based), byte `b` is
//! screen cell (l + 1, b + 6).

const std = @import("std");
const h = @import("../harness.zig");

/// A press+release pair at a 1-based screen cell.
fn click(comptime row: usize, comptime col: usize) []const u8 {
    return std.fmt.comptimePrint("\x1b[<0;{d};{d}M\x1b[<0;{d};{d}m", .{ col, row, col, row });
}
fn press(comptime row: usize, comptime col: usize) []const u8 {
    return std.fmt.comptimePrint("\x1b[<0;{d};{d}M", .{ col, row });
}
fn drag(comptime row: usize, comptime col: usize) []const u8 {
    return std.fmt.comptimePrint("\x1b[<32;{d};{d}M", .{ col, row });
}
fn release(comptime row: usize, comptime col: usize) []const u8 {
    return std.fmt.comptimePrint("\x1b[<0;{d};{d}m", .{ col, row });
}
/// `n` clicks at one cell in a single write, so they land well inside
/// `mousetime` however loaded the machine is.
fn multi(comptime n: usize, comptime row: usize, comptime col: usize) []const u8 {
    const one = comptime click(row, col);
    return one ** n;
}

pub fn run(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();
    const path = h.join(ctx, dir, "m.txt");
    defer ctx.gpa.free(path);
    const cfg = h.join(ctx, dir, "cfg");
    defer ctx.gpa.free(cfg);

    // ---- the read boundary -------------------------------------------------
    // A read that fills the input buffer exactly cannot use the short wait
    // that completes a split escape sequence, so the unfinished tail is held
    // back for the next read. Before that carry, the fragment decoded as a
    // bare Esc (dropping out of insert mode) and the rest ran as commands or
    // landed in the document. Drags make this routine: one across a window is
    // ~900 bytes of reports. The sweep covers every plausible buffer size, so
    // it keeps biting if the buffer is ever resized.
    {
        for ([_]usize{ 255, 511, 1023, 2047 }) |pad| {
            h.writeFile(ctx.io, path, "hello\nworld\n");
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
            defer s.finish();
            s.drain(400);
            s.send("i");
            s.drain(200);
            // One write: `pad` ordinary characters, then a Down arrow whose
            // ESC lands exactly on the boundary for a buffer of `pad + 1`.
            var burst: std.ArrayList(u8) = .empty;
            defer burst.deinit(ctx.gpa);
            try burst.appendNTimes(ctx.gpa, 'a', pad);
            try burst.appendSlice(ctx.gpa, "\x1b[B");
            s.send(burst.items);
            s.drain(600);
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const status = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(status);
            var name: [64]u8 = undefined;
            ctx.check(
                std.fmt.bufPrint(&name, "a split escape at byte {d} stays one key", .{pad}) catch "boundary",
                std.mem.indexOf(u8, status, "INSERT") != null,
            );
            s.send("\x1b:q!\r");
            s.drain(200);
        }
    }

    // The same burst made of mouse reports must not put a byte in the buffer.
    {
        h.writeFile(ctx.io, path, "hello\nworld\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        var burst: std.ArrayList(u8) = .empty;
        defer burst.deinit(ctx.gpa);
        try burst.append(ctx.gpa, 'i');
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var b: [24]u8 = undefined;
            try burst.appendSlice(ctx.gpa, std.fmt.bufPrint(&b, "\x1b[<32;{d};4M", .{20 + (i % 40)}) catch break);
        }
        s.send(burst.items); // one write: 1100+ bytes
        s.drain(600);
        s.send("\x1b:wq\r");
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        const ok = std.mem.eql(u8, got, "hello\nworld\n");
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check("a one-write burst of drag reports injects nothing", ok);
    }

    // ---- the protocol ------------------------------------------------------
    {
        h.writeFile(ctx.io, path, "hello\nworld\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        ctx.check("mouse mode 1002 is enabled", s.contains("\x1b[?1002h"));
        ctx.check("mode 1000 is not set alongside it", !s.contains("\x1b[?1000h"));
        ctx.check("SGR encoding is enabled", s.contains("\x1b[?1006h"));
        s.send(":q!\r");
        s.drain(300);
        ctx.check("both are disabled on the way out", s.contains("\x1b[?1002l"));
    }

    // `mouse = false` never asks the terminal to report, and a stray report
    // from a terminal some other program left in tracking mode stays inert.
    {
        h.writeFile(ctx.io, cfg, "mouse = false\n");
        h.writeFile(ctx.io, path, "hello\nworld\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg, "m.txt" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(400);
        // Not just 1002: *no* tracking mode of any encoding may be asked for,
        // or the terminal hands its own click-drag selection over for nothing.
        var asked = false;
        for ([_][]const u8{ "\x1b[?1000", "\x1b[?1002", "\x1b[?1003", "\x1b[?1005", "\x1b[?1006", "\x1b[?1015" }) |seq| {
            if (s.contains(seq)) asked = true;
        }
        ctx.check("mouse = false emits no reporting sequence at all", !asked);
        // Wheel, click, drag and release: every one inert, and the keyboard
        // untouched by them.
        s.send("\x1b[<65;5;5M\x1b[<64;5;5M");
        s.drain(200);
        s.send(click(3, 9));
        s.drain(200);
        s.sendKeys(&.{ press(2, 8), drag(3, 9), release(3, 9) });
        s.drain(300);
        s.send("x:wq\r");
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("mouse = false ignores every stray report", std.mem.eql(u8, got, "ello\nworld\n"));
    }

    // Modified reports are what a terminal sends when it does *not* bypass on
    // Shift (and always for Ctrl/Alt). zedit binds none of them, so a whole
    // modified press-drag-release must leave no selection and no armed drag.
    {
        h.writeFile(ctx.io, path, "alpha\nbeta\ngamma\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.send("\x1b[<4;10;4M\x1b[<36;20;5M\x1b[<4;20;5m"); // shift
        s.drain(200);
        s.send("\x1b[<16;10;4M\x1b[<48;20;5M\x1b[<16;20;5m"); // ctrl
        s.drain(200);
        s.send("\x1b[<8;10;4M\x1b[<40;20;5M\x1b[<8;20;5m"); // alt
        s.drain(300);
        var scr = try h.screenOf(ctx, &s, 24, 80);
        defer scr.deinit();
        const st = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(st);
        ctx.check("a modified gesture starts no selection", std.mem.indexOf(u8, st, "VISUAL") == null);
        ctx.check("a modified gesture moves no cursor", scr.cur_row == 2 and scr.cur_col == 6);
        s.send("dd:wq\r");
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("and leaves no armed drag behind", std.mem.eql(u8, got, "beta\ngamma\n"));
    }

    // showcmd: a press acts at once, so it clears the indicator rather than
    // leaving the pending command on it — otherwise the *next* command
    // appended to the stale text (`d` then `3` showed `d3`). nvim blanks that
    // cell for both, pty-probed.
    {
        h.writeFile(ctx.io, path, "alpha\nbeta\ngamma\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.send("d");
        s.drain(250);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(st);
            ctx.check("showcmd shows the pending operator", std.mem.indexOf(u8, st, "d \u{e0b2} text") != null);
        }
        s.send(click(2, 8));
        s.drain(300);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(st);
            ctx.check("a press that runs the operator clears showcmd", std.mem.indexOf(u8, st, "d \u{e0b2} text") == null);
        }
        s.send("3");
        s.drain(200);
        s.send(click(3, 7));
        s.drain(300);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(st);
            ctx.check("a discarded count leaves nothing on showcmd", std.mem.indexOf(u8, st, "3 \u{e0b2} text") == null and
                std.mem.indexOf(u8, st, "d3") == null);
        }
        s.send(":q!\r");
        s.drain(300);
    }

    // ---- where a click lands ----------------------------------------------
    // The gutter resolves to column 0, tabs and wide characters own every cell
    // they are drawn across, and clicks on the chrome move nothing.
    {
        const Case = struct { name: []const u8, keys: []const []const u8, want: []const u8 };
        const tabs = "a\tb\tcd\nx\u{4e2d}\u{6587}y\n";
        const cases = [_]Case{
            .{ .name = "a click lands on the byte under it", .keys = &.{ click(2, 6), "x" }, .want = "\tb\tcd\nx\u{4e2d}\u{6587}y\n" },
            .{ .name = "a click inside a tab lands on the tab", .keys = &.{ click(2, 8), "x" }, .want = "ab\tcd\nx\u{4e2d}\u{6587}y\n" },
            .{ .name = "a click past a tab lands after it", .keys = &.{ click(2, 10), "x" }, .want = "a\t\tcd\nx\u{4e2d}\u{6587}y\n" },
            .{ .name = "the first cell of a wide char lands on it", .keys = &.{ click(3, 7), "x" }, .want = "a\tb\tcd\nx\u{6587}y\n" },
            .{ .name = "the second cell of a wide char lands on it too", .keys = &.{ click(3, 8), "x" }, .want = "a\tb\tcd\nx\u{6587}y\n" },
            .{ .name = "a click in the gutter lands on column 1", .keys = &.{ click(3, 2), "x" }, .want = "a\tb\tcd\n\u{4e2d}\u{6587}y\n" },
            .{ .name = "a click on the title bar moves nothing", .keys = &.{ click(1, 40), "x" }, .want = "\tb\tcd\nx\u{4e2d}\u{6587}y\n" },
            .{ .name = "a click on the status line moves nothing", .keys = &.{ click(24, 40), "x" }, .want = "\tb\tcd\nx\u{4e2d}\u{6587}y\n" },
            .{ .name = "a click while the command line is open is inert", .keys = &.{ ":", click(3, 9), "\x1b", "x" }, .want = "\tb\tcd\nx\u{4e2d}\u{6587}y\n" },
        };
        for (cases) |c| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(ctx.gpa);
            try keys.appendSlice(ctx.gpa, c.keys);
            try keys.appendSlice(ctx.gpa, &.{ ":wq", "\r" });
            h.case(ctx, path, c.name, keys.items, tabs, c.want);
        }
    }

    // ---- soft wrap ---------------------------------------------------------
    // A continuation row draws the hanging indent first and ends at the word
    // break, not at the window edge: the indent cells must resolve to the
    // row's first character, and the padding past the break to its last —
    // never to the row below, which is where `place()` would send it.
    {
        const prose = "    indented alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november\nplain\n";
        const Case = struct { name: []const u8, cell: []const u8, want: []const u8 };
        const cases = [_]Case{
            .{ .name = "a click in the hanging indent lands on the row's first char", .cell = click(3, 7), .want = "uliet" },
            .{ .name = "a click on a continuation row's text lands there", .cell = click(3, 12), .want = "juiet" },
            .{ .name = "a click past a wrapped row's word break stays on that row", .cell = click(3, 80), .want = "novembe\n" },
        };
        for (cases) |c| {
            h.writeFile(ctx.io, path, prose);
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
            defer s.finish();
            s.drain(400);
            s.sendKeys(&.{ c.cell, "x", ":wq", "\r" });
            s.drain(500);
            const got = h.readFile(ctx.gpa, ctx.io, path);
            defer ctx.gpa.free(got);
            const ok = std.mem.indexOf(u8, got, c.want) != null;
            if (!ok) std.debug.print("       looked for \"{s}\" in \"{f}\"\n", .{ c.want, std.zig.fmtString(got) });
            ctx.check(c.name, ok);
        }
    }

    // ---- multi-click gestures ----------------------------------------------
    // The gestures themselves (what a double click selects, the 4-click cycle,
    // Insert Visual) are pinned against real nvim in `vim_compat`. What lives
    // here is everything nvim has no equivalent for: the timing window and its
    // config key, the statusline label, and zedit's own geometry — the gutter,
    // wrapped rows, splits, the `~` rows past EOF.
    {
        const G = "alpha beta gamma\nsecond line here\n";
        // Two clicks at one cell chain only while they are inside `mousetime`
        // of each other (500 ms by default, nvim's value): the count is derived
        // from the previous press, so a slow second click is a plain one.
        h.writeFile(ctx.io, path, G);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.send(click(2, 13));
        s.drain(200); // well inside the window
        s.send(click(2, 13));
        s.drain(300);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(st);
            ctx.check("a second click inside mousetime selects the word", std.mem.indexOf(u8, st, "VISUAL") != null);
        }
        // A different cell breaks the chain, so the slow pair below starts
        // fresh: two clicks 800 ms apart, which is past the default window.
        s.send("\x1b");
        s.drain(200);
        s.send(click(2, 14));
        s.drain(800);
        s.send(click(2, 14));
        s.drain(300);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(st);
            ctx.check("a second click past mousetime does not", std.mem.indexOf(u8, st, "VISUAL") == null);
        }
        s.send(":q!\r");
        s.drain(300);
    }
    // The config key is read, both ways: 0 turns multi-clicks off entirely,
    // and a longer window makes a click chain that the default would not.
    {
        const G = "alpha beta gamma\n";
        h.writeFile(ctx.io, cfg, "mousetime = 0\n");
        h.writeFile(ctx.io, path, G);
        {
            var s = try h.Session.spawn(ctx.gpa, .{
                .argv = &.{ ctx.zedit, "--config", cfg, "m.txt" },
                .cwd = dir,
            });
            defer s.finish();
            s.drain(400);
            s.send(multi(2, 2, 13)); // back to back, and still not a double click
            s.drain(300);
            s.send("x:wq\r");
            s.drain(500);
            const got = h.readFile(ctx.gpa, ctx.io, path);
            defer ctx.gpa.free(got);
            ctx.check("mousetime = 0 leaves every click a single click", std.mem.eql(u8, got, "alpha bta gamma\n"));
        }
        h.writeFile(ctx.io, cfg, "mousetime = 2000\n");
        h.writeFile(ctx.io, path, G);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg, "m.txt" },
            .cwd = dir,
        });
        defer s.finish();
        s.drain(400);
        s.send(click(2, 13));
        s.drain(800); // past the default 500, inside 2000
        s.send(click(2, 13));
        s.drain(300);
        s.send("d:wq\r");
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("a longer mousetime chains a slower click", std.mem.eql(u8, got, "alpha  gamma\n"));
    }
    // The statusline says which visual mode is up — and says so nvim's way for
    // a selection begun in insert mode, which returns to insert when it ends.
    {
        const Case = struct { name: []const u8, keys: []const []const u8, want: []const u8 };
        const cases = [_]Case{
            .{ .name = "a double click shows VISUAL", .keys = &.{multi(2, 2, 13)}, .want = " VISUAL " },
            .{ .name = "a triple click shows V-LINE", .keys = &.{multi(3, 2, 13)}, .want = " V-LINE " },
            .{ .name = "a quadruple click shows V-BLOCK", .keys = &.{multi(4, 2, 13)}, .want = " V-BLOCK " },
            .{ .name = "a drag out of insert shows (insert) VISUAL", .keys = &.{ "i", press(2, 8), drag(2, 13), release(2, 13) }, .want = " (insert) VISUAL " },
            .{ .name = "a triple click in insert shows (insert) V-LINE", .keys = &.{ "i", multi(3, 2, 13) }, .want = " (insert) V-LINE " },
            .{ .name = "Esc out of Insert Visual returns to insert", .keys = &.{ "i", multi(2, 2, 13), "\x1b" }, .want = " INSERT " },
            .{ .name = "a second Esc leaves insert", .keys = &.{ "i", multi(2, 2, 13), "\x1b", "\x1b" }, .want = " NORMAL " },
        };
        for (cases) |c| {
            h.writeFile(ctx.io, path, "alpha beta gamma\nsecond line here\n");
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
            defer s.finish();
            s.drain(400);
            s.sendKeys(c.keys);
            s.drain(300);
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(st);
            const ok = std.mem.indexOf(u8, st, c.want) != null;
            if (!ok) std.debug.print("       looked for \"{s}\" in \"{s}\"\n", .{ c.want, st });
            ctx.check(c.name, ok);
            s.send("\x1b\x1b:q!\r");
            s.drain(200);
        }
    }
    // zedit's own geometry: nvim has no gutter, no `~` rows under a click and
    // no window to focus, so these have no vim_compat counterpart.
    {
        // The gutter resolves to column 0, so a double click there takes the
        // line's first word.
        h.case(ctx, path, "a double click in the gutter takes the first word", &.{
            multi(2, 2, 2), "d", ":wq", "\r",
        }, "alpha beta gamma\n", " beta gamma\n");
        // A `~` row past the end of the file snaps to the last line.
        h.case(ctx, path, "a double click past EOF takes the last line's word", &.{
            multi(2, 20, 8), "d", ":wq", "\r",
        }, "alpha beta\nsecond line\n", "alpha beta\n line\n");
        // On a wrapped line the word under the pointer is found on the
        // continuation row, not on the line's first row.
        h.case(ctx, path, "a double click on a continuation row takes its word", &.{
            multi(2, 3, 12), "d", ":wq", "\r",
        }, "    indented alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november\n", "    indented alpha bravo charlie delta echo foxtrot golf hotel india  kilo lima mike november\n");
        // A press on chrome breaks the chain, wherever it lands: the count is
        // derived for *every* press, before the click is routed anywhere
        // (vim's rule, pinned for the command row in `vim_compat`). zedit's
        // title bar has no nvim counterpart, so it is checked here — column 70
        // is past the single tab, so the press does nothing at all, and the
        // click after it must still be a plain one.
        h.case(ctx, path, "two clicks at one cell chain", &.{
            comptime click(2, 13) ++ click(2, 13), "x", ":wq", "\r",
        }, "alpha beta gamma\n", "alpha  gamma\n");
        h.case(ctx, path, "a press on the title bar breaks the click chain", &.{
            comptime click(2, 13) ++ click(1, 70) ++ click(2, 13), "x", ":wq", "\r",
        }, "alpha beta gamma\n", "alpha bta gamma\n");
    }

    // ---- drag ---------------------------------------------------------------
    {
        // The selection is anchored at the *press*, not at the first motion —
        // which already lands a cell or more away.
        h.case(ctx, path, "a drag yanks exactly the dragged span", &.{
            press(2, 12), drag(2, 16), drag(3, 9), release(3, 9), "y", "P", ":wq", "\r",
        }, "alpha bravo charlie\nsecond line here\n", "alpha bravo charlie\nsecobravo charlie\nsecond line here\n");
        // A drag that wanders off the window clamps to what is on screen
        // instead of stranding the selection, and the release ends it: the
        // following `j` is an ordinary motion again.
        h.case(ctx, path, "a drag off the window clamps and then releases", &.{
            press(2, 6), drag(30, 200), release(30, 200), "\x1b", "j", "x", ":wq", "\r",
        }, "aaa\nbbb\nccc\n", "aaa\nbbb\ncc\n");
        // A motion with no press behind it invents no anchor.
        h.case(ctx, path, "a drag with no press is inert", &.{ drag(3, 8), release(3, 8), "x", ":wq", "\r" }, "aaa\nbbb\n", "aa\nbbb\n");
        // A drag begun in insert mode anchors at the insert cursor, which may
        // sit one past the last character; nvim keeps it there rather than
        // clamping. The `d` lands back in insert (Insert Visual), so the Esc
        // before `:wq` is part of the ground truth: nvim run with the same
        // gesture saves `abcf` only with it.
        h.case(ctx, path, "a drag out of insert keeps the insert anchor", &.{
            "i", press(2, 20), drag(3, 7), release(3, 7), "d", "\x1b", ":wq", "\r",
        }, "abc\ndef\n", "abcf\n");
    }

    // Closing the window the drag started in must not strand a pointer.
    {
        h.writeFile(ctx.io, path, "aaa\nbbb\nccc\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ ":split", "\r", press(3, 8) });
        s.send(":close\r"); // mid-drag, no release
        s.drain(400);
        s.sendKeys(&.{ drag(4, 10), release(4, 10), "\x1b", "x", ":wq", "\r" });
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("closing the window mid-drag does not crash", got.len > 0);
    }

    // ---- splits ------------------------------------------------------------
    {
        h.writeFile(ctx.io, path, "aaa\nbbb\nccc\nddd\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ ":vsplit", "\r" }); // focus lands on the new right pane
        s.drain(300);
        s.send(click(4, 8)); // left pane, line 3
        s.drain(400);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const left = try scr.rowText(ctx.gpa, 23);
            defer ctx.gpa.free(left);
            ctx.check("a click in another pane focuses it", std.mem.indexOf(u8, left, "m.txt  3:1") != null);
            ctx.check("and lands on the clicked row", scr.cur_row == 4 and scr.cur_col == 8);
        }
        // The per-window status row belongs to no window.
        s.send(click(23, 8));
        s.drain(300);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            ctx.check("a click on a window status row moves nothing", scr.cur_row == 4 and scr.cur_col == 8);
        }
        s.send(":qa!\r");
        s.drain(300);
    }

    // ---- the wheel ---------------------------------------------------------
    // The notch scrolls the window *under the pointer*, focused or not, and
    // never moves focus — nvim's rule, probed. With `:split` the top window
    // has rows 2-11 (status row 12) and the bottom one rows 13-22 (status
    // row 23), so the two are addressable by row alone.
    {
        const long = "L001 line\nL002 line\nL003 line\nL004 line\nL005 line\nL006 line\nL007 line\nL008 line\nL009 line\nL010 line\nL011 line\nL012 line\nL013 line\nL014 line\nL015 line\nL016 line\nL017 line\nL018 line\nL019 line\nL020 line\n";
        const other = h.join(ctx, dir, "o.txt");
        defer ctx.gpa.free(other);
        h.writeFile(ctx.io, path, long);
        h.writeFile(ctx.io, other, "S1\nS2\nS3\nS4\nS5\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ ":split", "\r", ":e o.txt", "\r" }); // focus = the bottom window
        s.drain(400);
        s.send("\x1b[<65;10;5M"); // wheel down over the *top* window
        s.drain(400);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const top = try scr.rowText(ctx.gpa, 2);
            defer ctx.gpa.free(top);
            const st1 = try scr.rowText(ctx.gpa, 12);
            defer ctx.gpa.free(st1);
            const st2 = try scr.rowText(ctx.gpa, 23);
            defer ctx.gpa.free(st2);
            ctx.check("the wheel scrolls the window under the pointer", std.mem.indexOf(u8, top, "L004") != null);
            ctx.check("…carrying that window's cursor with it", std.mem.indexOf(u8, st1, "m.txt  4:1") != null);
            ctx.check("…leaving the focused window alone", std.mem.indexOf(u8, st2, "o.txt  1:1") != null);
            ctx.check("…and never moving focus", scr.cur_row >= 13 and scr.cur_row <= 22);
        }
        // Over the focused window it still scrolls that one.
        s.send("\x1b[<65;10;15M");
        s.drain(400);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st1 = try scr.rowText(ctx.gpa, 12);
            defer ctx.gpa.free(st1);
            const st2 = try scr.rowText(ctx.gpa, 23);
            defer ctx.gpa.free(st2);
            ctx.check("a notch over the focused window scrolls it", std.mem.indexOf(u8, st2, "o.txt  4:1") != null);
            ctx.check("…and leaves the other one where it was", std.mem.indexOf(u8, st1, "m.txt  4:1") != null);
        }
        // A status row belongs to the window above it, so a notch there
        // scrolls *that* window — not the focused one (nvim-probed: with the
        // focus on the other window it is still the hovered one that moves).
        s.send("\x1b[<64;10;12M"); // wheel up on the top window's status row
        s.drain(400);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st1 = try scr.rowText(ctx.gpa, 12);
            defer ctx.gpa.free(st1);
            const st2 = try scr.rowText(ctx.gpa, 23);
            defer ctx.gpa.free(st2);
            ctx.check("a notch on a status row scrolls the window it belongs to", std.mem.indexOf(u8, st1, "m.txt  1:1") != null);
            ctx.check("…not the focused one", std.mem.indexOf(u8, st2, "o.txt  4:1") != null);
        }
        // Cells no window owns at all (the title bar, the explorer) fall back
        // to the focused window rather than doing nothing.
        s.send("\x1b[<64;10;1M"); // wheel up on the title bar
        s.drain(400);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st2 = try scr.rowText(ctx.gpa, 23);
            defer ctx.gpa.free(st2);
            ctx.check("a notch on the title bar scrolls the focused window", std.mem.indexOf(u8, st2, "o.txt  1:1") != null);
        }
        s.sendKeys(&.{ " e", "\x1b" }); // explorer open, focus back on the buffer
        s.drain(400);
        s.send("\x1b[<65;5;15M"); // wheel down inside the tree's columns
        s.drain(400);
        {
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const st2 = try scr.rowText(ctx.gpa, 23);
            defer ctx.gpa.free(st2);
            ctx.check("a notch over the explorer scrolls the focused window", std.mem.indexOf(u8, st2, "o.txt  4:1") != null);
        }
        s.send(":qa!\r");
        s.drain(300);
    }

    // ---- the explorer ------------------------------------------------------
    // With the tree focused, a click in the text area must hand the keyboard
    // back — otherwise the cursor moves and the next `j` still walks the tree.
    {
        h.writeFile(ctx.io, path, "aaa\nbbb\nccc\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ " e", click(2, 45), "j", "x", ":wq", "\r" });
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("a text click takes focus back from the explorer", std.mem.eql(u8, got, "aaa\nbb\nccc\n"));
    }

    // ---- the picker --------------------------------------------------------
    {
        h.writeFile(ctx.io, path, "aaa\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ " ff", press(10, 40), drag(12, 50), release(12, 50) });
        s.drain(400);
        var scr = try h.screenOf(ctx, &s, 24, 80);
        defer scr.deinit();
        const status = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(status);
        ctx.check("a drag in the picker selects nothing", std.mem.indexOf(u8, status, "VISUAL") == null);
        s.send("\x1b:q!\r");
        s.drain(300);
    }

    // ---- the diff views ----------------------------------------------------
    {
        const repo = try ctx.tempDir();
        const d = h.join(ctx, repo, "d.txt");
        defer ctx.gpa.free(d);
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", repo, "init", "-q" });
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", repo, "config", "user.email", "t@t.t" });
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", repo, "config", "user.name", "t" });
        h.writeFile(ctx.io, d, "old1\nold2\nold3\nl04\nl05\nl06\n");
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", repo, "add", "d.txt" });
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", repo, "commit", "-qm", "x" });
        h.writeFile(ctx.io, d, "l04\nl05\nl06\n");

        // Side by side: the worktree pane opens with three filler rows on top
        // (the deleted old1..old3). A click on one has no buffer position, so
        // it snaps to the next real line rather than a phantom row.
        {
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "d.txt" }, .cwd = repo });
            defer s.finish();
            s.drain(600);
            s.sendKeys(&.{ " gs", click(2, 10) });
            s.drain(400);
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            ctx.check("a click on a diff filler snaps to a real line", scr.cur_row == 5);
            // The index pane is a read-only snapshot: a click focuses it, and
            // an edit there is still refused.
            s.send(click(6, 50));
            s.drain(400);
            s.send("x");
            s.drain(400);
            var scr2 = try h.screenOf(ctx, &s, 24, 80);
            defer scr2.deinit();
            const status = try scr2.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(status);
            ctx.check("a click focuses the index pane", scr2.cur_row == 6 and scr2.cur_col > 40);
            ctx.check("the index pane stays read-only", std.mem.indexOf(u8, status, "read-only") != null);
            s.send(":qa!\r");
            s.drain(300);
        }

        // The panes scroll in lockstep, and that lockstep is derived from the
        // *focused* pane every frame — so a wheel notch over the unfocused one
        // has to be routed to its partner. Writing the hovered pane's own top
        // instead would be undone by `syncDiffPanes` before the frame, and
        // nothing at all would move.
        {
            const long = h.join(ctx, repo, "long.txt");
            defer ctx.gpa.free(long);
            h.writeFile(ctx.io, long, "line01\nline02\nline03\nline04\nline05\nline06\nline07\nline08\nline09\nline10\nline11\nline12\nline13\nline14\nline15\n");
            h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", repo, "add", "long.txt" });
            h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", repo, "commit", "-qm", "y" });
            h.writeFile(ctx.io, long, "line01\nline02\nline03\nline04\nline05\nline06\nline07\nCHANGED\nline09\nline10\nline11\nline12\nline13\nline14\nline15\n");
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "long.txt" }, .cwd = repo });
            defer s.finish();
            s.drain(600);
            s.sendKeys(&.{" gs"}); // focus stays on the worktree (left) pane
            s.drain(500);
            s.send("\x1b[<65;60;10M"); // wheel down over the index (right) pane
            s.drain(500);
            var scr = try h.screenOf(ctx, &s, 24, 80);
            defer scr.deinit();
            const row2 = try scr.rowText(ctx.gpa, 2);
            defer ctx.gpa.free(row2);
            const st = try scr.rowText(ctx.gpa, 23);
            defer ctx.gpa.free(st);
            ctx.check("a notch over the index pane still scrolls the pair", std.mem.indexOf(u8, row2, "line04") != null and
                std.mem.lastIndexOf(u8, row2, "line04") != std.mem.indexOf(u8, row2, "line04"));
            ctx.check("…through the pane that drives the lockstep", std.mem.indexOf(u8, st, "long.txt  4:1") != null);
            ctx.check("…without moving focus off the worktree pane", scr.cur_col < 40);
            s.send(":qa!\r");
            s.drain(300);
        }

        // The line view weaves the old lines in above the ones that replaced
        // them; a click on one counts for the line below it, as H/M/L do.
        {
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "d.txt" }, .cwd = repo });
            defer s.finish();
            s.drain(600);
            s.sendKeys(&.{ " gl", click(3, 8), "x", ":w", "\r" });
            s.drain(500);
            const got = h.readFile(ctx.gpa, ctx.io, d);
            defer ctx.gpa.free(got);
            ctx.check("a click on a woven row edits the line below it", std.mem.eql(u8, got, "l0\nl05\nl06\n"));
            s.send(":qa!\r");
            s.drain(300);
        }
    }

    // ---- renderer vs hit-test ----------------------------------------------
    // The invariant the shared `RowWalk` exists to guarantee, checked
    // exhaustively rather than by example: click *every* cell the renderer
    // drew a plain ASCII glyph into and the cursor must land on that very
    // cell. Anything the two disagree about shows up as a miss.
    {
        const Layout = struct { name: []const u8, text: []const u8, cfg: ?[]const u8, keys: []const []const u8, rows: []const usize };
        const layouts = [_]Layout{
            // Soft wrap with hanging indent, plus a word wider than the row.
            .{
                .name = "wrapped rows",
                .text = "    aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt uuu vvv www\n" ++
                    "            deep word word word word word word word word word word word word word word word\n" ++
                    "aVeryLongUnbrokenWordWiderThanTheWindowIsAndThereforeBrokenMidWordInsteadOfAtASpace12345678\n",
                .cfg = null,
                .keys = &.{},
                .rows = &.{ 2, 3, 4, 5, 6, 7, 8, 9 },
            },
            // Tabs, whose rendered width depends on the column they start at.
            .{ .name = "tab stops", .text = "ab\tcd\tef\tgh\n\tlead\nx\ty\tz\nplain text\n", .cfg = null, .keys = &.{}, .rows = &.{ 2, 3, 4, 5 } },
            // Horizontal scrolling: the inverse has to add the window's left.
            .{
                .name = "horizontal scroll",
                .text = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop\nsecond\n",
                .cfg = "soft_wrap = false\n",
                .keys = &.{"$"},
                .rows = &.{ 2, 3 },
            },
            // Two panes side by side: the second one starts at its own gx.
            .{ .name = "vertical split", .text = "alpha beta gamma\ndelta epsilon\nzeta eta theta\niota kappa\n", .cfg = null, .keys = &.{ ":vsplit", "\r" }, .rows = &.{ 2, 3, 4, 5 } },
        };
        for (layouts) |lay| {
            h.writeFile(ctx.io, path, lay.text);
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(ctx.gpa);
            try argv.append(ctx.gpa, ctx.zedit);
            if (lay.cfg) |text| {
                h.writeFile(ctx.io, cfg, text);
                try argv.appendSlice(ctx.gpa, &.{ "--config", cfg });
            }
            try argv.append(ctx.gpa, "m.txt");
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = argv.items, .cwd = dir });
            defer s.finish();
            s.drain(500);
            if (lay.keys.len > 0) {
                s.sendKeys(lay.keys);
                s.drain(300);
            }
            var base = try h.screenOf(ctx, &s, 24, 80);
            defer base.deinit();
            var bad: usize = 0;
            var tested: usize = 0;
            for (lay.rows) |r| {
                var col: usize = 1;
                while (col <= 80) : (col += 1) {
                    const cp = base.at(r, col).cp;
                    // Gutter digits and `↳`/`~` are chrome, not buffer text:
                    // they resolve to column 0 by design (nvim's rule too).
                    if (cp == ' ' or cp == 0 or cp > 127 or col % 40 < 6) continue;
                    var b: [48]u8 = undefined;
                    s.send(std.fmt.bufPrint(&b, "\x1b[<0;{d};{d}M\x1b[<0;{d};{d}m", .{ col, r, col, r }) catch continue);
                    s.drain(60);
                    var scr = try h.screenOf(ctx, &s, 24, 80);
                    defer scr.deinit();
                    tested += 1;
                    if (scr.cur_row != r or scr.cur_col != col) {
                        bad += 1;
                        std.debug.print("       ({d},{d}) '{u}' -> ({d},{d})\n", .{ r, col, cp, scr.cur_row, scr.cur_col });
                    }
                }
            }
            var name: [96]u8 = undefined;
            ctx.check(
                std.fmt.bufPrint(&name, "every drawn cell is clickable where it was drawn: {s} ({d} cells)", .{ lay.name, tested }) catch lay.name,
                bad == 0 and tested > 20,
            );
            s.send(":qa!\r");
            s.drain(300);
        }
    }

    // ---- the read boundary, byte by byte -----------------------------------
    // The sweep above varies the buffer size; this one varies the *split*,
    // putting the boundary on each byte of a sequence in turn — the offsets a
    // real drag burst hits at random. Every sequence below is a no-op in
    // insert mode on a single line, so the line must still hold exactly the
    // filler and the mode must still be INSERT.
    {
        const seqs = [_][]const u8{
            "\x1b[B", // a CSI arrow: split after ESC and after "["
            "\x1b[3~", // a longer CSI, split before its final byte too
            "\x1bOA", // SS3, which is exactly three bytes
            "\x1b[<32;10;3M", // a drag report: the shape a burst is made of
            "\x1b[200~\x1b[201~", // an empty bracketed paste, fences included
        };
        h.writeFile(ctx.io, path, "");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.send("i");
        s.drain(150);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(ctx.gpa);
        var bad: usize = 0;
        var tested: usize = 0;
        for (seqs) |seq| {
            var k: usize = 1;
            while (k < seq.len) : (k += 1) {
                const pad = 1024 - k; // = inbuf.len - k: the split lands on byte k
                line.clearRetainingCapacity();
                try line.appendNTimes(ctx.gpa, 'a', pad);
                try line.appendSlice(ctx.gpa, seq);
                s.send(line.items); // one write, so the reads split it
                s.drain(400);
                var scr = try h.screenOf(ctx, &s, 24, 80);
                defer scr.deinit();
                const st = try scr.rowText(ctx.gpa, 24);
                defer ctx.gpa.free(st);
                var want: [48]u8 = undefined;
                const w = std.fmt.bufPrint(&want, "Ln 1, Col {d}", .{pad + 1}) catch continue;
                tested += 1;
                if (std.mem.indexOf(u8, st, "INSERT") == null or std.mem.indexOf(u8, st, w) == null) {
                    bad += 1;
                    std.debug.print("       split@{d} of {f}: |{s}|\n", .{ k, std.zig.fmtString(seq), st });
                }
                s.send("\x1bggVGdi"); // reset to one empty line, still in insert
                s.drain(250);
            }
        }
        var name: [96]u8 = undefined;
        ctx.check(
            std.fmt.bufPrint(&name, "a sequence split at any byte of itself still decodes whole ({d} offsets)", .{tested}) catch "split offsets",
            bad == 0 and tested > 10,
        );
        s.send("\x1b:q!\r");
        s.drain(300);
    }

    // ---- drag under interference -------------------------------------------
    {
        // A resize mid-drag re-tiles the window under the pointer; the drag
        // must keep extending in the new geometry, not strand or crash.
        h.writeFile(ctx.io, path, "alpha bravo\ncharlie delta\necho foxtrot\ngolf hotel\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.send(press(3, 8));
        s.drain(200);
        s.send(drag(4, 9));
        s.drain(200);
        s.resize(12, 40);
        s.drain(400);
        s.send(drag(5, 10));
        s.drain(200);
        s.send(release(5, 10));
        s.drain(200);
        s.send("d:w\r");
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("a drag survives a resize and still deletes its span", std.mem.eql(u8, got, "alpha bravo\nchhotel\n"));
        // …and nothing is left armed: a later stray motion must do nothing.
        s.send(drag(3, 20));
        s.drain(200);
        s.send("x:w\r");
        s.drain(400);
        const after = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(after);
        ctx.check("and leaves no armed drag after the resize", std.mem.eql(u8, after, "alpha bravo\nchotel\n"));
        s.send(":q!\r");
        s.drain(300);
        s.resize(24, 80);
    }
    {
        // Wandering into the explorer's columns mid-drag clamps back into the
        // window it started in; the release still ends the drag.
        h.writeFile(ctx.io, path, "alpha bravo charlie\ndelta echo\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ " e", "\x1b" }); // open the tree, focus back on the buffer
        s.drain(300);
        s.send(press(3, 40));
        s.drain(200);
        s.send(drag(3, 2)); // deep inside the tree
        s.drain(200);
        s.send(release(24, 2)); // and the release outside the text area entirely
        s.drain(300);
        s.send("\x1bj");
        s.drain(200);
        s.send("x:wq\r");
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("a drag into the explorer clamps and releases cleanly", std.mem.indexOf(u8, got, "alpha bravo charlie\n") != null and got.len < 31);
    }

    // ---- cost --------------------------------------------------------------
    // Mode 1002 reports nothing while the mouse is idle, so the editor still
    // blocks in poll(2) at zero CPU; a drag burst costs a bounded amount and
    // arms no timer.
    {
        h.writeFile(ctx.io, path, "line of text here\n" ** 200);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "m.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(500);

        var burst: std.ArrayList(u8) = .empty;
        defer burst.deinit(ctx.gpa);
        try burst.appendSlice(ctx.gpa, press(3, 8));
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            var b: [24]u8 = undefined;
            try burst.appendSlice(ctx.gpa, std.fmt.bufPrint(&b, "\x1b[<32;{d};{d}M", .{ 6 + (i % 60), 2 + (i % 20) }) catch break);
        }
        try burst.appendSlice(ctx.gpa, release(3, 8));
        const t0 = try s.cpuTicks(ctx.gpa, ctx.io);
        s.send(burst.items);
        s.drain(1500);
        const t1 = try s.cpuTicks(ctx.gpa, ctx.io);
        s.drain(2000); // then sit idle
        const t2 = try s.cpuTicks(ctx.gpa, ctx.io);
        const per_ms = @as(f64, @floatFromInt(h.clockTicksPerSec()));
        const drag_ms = @as(f64, @floatFromInt(t1 - t0)) / per_ms * 1000.0;
        const idle_ms = @as(f64, @floatFromInt(t2 - t1)) / per_ms * 1000.0;
        std.debug.print("  202 drag reports: {d:.0} ms CPU; 2s idle after: {d:.0} ms\n", .{ drag_ms, idle_ms });
        ctx.check("a 200-report drag burst costs bounded CPU (<500ms)", drag_ms < 500.0);
        ctx.check("the editor is back to zero CPU after a drag (<40ms/2s)", idle_ms < 40.0);
        s.send(":q!\r");
        s.drain(300);
    }
}
