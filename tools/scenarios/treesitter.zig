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
    const dir = try ctx.tempDir();
    const path = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, name });
    defer ctx.gpa.free(path);
    h.writeFile(ctx.io, path, content);

    var s = try h.Session.spawn(ctx.gpa, .{
        .argv = &.{ ctx.zedit, name },
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

/// A buffer born empty (the named file is not on disk yet) must highlight as
/// soon as code is typed. The first keystroke's reparse used to hand the old
/// empty tree to tree-sitter without an edit (an api.h contract violation), so
/// the stale zero-length root won forever: no colours, not even the lexer's.
fn newFileHighlighting(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();

    // CLI path: `zedit brandnew.py` with no such file on disk.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "brandnew.py" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(600);
        s.send("idef foo():");
        s.drain(500);
        s.send("\x1b");
        s.drain(300);
        ctx.check("typing into a brand-new .py file highlights", s.contains(KEYWORD));
        s.send(":q!\r");
        s.drain(200);
    }
    // In-session path (`:e brandnew2.py`), with the existing file as the
    // contrast that guards the incremental path.
    {
        const existing = h.join(ctx, dir, "existing.py");
        defer ctx.gpa.free(existing);
        h.writeFile(ctx.io, existing, "def hello():\n    return 42\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "existing.py" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(700);
        ctx.check("existing .py file highlights (contrast)", s.contains(KEYWORD));
        const from = s.mark();
        s.send(":e brandnew2.py\r");
        s.drain(500);
        s.send("idef foo():");
        s.drain(500);
        s.send("\x1b");
        s.drain(300);
        ctx.check(":e to a brand-new .py file highlights as typed", std.mem.indexOf(u8, s.out.items[from..], KEYWORD) != null);
        s.send(":q!\r");
        s.drain(200);
    }
    // `:w name.py` naming a previously-unnamed buffer decides its language on
    // the spot: filetype, highlighting (and LSP) come up without a reopen.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(600);
        s.send("\x1b"); // cancel the picker: an unnamed empty buffer
        s.drain(300);
        s.send("idef foo():");
        s.drain(400);
        s.send("\x1b");
        s.drain(300);
        const from = s.mark();
        s.send(":w named.py\r");
        s.drain(700);
        ctx.check(":w name.py highlights the newly-named buffer", std.mem.indexOf(u8, s.out.items[from..], KEYWORD) != null);
        ctx.check(":w name.py sets the filetype", s.containsPlainSince(ctx.gpa, from, "python"));
        s.send(":q\r");
        s.drain(200);
    }
}

/// tokyonight fg values (theme.zig), for per-cell colour assertions.
const KEYWORD_RGB = h.rgb(0xbb, 0x9a, 0xf7);
const NUMBER_RGB = h.rgb(0xff, 0x9e, 0x64);
const TYPE_RGB = h.rgb(0x2a, 0xc3, 0xde);
const BUILTIN_RGB = h.rgb(0xe0, 0xaf, 0x68);

/// Open `dir/name`, let it settle, and hand the decoded screen to `body`.
/// `Screen` is 1-based and the title bar takes its first row, so buffer line
/// `n` (1-based) is screen row `n + 1`.
fn onScreen(
    ctx: *h.Ctx,
    content: []const u8,
    name: []const u8,
    body: fn (ctx: *h.Ctx, scr: *h.Screen) void,
) !void {
    const dir = try ctx.tempDir();
    const path = h.join(ctx, dir, name);
    defer ctx.gpa.free(path);
    h.writeFile(ctx.io, path, content);

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, name }, .cwd = dir, .term = "xterm-256color" });
    defer s.finish();
    s.drain(900); // first paint, then the frame that brings highlighting in

    var scr = try h.Screen.init(ctx.gpa, 24, 80);
    defer scr.deinit();
    scr.apply(s.out.items);
    body(ctx, &scr);
    s.send(":q!\r");
    s.drain(200);
}

/// The foreground colour of the first cell of `needle` on screen `row`.
fn fgOf(ctx: *h.Ctx, scr: *h.Screen, row: usize, needle: []const u8) ?u32 {
    const col = scr.colOf(ctx.gpa, row, needle) orelse return null;
    return scr.at(row, col).fg;
}

/// Injections put a *different grammar's* colours inside a region: a fenced
/// python block is python, a `<script>` body is javascript. Asserted per cell,
/// so "the keyword colour is on `def` inside the fence and on nothing outside
/// it" is a real claim about where the colour landed.
fn injections(ctx: *h.Ctx) !void {
    try onScreen(ctx, MD_FENCE, "inj.md", checkMdFence);
    try onScreen(ctx, MD_PLAIN_FENCE, "plain.md", checkMdPlainFence);
    try onScreen(ctx, HTML_SCRIPT, "inj.html", checkHtmlScript);
}

