//! Tree-sitter highlighting end-to-end: verify the vendored grammars colour the
//! captured screen bytes. Port of tools/treesitter_test.py.
//!
//! Discriminator: a Zig multiline string (\\...). The per-line lexer cannot
//! recognise it, so if its bytes are coloured with the string colour, the colour
//! must have come from tree-sitter. The file lives outside any git repo and we
//! stay in normal mode, so the green string colour can't come from a git sign or
//! the insert-mode block.

const std = @import("std");
const h = @import("../harness.zig");

const KEYWORD = "\x1b[38;2;187;154;247m"; // theme.keyword (purple)
const STRING = "\x1b[38;2;158;206;106m"; // theme.string_ (green)
const NUMBER = "\x1b[38;2;255;158;100m"; // theme.number (orange)
const TYPE = "\x1b[38;2;42;195;222m"; // theme.type_ (cyan)
const BUILTIN = "\x1b[38;2;224;175;104m"; // theme.builtin (@text.strong)

const ZIG =
    "pub fn f() void {\n" ++
    "    const x =\n" ++
    "        \\\\hi\n" ++
    "    ;\n" ++
    "    _ = x;\n" ++
    "}\n";

/// Open `dir/name` with `content`, replay `keys`, then run `body` against the
/// live session before it is torn down. The session owns its captured bytes
/// (freed on finish), so `contains` assertions must happen in `body`, before
/// finish + removeTree.
fn capture(
    ctx: *h.Ctx,
    content: []const u8,
    name: []const u8,
    keys: []const []const u8,
    body: fn (ctx: *h.Ctx, s: *h.Session) void,
) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    const path = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, name });
    defer ctx.gpa.free(path);
    h.writeFile(ctx.io, path, content);

    var s = try h.Session.spawn(ctx.gpa, .{
        .argv = &.{ ctx.zed, name },
        .cwd = dir,
        .term = "xterm-256color",
    });
    s.drain(1000);
    for (keys) |k| {
        s.send(k);
        s.drain(400);
    }
    s.send("\x1b:q!\r");
    s.drain(300);

    body(ctx, &s);

    s.finish();
    h.removeTree(ctx.gpa, ctx.io, dir);
}

fn checkLoad(ctx: *h.Ctx, s: *h.Session) void {
    ctx.check("keywords highlighted", s.contains(KEYWORD));
    ctx.check("multiline string highlighted (tree-sitter only)", s.contains(STRING));
}

fn checkIncremental(ctx: *h.Ctx, s: *h.Session) void {
    ctx.check("incremental: new keyword highlighted", s.contains(KEYWORD));
    ctx.check("incremental: new number highlighted", s.contains(NUMBER));
    ctx.check("incremental: existing string still highlighted", s.contains(STRING));
}

fn checkScroll(ctx: *h.Ctx, s: *h.Session) void {
    ctx.check("scroll re-queries: off-screen string highlighted after G", s.contains(STRING));
}

fn checkTypescript(ctx: *h.Ctx, s: *h.Session) void {
    ctx.check("typescript file highlights (type + string)", s.contains(TYPE) and s.contains(STRING));
}

fn checkRust(ctx: *h.Ctx, s: *h.Session) void {
    ctx.check("rust file highlights (keyword + string)", s.contains(KEYWORD) and s.contains(STRING));
}

fn checkHtml(ctx: *h.Ctx, s: *h.Session) void {
    ctx.check("html file highlights (tag + attr value)", s.contains(KEYWORD) and s.contains(STRING));
}

fn checkMarkdown(ctx: *h.Ctx, s: *h.Session) void {
    ctx.check("markdown: heading highlighted (block layer)", s.contains(KEYWORD));
    ctx.check("markdown: bold highlighted (inline layer)", s.contains(BUILTIN));
}

pub fn run(ctx: *h.Ctx) !void {
    // A file taller than the screen, with a multiline string near the bottom
    // that is off-screen until we scroll down.
    var tall: std.ArrayList(u8) = .empty;
    defer tall.deinit(ctx.gpa);
    try tall.appendSlice(ctx.gpa, "pub fn f() void {\n");
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const line = try std.fmt.allocPrint(ctx.gpa, "    const a{d} = {d};\n", .{ i, i });
        defer ctx.gpa.free(line);
        try tall.appendSlice(ctx.gpa, line);
    }
    try tall.appendSlice(ctx.gpa, "    const s =\n        \\\\deep\n    ;\n    _ = s;\n}\n");

    // Full parse on load.
    try capture(ctx, ZIG, "sample.zig", &.{}, checkLoad);

    // Incremental reparse: insert a new line at the top (O + text + Esc). The
    // new tokens must be highlighted, and the pre-existing multiline string must
    // stay highlighted (proving the reused tree wasn't corrupted by the edit).
    try capture(ctx, ZIG, "sample.zig", &.{ "O", "const z = 99;", "\x1b" }, checkIncremental);

    // Visible-range query: a multiline string near the bottom of a tall file is
    // off-screen at first; after scrolling to it (G), the re-query highlights it.
    try capture(ctx, tall.items, "sample.zig", &.{"G"}, checkScroll);

    // A TypeScript file goes through the .typescript variant; a type annotation
    // is highlighted as a type.
    try capture(ctx, "function f(a: number): string { return \"x\"; }\n", "sample.ts", &.{}, checkTypescript);

    // A Rust file goes through the .rust variant.
    try capture(ctx, "fn main() {\n    let s = \"hi\";\n}\n", "sample.rs", &.{}, checkRust);

    // HTML: tag names highlighted (as keywords), attribute values (as strings).
    try capture(ctx, "<div class=\"x\">hi</div>\n", "sample.html", &.{}, checkHtml);

    // Markdown exercises the two-layer path: the heading comes from the block
    // layer and the bold from the inline (secondary) layer.
    try capture(ctx, "# Title\n\nsome **bold** text\n", "sample.md", &.{}, checkMarkdown);
}
