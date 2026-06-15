//! Visual rendering (true-color, powerline, syntax) and editing built-ins
//! (auto-pairs, comment toggle). Port of tools/feature_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const BS = "\x7f";
const target = "/tmp/zed_it_feat.txt";

fn case(ctx: *h.Ctx, name: []const u8, chunks: []const []const u8, initial: []const u8, want: []const u8) void {
    const got = h.runEdit(ctx, target, initial, chunks);
    defer ctx.gpa.free(got);
    ctx.check(name, std.mem.eql(u8, got, want));
}

pub fn run(ctx: *h.Ctx) !void {
    // ---- visual rendering (needs a .zig file for language detection) ----
    const zig_target = "/tmp/zed_it_feat.zig";
    const zig_src =
        "const std = @import(\"std\");\n" ++
        "pub fn main() void {\n" ++
        "        const x = 42; // hi\n" ++ // 8-space indent -> indent guide at col 4
        "}\n";
    h.writeFile(ctx.io, zig_target, zig_src);
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zed, zig_target }, .term = "xterm-256color" });
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
    case(ctx, "backspace deletes empty pair", &.{ "i", "(", BS, ESC, ":wq", CR }, "", "");
    case(ctx, "autopair quotes", &.{ "i", "\"", "hi", ESC, ":wq", CR }, "", "\"hi\"\n");

    // ---- comment toggle ----
    case(ctx, "gcc comments line", &.{ "gcc", ":wq", CR }, "abc\n", "// abc\n");
    case(ctx, "gcc twice toggles back", &.{ "gcc", "gcc", ":wq", CR }, "abc\n", "abc\n");
    case(ctx, "gcj comments two lines", &.{ "gcj", ":wq", CR }, "a\nb\nc\n", "// a\n// b\nc\n");
}