// Buffer lines 1 "# Title", 2 "", 3 "```python", 4 "def f():",
// 5 "    return 9007", 6 "```", 7 "", 8 "def outside". The numbers are picked
// so they cannot collide with the gutter's line numbers.
const MD_FENCE = "# Title\n\n```python\ndef f():\n    return 9007\n```\n\ndef outside\n";
// The same document with no language on the fence.
const MD_PLAIN_FENCE = "# Title\n\n```\ndef f():\n```\n";
const HTML_SCRIPT = "<p>hi</p>\n<script>\nlet x = 9007;\n</script>\n";

fn checkMdFence(ctx: *h.Ctx, scr: *h.Screen) void {
    // Inside the fence: python's own colours.
    ctx.check("md fence: `def` inside is a python keyword", fgOf(ctx, scr, 5, "def") == KEYWORD_RGB);
    ctx.check("md fence: `return` inside is a python keyword", fgOf(ctx, scr, 6, "return") == KEYWORD_RGB);
    ctx.check("md fence: `9007` inside is a python number", fgOf(ctx, scr, 6, "9007") == NUMBER_RGB);
    // Outside it the same word is prose — markdown has no keyword capture for
    // it, so the keyword colour must be absent.
    ctx.check("md fence: `def` outside is not a keyword", fgOf(ctx, scr, 9, "def") != KEYWORD_RGB);
}

fn checkMdPlainFence(ctx: *h.Ctx, scr: *h.Screen) void {
    // No language named, so no injected layer and no python colours.
    ctx.check("md fence: an unnamed fence gets no python keyword", fgOf(ctx, scr, 5, "def") != KEYWORD_RGB);
}

fn checkHtmlScript(ctx: *h.Ctx, scr: *h.Screen) void {
    ctx.check("html script: `let` is a javascript keyword", fgOf(ctx, scr, 4, "let") == KEYWORD_RGB);
    ctx.check("html script: `9007` is a javascript number", fgOf(ctx, scr, 4, "9007") == NUMBER_RGB);
}

/// Query predicates gate their pattern: Zig's `((identifier) @type
/// (#lua-match? @type "^[A-Z_]..."))` fires on `Foo` and must *not* fire on
/// `bar`. Before predicates were evaluated the pattern matched every
/// identifier, so every one of them came out type-coloured.
fn predicates(ctx: *h.Ctx) !void {
    try onScreen(ctx, PRED_ZIG, "pred.zig", checkZigPredicates);
    try onScreen(ctx, PRED_PY, "pred.py", checkPyPredicates);
}

// Buffer lines 1 "test {", 2 "    const alpha = Bravo;", 3 "    _ = alpha;", 4 "}"
const PRED_ZIG = "test {\n    const alpha = Bravo;\n    _ = alpha;\n}\n";
const PRED_PY = "LOUD = 1\nquiet = 2\n";

fn checkZigPredicates(ctx: *h.Ctx, scr: *h.Screen) void {
    ctx.check("predicate: capitalised zig identifier is a type", fgOf(ctx, scr, 3, "Bravo") == TYPE_RGB);
    ctx.check("predicate: lowercase zig identifier is not", fgOf(ctx, scr, 3, "alpha") != TYPE_RGB);
    // `#eq? @variable.builtin "_"` — only the discard identifier.
    ctx.check("predicate: `_` is the builtin it is named as", fgOf(ctx, scr, 4, "_") == BUILTIN_RGB);
    ctx.check("predicate: a plain identifier is not a builtin", fgOf(ctx, scr, 4, "alpha") != BUILTIN_RGB);
}

fn checkPyPredicates(ctx: *h.Ctx, scr: *h.Screen) void {
    // `#match? @constant "^[A-Z][A-Z_]*$"`.
    ctx.check("predicate: ALL_CAPS python name is a constant", fgOf(ctx, scr, 2, "LOUD") == BUILTIN_RGB);
    ctx.check("predicate: lowercase python name is not", fgOf(ctx, scr, 3, "quiet") != BUILTIN_RGB);
}

