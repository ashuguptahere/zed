//! Visual rendering (true-color, powerline, syntax) and editing built-ins
//! (auto-pairs, comment toggle). Port of tools/feature_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const BS = "\x7f";
const target = "/tmp/zedit_it_feat.txt";

fn case(ctx: *h.Ctx, name: []const u8, chunks: []const []const u8, initial: []const u8, want: []const u8) void {
    const got = h.runEdit(ctx, target, initial, chunks);
    defer ctx.gpa.free(got);
    ctx.check(name, std.mem.eql(u8, got, want));
}

pub fn run(ctx: *h.Ctx) !void {
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
    case(ctx, "autopair inserts closer", &.{ "i", "(", "x", ESC, ":wq", CR }, "", "(x)\n");
    case(ctx, "autopair steps over closer", &.{ "i", "(", ")", ESC, ":wq", CR }, "", "()\n");
    // The emptied (but once-edited) line writes "\n", not 0 bytes — verified
    // against nvim (see vim_compat.zig and Buffer.emptied).
    case(ctx, "backspace deletes empty pair", &.{ "i", "(", BS, ESC, ":wq", CR }, "", "\n");
    case(ctx, "autopair quotes", &.{ "i", "\"", "hi", ESC, ":wq", CR }, "", "\"hi\"\n");

    // ---- comment toggle ----
    case(ctx, "gcc comments line", &.{ "gcc", ":wq", CR }, "abc\n", "// abc\n");
    case(ctx, "gcc twice toggles back", &.{ "gcc", "gcc", ":wq", CR }, "abc\n", "abc\n");
    case(ctx, "gcj comments two lines", &.{ "gcj", ":wq", CR }, "a\nb\nc\n", "// a\n// b\nc\n");

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

        var m = s.mark();
        s.send("2");
        s.drain(250);
        ctx.check("showcmd shows a pending count", s.containsPlainSince(ctx.gpa, m, "2 "));

        m = s.mark();
        s.send("d");
        s.drain(250);
        ctx.check("showcmd shows count + operator", s.containsPlainSince(ctx.gpa, m, "2d "));

        m = s.mark();
        s.send("\x1b"); // abandon it
        s.drain(250);
        ctx.check("Esc clears the indicator", !s.containsPlainSince(ctx.gpa, m, "2d "));

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
        s.send("\x17"); // Ctrl-w: a pending window command shows as ^W
        s.drain(250);
        ctx.check("control keys show in caret notation", s.containsPlainSince(ctx.gpa, m, "^W "));
        s.send("\x1b");
        s.drain(150);

        m = s.mark();
        s.send("qa"); // start recording into register a
        s.drain(250);
        ctx.check("recording marker still shows", s.containsPlainSince(ctx.gpa, m, "REC @a"));
        s.send("q:q!\r");
        s.drain(300);
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
        const cases = [_]Case{
            .{ .name = "one wheel notch leaves the cursor put", .keys = &.{ "100G", WHEEL_UP, "x" }, .line = 100 },
            .{ .name = "wheel up drags only at the window edge", .keys = &.{ "100G", WHEEL_UP ** 5, "x" }, .line = 96 },
            .{ .name = "wheel up to the top drags the cursor with it", .keys = &.{ "100G", WHEEL_UP ** 20, "x" }, .line = 51 },
            .{ .name = "wheel down drags the cursor at the top edge", .keys = &.{ "100G", WHEEL_DOWN ** 5, "x" }, .line = 104 },
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
