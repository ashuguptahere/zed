//! Visual rendering (true-color, powerline, syntax) and editing built-ins
//! (auto-pairs, comment toggle). Port of tools/feature_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const BS = "\x7f";
const target = "/tmp/zedit_it_feat.txt";

pub fn run(ctx: *h.Ctx) !void {
    // ---- `:w` creates missing parent directories (VS Code's rule) ----------
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ctx.zedit}, .cwd = dir });
        defer s.finish();
        s.drain(500);
        s.send(ESC); // dismiss the startup screen (`q` there quits)
        s.drain(200);
        s.send("ihi" ++ ESC ++ ":w deep/er/note.txt" ++ CR);
        s.drain(600);
        ctx.check("writing under a missing directory succeeds", s.containsPlain(ctx.gpa, "\"deep/er/note.txt\" written"));
        s.send(":q!" ++ CR);
        s.drain(200);
        const made = h.join(ctx, dir, "deep/er/note.txt");
        defer ctx.gpa.free(made);
        const got = h.readFile(ctx.gpa, ctx.io, made);
        defer ctx.gpa.free(got);
        ctx.check("the directories were created on the way", std.mem.eql(u8, got, "hi\n"));
    }

    // ---- `Space u` UI toggles ---------------------------------------------
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const f = h.join(ctx, dir, "t.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "alpha\nbeta\ngamma\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "t.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(600);
        var m = s.out.items.len;
        s.send(" ");
        s.drain(300);
        ctx.check("Space lists the UI-toggles group", s.containsPlainSince(ctx.gpa, m, "UI toggles"));
        s.send("u");
        s.drain(300);
        ctx.check("Space u lists the toggles", s.containsPlain(ctx.gpa, "soft wrap") and
            s.containsPlain(ctx.gpa, "buffer tabs"));
        // The tabline is on by default: toggling it off must remove the row.
        m = s.out.items.len;
        s.send("t");
        s.drain(400);
        ctx.check("Space u t reports the new state", s.containsPlainSince(ctx.gpa, m, "buffer tabs: off"));
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row1 = try scr.rowText(ctx.gpa, 1);
        defer ctx.gpa.free(row1);
        ctx.check("Space u t actually removes the tabline", std.mem.indexOf(u8, row1, "t.txt") == null);
        m = s.out.items.len;
        s.send(" ut");
        s.drain(400);
        ctx.check("Space u t toggles back on", s.containsPlainSince(ctx.gpa, m, "buffer tabs: on"));
        // A toggle with a visible geometry change: numbers.
        m = s.out.items.len;
        s.send(" un");
        s.drain(400);
        ctx.check("Space u n toggles relative numbers", s.containsPlainSince(ctx.gpa, m, "relative numbers:"));
        s.send(":q!" ++ CR);
        s.drain(200);
    }

    // ---- visual rendering (needs a .zig file for language detection) ----
    const zig_target = "/tmp/zedit_it_feat.zig";
    const zig_src =
        "const std = @import(\"std\");\n" ++
        "pub fn main() void {\n" ++
        "        const x = 42; // hi\n" ++ // 8-space indent -> indent guide at col 4
        "}\n";
    h.writeFile(ctx.io, zig_target, zig_src);
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, zig_target }, .term = "xterm-256color" });
        defer s.finish();
        s.drain(800); // first frame; let colours be emitted

        ctx.check("true-color foreground escapes", s.contains("\x1b[38;2;"));
        ctx.check("true-color background escapes", s.contains("\x1b[48;2;"));
        ctx.check("powerline separator glyph", s.contains("\xee\x82\xb0")); // U+E0B0
        ctx.check("keyword color (const/pub/fn)", s.contains("\x1b[38;2;187;154;247m")); // theme.keyword
        ctx.check("string color", s.contains("\x1b[38;2;158;206;106m")); // theme.string_
        ctx.check("number color", s.contains("\x1b[38;2;255;158;100m")); // theme.number
        ctx.check("indent guide glyph", s.contains("\xe2\x94\x82")); // U+2502
        ctx.check("mode label NORMAL shown", s.contains("NORMAL"));

        s.send("\x1b:q!\r");
        s.drain(300);
    }
    h.removeFile(ctx.io, zig_target);

    // ---- auto-pairs ----
    h.case(ctx, target, "autopair inserts closer", &.{ "i", "(", "x", ESC, ":wq", CR }, "", "(x)\n");
    h.case(ctx, target, "autopair steps over closer", &.{ "i", "(", ")", ESC, ":wq", CR }, "", "()\n");
    // The emptied (but once-edited) line writes "\n", not 0 bytes — verified
    // against nvim (see vim_compat.zig and Buffer.emptied).
    h.case(ctx, target, "backspace deletes empty pair", &.{ "i", "(", BS, ESC, ":wq", CR }, "", "\n");
    h.case(ctx, target, "autopair quotes", &.{ "i", "\"", "hi", ESC, ":wq", CR }, "", "\"hi\"\n");

    // ---- comment toggle ----
    h.case(ctx, target, "gcc comments line", &.{ "gcc", ":wq", CR }, "abc\n", "// abc\n");
    h.case(ctx, target, "gcc twice toggles back", &.{ "gcc", "gcc", ":wq", CR }, "abc\n", "abc\n");
    h.case(ctx, target, "gcj comments two lines", &.{ "gcj", ":wq", CR }, "a\nb\nc\n", "// a\n// b\nc\n");

    // ---- showcmd: the partial command as typed (vim's 'showcmd') ----
    // The indicator accumulates keys while a command is incomplete and clears
    // the instant it executes, matching nvim (whose 'showcmd' is on by
    // default). Assertions look only at the frames each step produced.
    {
        const path = "/tmp/zedit_it_showcmd.txt";
        h.writeFile(ctx.io, path, "xxx yyy zzz\nqqq\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, path }, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);

        // A special key shows its NAME, never its escape sequence. This is a
        // deliberate divergence from nvim, which renders nothing for a bare
        // <Down>/<Esc>/<PageDown> (0.12.4 --clean, pty at 100x24: last row
        // stays empty after each) — the owner wants to see the key that
        // acted. The bug being guarded is the original one: showcmd used to
        // capture the raw escape bytes and paint ^[[B / ^[ / ^[[6~.
        var m = s.mark();
        s.send("\x1b[B"); // Down
        s.drain(250);
        ctx.check("an arrow renders its name", s.containsPlainSince(ctx.gpa, m, "<Down>"));
        ctx.check("an arrow never renders its sequence", !s.containsPlainSince(ctx.gpa, m, "^["));
        m = s.mark();
        s.send("\x1b[6~"); // PageDown
        s.drain(250);
        ctx.check("a paging key renders its name", s.containsPlainSince(ctx.gpa, m, "<PageDown>"));
        ctx.check("a paging key never renders its sequence", !s.containsPlainSince(ctx.gpa, m, "^["));
        m = s.mark();
        s.send("\x1b"); // bare Esc
        s.drain(250);
        ctx.check("a bare Esc renders its name", s.containsPlainSince(ctx.gpa, m, "<Esc>"));
        ctx.check("a bare Esc never renders its sequence", !s.containsPlainSince(ctx.gpa, m, "^["));
        s.send("gg");
        s.drain(150);

        m = s.mark();
        s.send("2");
        s.drain(250);
        ctx.check("showcmd shows a pending count", s.containsPlainSince(ctx.gpa, m, "2 "));

        // nvim (pty-probed): `2` then <Down> executes the counted motion and
        // the indicator clears — the arrow's bytes never show. (The clearing
        // itself is asserted via Esc/yy below; the cursor move redraws the
        // gutter's line numbers, so a "2 " negative would false-fail here.)
        m = s.mark();
        s.send("\x1b[B");
        s.drain(250);
        ctx.check("a special key executes the count and clears", !s.containsPlainSince(ctx.gpa, m, "^["));
        s.send("gg");
        s.drain(150);

        m = s.mark();
        s.send("2");
        s.drain(250);
        s.send("d");
        s.drain(250);
        ctx.check("showcmd shows count + operator", s.containsPlainSince(ctx.gpa, m, "2d "));

        m = s.mark();
        s.send("\x1b"); // abandon it
        s.drain(250);
        ctx.check("Esc clears the indicator", !s.containsPlainSince(ctx.gpa, m, "2d ") and
            !s.containsPlainSince(ctx.gpa, m, "^["));

        m = s.mark();
        s.send("\"a");
        s.drain(250);
        ctx.check("showcmd shows a pending register", s.containsPlainSince(ctx.gpa, m, "\"a "));

        m = s.mark();
        s.send("y");
        s.drain(250);
        ctx.check("showcmd shows register + operator", s.containsPlainSince(ctx.gpa, m, "\"ay "));

        m = s.mark();
        s.send("y"); // "ayy completes
        s.drain(250);
        ctx.check("executing clears the indicator", !s.containsPlainSince(ctx.gpa, m, "\"ay "));

        m = s.mark();
        s.send("d");
        s.drain(200);
        s.send("iw"); // completes diw
        s.drain(300);
        ctx.check("finished command stays visible", s.containsPlainSince(ctx.gpa, m, "diw "));
        m = s.mark();
        s.send("j"); // the next command clears the previous one
        s.drain(250);
        ctx.check("the next command clears the previous", !s.containsPlainSince(ctx.gpa, m, "diw "));

        m = s.mark();
        s.send("\x17"); // Ctrl-w: a pending window command shows as ^W
        s.drain(250);
        ctx.check("control keys show in caret notation", s.containsPlainSince(ctx.gpa, m, "^W "));
        s.send("\x1b");
        s.drain(150);

        m = s.mark();
        s.send("d");
        s.drain(250);
        ctx.check("showcmd shows the pending operator", s.containsPlainSince(ctx.gpa, m, "d "));
        // nvim (pty-probed): `d` then <Down> executes and clears — no ^[[B
        // on the statusline, and no lingering "d ".
        m = s.mark();
        s.send("\x1b[B");
        s.drain(250);
        ctx.check("operator + special key executes and clears", !s.containsPlainSince(ctx.gpa, m, "d ") and
            !s.containsPlainSince(ctx.gpa, m, "^["));
        s.send("u");
        s.drain(150);

        m = s.mark();
        s.send("qa"); // start recording into register a
        s.drain(250);
        ctx.check("recording marker still shows", s.containsPlainSince(ctx.gpa, m, "REC @a"));
        s.send("q:q!\r");
        s.drain(300);
    }

    // ---- showcmd is display-only: macros and dot-repeat keep raw bytes ----
    // Recording `qa x <Down> q`, replaying `2@a`, then `d<Down>` and `.`:
    // the arrow must still replay from its stored escape bytes — only the
    // indicator's capture changed, never the macro/dot buffers.
    {
        const path = "/tmp/zedit_it_showcmd_replay.txt";
        h.writeFile(ctx.io, path, "a1\na2\na3\nb4\nb5\nb6\nb7\nb8\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, path } });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ "qa", "x", "\x1b[B", "q", "2@a" }); // strip lines 1-3's first char
        s.drain(300);
        s.sendKeys(&.{ "d", "\x1b[B", "." }); // delete lines 4-5, repeat for 6-7
        s.drain(300);
        s.send(":wq\r");
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        const ok = std.mem.eql(u8, got, "1\n2\n3\nb8\n");
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check("macros and dot-repeat still replay special keys", ok);
        h.removeFile(ctx.io, path);
    }

    // ---- arrows take a count, like h/l/k/j (nvim-probed) ----
    // nvim 0.12.4 --clean -n through a pty, file "abcdef\nghijkl", cursor
    // on line 2 col 1: `3<Right>` `x` -> "ghikl" (column 4, counted);
    // `$` `2<Left>` `x` -> "ghikl"; `$` `2<BS>` `x` -> "ghikl" (<BS> counts
    // like <Left>); `$` `2<Home>` `x` -> "hijkl" (<Home> ignores the count).
    // `2<Down>` lands two lines down (`:ls` "line 4" from line 2). zedit used
    // to hardcode 1 for every arrow while doMotion consumed the count anyway.
    {
        const path = "/tmp/zedit_it_arrow_count.txt";
        h.writeFile(ctx.io, path, "abcdef\nghijkl\nmnopqr\nstuvwx\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, path } });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ "3\x1b[C", "x" }); // 3<Right> on line 1: col 4, x -> "abcef"
        s.drain(200);
        s.sendKeys(&.{ "2\x1b[B", "x" }); // 2<Down> keeps the goal col: line 3 'p', x -> "mnoqr"
        s.drain(200);
        s.sendKeys(&.{ "$", "2\x1b[D", "x" }); // $ 2<Left> on "mnoqr": col 3 'o', x -> "mnqr"
        s.drain(200);
        s.sendKeys(&.{ "\x1b[B", "$", "2\x7f", "x" }); // line 4, $ 2<BS>: "stuvwx" -> "stuwx"
        s.drain(200);
        s.sendKeys(&.{ "2\x1b[A", "\x1b[H", "x" }); // 2<Up>: line 2, Home, x -> "hijkl"
        s.drain(200);
        s.send(":wq\r");
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        const ok = std.mem.eql(u8, got, "abcef\nhijkl\nmnqr\nstuwx\n");
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check("arrows and <BS> take a count like h/l/k/j", ok);
        h.removeFile(ctx.io, path);
    }

    // ---- viewport centring + wheel drag (nvim-verified) ----
    // A jump further than half a window centres the cursor line, so it is not
    // glued to the bottom row where every wheel notch would drag it along.
    // Expected cursor lines came from real nvim given the same 23 text rows
    // (nvim needs a 25-row terminal for that, since it spends a row on its
    // separate command line).
    {
        const path = "/tmp/zedit_it_scroll.txt";
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(ctx.gpa);
        var i: usize = 1;
        while (i <= 200) : (i += 1) {
            var lb: [8]u8 = undefined;
            content.appendSlice(ctx.gpa, std.fmt.bufPrint(&lb, "L{d:0>3}\n", .{i}) catch break) catch break;
        }
        const WHEEL_UP = "\x1b[<64;5;5M";
        const WHEEL_DOWN = "\x1b[<65;5;5M";
        const Case = struct { name: []const u8, keys: []const []const u8, line: usize };
        // The cursor rides along with the viewport, keeping its screen row
        // (the owner's choice over nvim's drag-only-at-the-edge rule): each
        // notch is 3 lines, so the cursor line moves by 3 per notch.
        const cases = [_]Case{
            .{ .name = "one wheel notch moves the cursor with the view", .keys = &.{ "100G", WHEEL_UP, "x" }, .line = 97 },
            .{ .name = "five notches up move the cursor 15 lines", .keys = &.{ "100G", WHEEL_UP ** 5, "x" }, .line = 85 },
            .{ .name = "cursor keeps its screen row scrolling to the top", .keys = &.{ "100G", WHEEL_UP ** 20, "x" }, .line = 40 },
            .{ .name = "wheel down moves the cursor down too", .keys = &.{ "100G", WHEEL_DOWN ** 5, "x" }, .line = 115 },
            // Already at the top: the view cannot move, so neither does the cursor.
            .{ .name = "scrolling stops dead at the top of the file", .keys = &.{ "3G", WHEEL_UP ** 5, "x" }, .line = 3 },
        };
        for (cases) |c| {
            h.writeFile(ctx.io, path, content.items);
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, path } });
            defer s.finish();
            s.drain(400);
            s.sendKeys(c.keys);
            s.drain(300);
            s.send(":wq\r");
            s.drain(400);
            const text = h.readFile(ctx.gpa, ctx.io, path);
            defer ctx.gpa.free(text);
            // The edited line lost its leading "L".
            var lb: [16]u8 = undefined;
            const edited = std.fmt.bufPrint(&lb, "\n{d:0>3}\n", .{c.line}) catch continue;
            ctx.check(c.name, std.mem.indexOf(u8, text, edited) != null);
        }
    }

    // ---- mouse wheel ----
    // Three wheel-down reports (SGR mouse) scroll the viewport 9 lines,
    // bringing off-screen lines into view and dragging the cursor to stay
    // visible (an edit then lands on the dragged-to line, L10).
    {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(ctx.gpa);
        var i: usize = 1;
        while (i <= 40) : (i += 1) {
            var lb: [8]u8 = undefined;
            content.appendSlice(ctx.gpa, std.fmt.bufPrint(&lb, "L{d}\n", .{i}) catch break) catch break;
        }
        const path = "/tmp/zedit_it_wheel.txt";
        h.writeFile(ctx.io, path, content.items);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, path } });
        defer s.finish();
        s.drain(400);
        ctx.check("bottom lines start off-screen", !s.containsPlain(ctx.gpa, "L30"));
        s.send("\x1b[<65;5;5M\x1b[<65;5;5M\x1b[<65;5;5M"); // wheel down x3
        s.drain(400);
        ctx.check("wheel scrolls the viewport", s.containsPlain(ctx.gpa, "L30"));
        s.send("x:wq\r"); // cursor was dragged to the top visible line (L10)
        s.drain(400);
        const text = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(text);
        ctx.check("cursor follows the scrolled viewport", std.mem.indexOf(u8, text, "\n10\n") != null);
    }
}
