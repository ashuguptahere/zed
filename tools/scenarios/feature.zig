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