pub fn run(ctx: *h.Ctx) !void {
    try newFileHighlighting(ctx);
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

    // Markdown exercises the injection path: the heading comes from the block
    // layer and the bold from the markdown-inline layer it injects.
    try capture(ctx, "# Title\n\nsome **bold** text\n", "sample.md", &.{}, checkMarkdown);

    try injections(ctx);
    try predicates(ctx);

    // --- structural text objects, resolved from the syntax tree ---------
    // Node names come from the grammars themselves, so these assert the real
    // structure: `af` takes the whole function, `if` only its body, `ac` a
    // whole type, and `]f` / `[f` step between functions.
    const zig_src =
        \\const std = @import("std");
        \\
        \\pub fn alpha(a: u8) u8 {
        \\    return a;
        \\}
        \\
        \\pub fn beta() void {}
        \\
    ;
    const Case = struct { name: []const u8, keys: []const []const u8, want: []const u8 };
    const cases = [_]Case{
        .{
            .name = "daf deletes the whole function",
            .keys = &.{ "3G", "daf" },
            .want = "const std = @import(\"std\");\n\n\n\npub fn beta() void {}\n",
        },
        .{
            .name = "dif deletes only the function body",
            .keys = &.{ "4G", "dif" },
            .want = "const std = @import(\"std\");\n\npub fn alpha(a: u8) u8 {}\n\npub fn beta() void {}\n",
        },
        .{
            .name = "]f jumps to the next function",
            .keys = &.{ "1G", "]f", "x" },
            .want = "const std = @import(\"std\");\n\nub fn alpha(a: u8) u8 {\n    return a;\n}\n\npub fn beta() void {}\n",
        },
        .{
            .name = "]f twice reaches the second function",
            .keys = &.{ "1G", "]f", "]f", "x" },
            .want = "const std = @import(\"std\");\n\npub fn alpha(a: u8) u8 {\n    return a;\n}\n\nub fn beta() void {}\n",
        },
        .{
            .name = "[f steps back to the previous function",
            .keys = &.{ "G", "[f", "x" },
            .want = "const std = @import(\"std\");\n\nub fn alpha(a: u8) u8 {\n    return a;\n}\n\npub fn beta() void {}\n",
        },
    };
    for (cases) |cs| {
        const path = "/tmp/zedit_it_tsobj.zig";
        h.writeFile(ctx.io, path, zig_src);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, path } });
        defer s.finish();
        s.drain(500);
        s.sendKeys(cs.keys);
        s.drain(300);
        s.send(":wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        const ok = std.mem.eql(u8, got, cs.want);
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check(cs.name, ok);
    }

    // Python: the same objects follow that grammar's own node names.
    {
        const path = "/tmp/zedit_it_tsobj.py";
        h.writeFile(ctx.io, path, "class Widget:\n    def draw(self):\n        return 1\n\n    def hide(self):\n        return 2\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, path } });
        defer s.finish();
        s.drain(500);
        s.sendKeys(&.{ "1G", "dac" }); // the whole class
        s.drain(300);
        s.send(":wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("dac deletes a python class", std.mem.eql(u8, got, "\n"));
    }

    // --- argument (`ia`/`aa`) and comment (`iC`/`aC`) objects -------------
    {
        const code =
            \\// first note
            \\// second note
            \\pub fn alpha(a: u8, b: u8) u8 {
            \\    return add(a, b); // trailing note
            \\}
            \\
        ;
        const head = "// first note\n// second note\n";
        const arg_cases = [_]Case{
            .{
                .name = "dia deletes just the parameter",
                .keys = &.{ "3G", "f(", "l", "dia" },
                .want = head ++ "pub fn alpha(, b: u8) u8 {\n    return add(a, b); // trailing note\n}\n",
            },
            .{
                .name = "daa takes the parameter and the comma after it",
                .keys = &.{ "3G", "f(", "l", "daa" },
                .want = head ++ "pub fn alpha(b: u8) u8 {\n    return add(a, b); // trailing note\n}\n",
            },
            .{
                .name = "daa on the last parameter takes the comma before it",
                .keys = &.{ "3G", "f)", "h", "daa" },
                .want = head ++ "pub fn alpha(a: u8) u8 {\n    return add(a, b); // trailing note\n}\n",
            },
            .{
                .name = "daa works on call arguments too",
                .keys = &.{ "4G", "f(", "l", "daa" },
                .want = head ++ "pub fn alpha(a: u8, b: u8) u8 {\n    return add(b); // trailing note\n}\n",
            },
            .{
                .name = "aa in visual mode selects the argument",
                .keys = &.{ "4G", "f(", "l", "vaad" },
                .want = head ++ "pub fn alpha(a: u8, b: u8) u8 {\n    return add(b); // trailing note\n}\n",
            },
            .{
                .name = "daC deletes the whole run of comment lines",
                .keys = &.{ "1G", "daC" },
                .want = "pub fn alpha(a: u8, b: u8) u8 {\n    return add(a, b); // trailing note\n}\n",
            },
            .{
                .name = "diC keeps the delimiter and clears the text",
                .keys = &.{ "1G", "diC" },
                .want = "// \n// second note\npub fn alpha(a: u8, b: u8) u8 {\n    return add(a, b); // trailing note\n}\n",
            },
            .{
                .name = "daC on a trailing comment leaves the code alone",
                .keys = &.{ "4G", "$", "daC" },
                .want = head ++ "pub fn alpha(a: u8, b: u8) u8 {\n    return add(a, b);\n}\n",
            },
        };
        for (arg_cases) |cs| {
            const path = "/tmp/zedit_it_tsarg.zig";
            h.writeFile(ctx.io, path, code);
            var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, path } });
            defer s.finish();
            s.drain(500);
            s.sendKeys(cs.keys);
            s.drain(300);
            s.send(":wq\r");
            s.drain(400);
            const got = h.readFile(ctx.gpa, ctx.io, path);
            defer ctx.gpa.free(got);
            const ok = std.mem.eql(u8, got, cs.want);
            if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
            ctx.check(cs.name, ok);
        }
    }
}
