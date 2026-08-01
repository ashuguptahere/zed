//! Fuzzy file picker and global search picker end-to-end. Port of
//! tools/picker_test.py. Sets up a temp directory of files, opens zedit there,
//! drives the pickers via the space-leader menu, then edits + saves to confirm
//! the right file/line was opened.

const std = @import("std");
const h = @import("../harness.zig");

const CR = "\r";

const File = struct { name: []const u8, content: []const u8 };

/// Create a temp dir, write `files`, open `open_arg` in zedit there, replay
/// `chunks`, then read each file back (before removing the tree). The read-back
/// contents are returned in the same order as `files` (caller frees each, and
/// the slice).
fn run_picker(
    ctx: *h.Ctx,
    files: []const File,
    open_arg: []const u8,
    chunks: []const []const u8,
) ![][]u8 {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);

    for (files) |f| {
        const path = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, f.name });
        defer ctx.gpa.free(path);
        h.writeFile(ctx.io, path, f.content);
    }

    var s = try h.Session.spawn(ctx.gpa, .{
        .argv = &.{ ctx.zedit, open_arg },
        .cwd = dir,
    });
    s.drain(400);
    s.sendKeys(chunks);
    s.drain(600);
    s.send("\x1b:q!\r");
    s.drain(600);

    // Read the files back BEFORE removing the tree.
    const result = try ctx.gpa.alloc([]u8, files.len);
    for (files, 0..) |f, i| {
        const path = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, f.name });
        defer ctx.gpa.free(path);
        result[i] = h.readFile(ctx.gpa, ctx.io, path);
    }

    s.finish();
    h.removeTree(ctx.gpa, ctx.io, dir);
    return result;
}

fn freeResult(ctx: *h.Ctx, result: [][]u8) void {
    for (result) |r| ctx.gpa.free(r);
    ctx.gpa.free(result);
}

/// True if `needle` appears anywhere on the *current* screen (replaying the
/// whole captured stream through the terminal model — row-diffed frames mean
/// "was printed at some point" is not "is still shown").
fn onScreen(ctx: *h.Ctx, s: *h.Session, needle: []const u8) bool {
    var scr = h.Screen.init(ctx.gpa, 24, 110) catch return false;
    defer scr.deinit();
    scr.apply(s.out.items);
    var row: usize = 1;
    while (row <= 24) : (row += 1) {
        const txt = scr.rowText(ctx.gpa, row) catch return false;
        defer ctx.gpa.free(txt);
        if (std.mem.indexOf(u8, txt, needle) != null) return true;
    }
    return false;
}

pub fn run(ctx: *h.Ctx) !void {
    // File picker: open a.txt, picker-open b.txt, delete a char, save.
    {
        const files = [_]File{
            .{ .name = "a.txt", .content = "aaa\n" },
            .{ .name = "b.txt", .content = "bbb\n" },
        };
        const result = try run_picker(ctx, &files, "a.txt", &.{ " ff", "b", CR, "x", ":wq", CR });
        defer freeResult(ctx, result);
        ctx.check("file picker opened b.txt and edited it", std.mem.eql(u8, result[1], "bb\n"));
        ctx.check("file picker left a.txt untouched", std.mem.eql(u8, result[0], "aaa\n"));
    }

    // `zedit .` (a directory argument) enters it and starts in the file
    // picker (regression: it used to die with "cannot open .: IsDir").
    {
        const files = [_]File{
            .{ .name = "a.txt", .content = "aaa\n" },
            .{ .name = "b.txt", .content = "bbb\n" },
        };
        const result = try run_picker(ctx, &files, ".", &.{ "b", CR, "x", ":wq", CR });
        defer freeResult(ctx, result);
        ctx.check("directory argument opens the file picker", std.mem.eql(u8, result[1], "bb\n"));
        ctx.check("directory open leaves other files untouched", std.mem.eql(u8, result[0], "aaa\n"));
    }

    // `zedit .` lands on the browser view: the file tree on the left, the
    // picker on the right, and a preview of the selected file beside it.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = try std.fmt.allocPrint(ctx.gpa, "{s}/alpha.txt", .{dir});
        defer ctx.gpa.free(a);
        const b = try std.fmt.allocPrint(ctx.gpa, "{s}/beta.txt", .{dir});
        defer ctx.gpa.free(b);
        h.writeFile(ctx.io, a, "ALPHA MARKER\nsecond line\n");
        h.writeFile(ctx.io, b, "BETA MARKER\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(700);
        ctx.check("directory opens the explorer beside the picker", s.containsPlain(ctx.gpa, "EXPLORER") and
            s.containsPlain(ctx.gpa, "FILES"));
        ctx.check("picker previews the selected file", s.containsPlain(ctx.gpa, "MARKER"));

        const m = s.mark();
        s.send("beta"); // narrow to beta.txt: the preview follows the selection
        s.drain(600);
        ctx.check("preview follows the selection", s.containsPlainSince(ctx.gpa, m, "BETA MARKER"));
        s.send("\x1b:qa!\r");
        s.drain(200);
    }

    // The preview is tree-sitter highlighted and scrollable on its own.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const zf = try std.fmt.allocPrint(ctx.gpa, "{s}/long.zig", .{dir});
        defer ctx.gpa.free(zf);
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(ctx.gpa);
        try content.appendSlice(ctx.gpa, "const std = @import(\"std\");\n");
        var i: usize = 1;
        while (i <= 60) : (i += 1) {
            var lb: [40]u8 = undefined;
            try content.appendSlice(ctx.gpa, std.fmt.bufPrint(&lb, "pub fn fn_{d}() void {{}}\n", .{i}) catch break);
        }
        try content.appendSlice(ctx.gpa, "const DEEP_MARKER = 42;\n");
        h.writeFile(ctx.io, zf, content.items);

        const KEYWORD = "\x1b[38;2;187;154;247m"; // tokyonight keyword
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "." },
            .cwd = dir,
            .cols = 110,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(900);
        // The grammar is compiled and the preview parsed *after* the picker's
        // first frame, so wait for the highlighting rather than for a fixed
        // number of milliseconds — that budget is a guess about how fast the
        // machine is, and CI is slower than a workstation.
        {
            const until = h.nowMs() + 8000;
            while (h.nowMs() < until and
                !(s.contains(KEYWORD) and s.containsPlain(ctx.gpa, "const std"))) s.drain(200);
        }
        ctx.check("preview is tree-sitter highlighted", s.contains(KEYWORD) and
            s.containsPlain(ctx.gpa, "const std"));

        // Page to the end. How many presses that takes depends on how tall the
        // preview is, which the floating box changed — so press until the last
        // line shows or the deadline says it never will, rather than assuming
        // a count.
        var m = s.mark();
        var reached = false;
        {
            const until = h.nowMs() + 8000;
            while (h.nowMs() < until and !reached) {
                s.send("\x04"); // Ctrl-d
                s.drain(250);
                reached = s.containsPlainSince(ctx.gpa, m, "DEEP_MARKER");
            }
        }
        ctx.check("Ctrl-d scrolls the preview", reached);

        m = s.mark();
        s.send("\x15\x15\x15\x15\x15\x15"); // Ctrl-u back to the top
        s.drain(700);
        ctx.check("Ctrl-u scrolls the preview back", s.containsPlainSince(ctx.gpa, m, "const std"));

        m = s.mark();
        s.send("\x1b[<65;60;10M" ** 4); // the wheel scrolls it too
        s.drain(600);
        ctx.check("the wheel scrolls the preview", s.containsPlainSince(ctx.gpa, m, "fn_"));
        s.send("\x1b:qa!\r");
        s.drain(200);
    }

    // Multi-term fuzzy queries (helix-style): every space-separated term must
    // match independently, in any order — "sub gamma" and "gamma sub" both
    // single out sub/gamma.txt — and a term matching nothing empties the
    // results, which shows the content-search hint (files picker only). The
    // `zedit <dir>` session also opens with a one-time scope status line.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const sub = h.join(ctx, dir, "sub");
        defer ctx.gpa.free(sub);
        std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
        const g = h.join(ctx, dir, "sub/gamma.txt");
        defer ctx.gpa.free(g);
        const decoy = h.join(ctx, dir, "gamma.txt"); // "gamma" but not "sub"
        defer ctx.gpa.free(decoy);
        const other = h.join(ctx, dir, "sub/alpha.txt"); // "sub" but not "gamma"
        defer ctx.gpa.free(other);
        h.writeFile(ctx.io, g, "right\n");
        h.writeFile(ctx.io, decoy, "wrong\n");
        h.writeFile(ctx.io, other, "wrong\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(700);
        ctx.check("a directory session states the search scopes", s.containsPlain(ctx.gpa, "type to match file NAMES") and
            s.containsPlain(ctx.gpa, "Space f w searches file contents"));

        s.send("sub gamma"); // only sub/gamma.txt holds both terms
        s.drain(500);
        ctx.check("the scope status is one-time (first keystroke clears it)", !onScreen(ctx, &s, "type to match file NAMES"));
        s.send("\r");
        s.drain(400);
        s.send("x:w\r");
        s.drain(400);
        {
            const got = h.readFile(ctx.gpa, ctx.io, g);
            defer ctx.gpa.free(got);
            ctx.check("multi-term query opens the file matching every term", std.mem.eql(u8, got, "ight\n"));
        }

        s.send(" ff");
        s.drain(300);
        s.send("gamma sub"); // reversed order: the same single match
        s.drain(500);
        s.send("\r");
        s.drain(400);
        s.send("x:w\r");
        s.drain(400);
        {
            const got = h.readFile(ctx.gpa, ctx.io, g);
            defer ctx.gpa.free(got);
            ctx.check("reversed term order matches the same file", std.mem.eql(u8, got, "ght\n"));
        }

        s.send(" ff");
        s.drain(300);
        s.send("gamma zq"); // no file name holds z+q: zero matches
        s.drain(500);
        ctx.check("a hopeless term empties the results and hints at Space f w", onScreen(ctx, &s, "no file names match") and
            onScreen(ctx, &s, "Space f w searches contents"));
        s.send("\x1b");
        s.drain(300);
        s.send(" fb"); // the hint is the files picker's alone
        s.drain(300);
        s.send("zq");
        s.drain(400);
        ctx.check("the zero-match hint stays out of the buffer picker", !onScreen(ctx, &s, "no file names match"));
        s.send("\x1b");
        s.drain(300);
        s.send(" ftzq"); // themes: a fuzzy picker, but not the file-name one
        s.drain(400);
        ctx.check("the zero-match hint stays out of the theme picker", !onScreen(ctx, &s, "no file names match"));
        s.send("\x1b");
        s.drain(300);
        s.send(" fwzqzq"); // grep: an empty content search is not a missing name
        s.drain(700);
        ctx.check("the zero-match hint stays out of the grep picker", !onScreen(ctx, &s, "no file names match"));
        s.send("\x1b:qa!\r");
        s.drain(200);
    }

    // Multi-term is the *shared* refilter's rule, so it holds in every fuzzy
    // picker — not only the file one, which is the sole kind with the
    // extend-narrow fast path and the char-bitmask prefilter. Pinned on the
    // buffer picker: both buffers carry "alpha", only one carries "q7q7".
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const only = h.join(ctx, dir, "alpha_only.txt");
        defer ctx.gpa.free(only);
        const both = h.join(ctx, dir, "q7q7_alpha.txt");
        defer ctx.gpa.free(both);
        h.writeFile(ctx.io, only, "first\n");
        h.writeFile(ctx.io, both, "second\n");

        // The target must NOT be the buffer already showing, or a picker that
        // matched nothing would edit the right file by doing nothing at all.
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "q7q7_alpha.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(500);
        s.send(":e alpha_only.txt\r"); // now the *other* buffer is active
        s.drain(600);
        s.send(" fb"); // the buffer picker, where "alpha" alone matches both
        s.drain(400);
        s.send("alpha q7q7"); // the second term singles one out
        s.drain(500);
        s.send("\r");
        s.drain(400);
        s.send("x:w\r"); // no match => this edits the still-active alpha_only
        s.drain(600);
        {
            const got = h.readFile(ctx.gpa, ctx.io, both);
            defer ctx.gpa.free(got);
            ctx.check("multi-term filters the buffer picker too", std.mem.eql(u8, got, "econd\n"));
        }
        {
            const got = h.readFile(ctx.gpa, ctx.io, only);
            defer ctx.gpa.free(got);
            ctx.check("the buffer holding only the first term is left alone", std.mem.eql(u8, got, "first\n"));
        }
        s.send("\x1b:qa!\r");
        s.drain(200);
    }

    // The grep picker is the one query that is NOT term-split: it is a single
    // regex, so a space matches a space. `alpha beta` finds the line that
    // spells it and not the line that merely holds both words in the other
    // order — which is exactly what a multi-term matcher would have returned.
    // (`foo.*bar` is how the grep picker asks for order; the docs say so.)
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const pair = h.join(ctx, dir, "pair.txt");
        defer ctx.gpa.free(pair);
        const swapped = h.join(ctx, dir, "swapped.txt");
        defer ctx.gpa.free(swapped);
        h.writeFile(ctx.io, pair, "alpha beta\n");
        h.writeFile(ctx.io, swapped, "beta then alpha\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "pair.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(500);
        s.send(" fwalpha beta");
        s.drain(800);
        ctx.check("grep keeps the space literal, matching the adjacent words", onScreen(ctx, &s, "pair.txt:1"));
        ctx.check("grep does not term-split: both words in any order is no match",
            !onScreen(ctx, &s, "swapped.txt:1"));
        s.send("\x1b");
        s.drain(300);
        s.send(" fwbeta.*alpha"); // ordering in grep is spelled with a regex
        s.drain(800);
        ctx.check("grep expresses order with a regex instead", onScreen(ctx, &s, "swapped.txt:1") and
            !onScreen(ctx, &s, "pair.txt:1"));
        s.send("\x1b:qa!\r");
        s.drain(200);
    }

    // Buffers appear as tabs across the top once more than one is open.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = try std.fmt.allocPrint(ctx.gpa, "{s}/one.txt", .{dir});
        defer ctx.gpa.free(a);
        const b = try std.fmt.allocPrint(ctx.gpa, "{s}/two.txt", .{dir});
        defer ctx.gpa.free(b);
        h.writeFile(ctx.io, a, "first\n");
        h.writeFile(ctx.io, b, "second\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(500);
        {
            // The title bar shows even a lone buffer's tab (VS Code-style).
            var scr = try h.Screen.init(ctx.gpa, 24, 80);
            defer scr.deinit();
            scr.apply(s.out.items);
            ctx.check("a single buffer already has its tab", scr.colOf(ctx.gpa, 1, "one.txt") != null);
        }
        const m = s.mark();
        s.send(":e two.txt\r");
        s.drain(600);
        ctx.check("tabs list both buffers", s.containsPlainSince(ctx.gpa, m, "one.txt") and
            s.containsPlainSince(ctx.gpa, m, "two.txt"));
        const m2 = s.mark();
        s.send("x"); // edit marks the active tab dirty
        s.drain(400);
        ctx.check("edited buffer is marked in its tab", s.containsPlainSince(ctx.gpa, m2, "two.txt \u{25CF}"));

        // Clicking a tab switches to that buffer; clicks elsewhere are ignored
        // so the terminal's own text selection keeps working.
        const m3 = s.mark();
        s.send("\x1b[<0;3;1M"); // left-click the first tab ("one.txt")
        s.drain(500);
        ctx.check("clicking a tab switches buffer", s.containsPlainSince(ctx.gpa, m3, "first"));
        const m4 = s.mark();
        s.send("\x1b[<0;5;6M"); // a click in the text area does nothing
        s.drain(400);
        ctx.check("clicks outside the tabline are ignored", !s.containsPlainSince(ctx.gpa, m4, "second"));
        s.send(":qa!\r");
        s.drain(200);
    }

    // Grep picker: search 'find', open match in c.txt at line 3, delete a char.
    {
        const files = [_]File{
            .{ .name = "a.txt", .content = "nothing\n" },
            .{ .name = "c.txt", .content = "one\ntwo\nfind me\n" },
        };
        const result = try run_picker(ctx, &files, "a.txt", &.{ " fw", "find", CR, "x", ":wq", CR });
        defer freeResult(ctx, result);
        ctx.check("grep picker opened match at correct line", std.mem.eql(u8, result[1], "one\ntwo\nind me\n"));
    }

    // The file list is cached per session (Zed-style warm picker): a file
    // created after the first walk appears only after Ctrl-r refreshes.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = try std.fmt.allocPrint(ctx.gpa, "{s}/a.txt", .{dir});
        defer ctx.gpa.free(a);
        const late = try std.fmt.allocPrint(ctx.gpa, "{s}/latecomer.txt", .{dir});
        defer ctx.gpa.free(late);
        h.writeFile(ctx.io, a, "aaa\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.send(" ff"); // first open warms the cache
        s.drain(400);
        s.send("\x1b"); // close the picker
        s.drain(200);
        h.writeFile(ctx.io, late, "new\n"); // created after the walk
        s.send(" ff");
        s.drain(400);
        ctx.check("picker list is cached (new file absent)", !s.containsPlain(ctx.gpa, "latecomer"));
        s.send("\x12"); // Ctrl-r: re-walk
        s.drain(400);
        ctx.check("Ctrl-r refreshes the cached file list", s.containsPlain(ctx.gpa, "latecomer"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // Picking a file whose walk index exceeds its line count must open it at
    // the top: PickItem.line holds the *cache index* for the files picker (the
    // prefilter's key), and treating it as a line number parked the cursor on
    // "line 29" of whatever the user opened (clamped to the file's last line).
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        var i: usize = 0;
        while (i < 40) : (i += 1) {
            var nb: [64]u8 = undefined;
            const pad = h.join(ctx, dir, std.fmt.bufPrint(&nb, "pad_{d:0>3}.txt", .{i}) catch unreachable);
            defer ctx.gpa.free(pad);
            h.writeFile(ctx.io, pad, "filler\n");
        }
        const hit = h.join(ctx, dir, "zz_target.txt");
        defer ctx.gpa.free(hit);
        h.writeFile(ctx.io, hit, "first\nsecond\nthird\nfourth\nfifth\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(700);
        s.send("zztarget");
        s.drain(500);
        s.send("\r"); // open it
        s.drain(400);
        s.send("ix"); // an edit lands where the cursor actually is
        s.drain(200);
        s.send("\x1b:wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, hit);
        defer ctx.gpa.free(got);
        const ok = std.mem.startsWith(u8, got, "xfirst");
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check("file picker opens at the top, not at the cache index", ok);
    }

    // ...while the grep picker must keep jumping to the matched line.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const f = h.join(ctx, dir, "one.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "aaa\nbbb\nNEEDLE here\nddd\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(400);
        s.send(" fwNEEDLE");
        s.drain(600);
        s.send("\r");
        s.drain(400);
        s.send("ix");
        s.drain(200);
        s.send("\x1b:wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        const ok = std.mem.indexOf(u8, got, "\nxNEEDLE here\n") != null;
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check("grep picker still jumps to the matched line", ok);
    }

    // A grep typed before the project walk has delivered anything must still
    // cover the files that arrive afterwards. (The picker opens on an empty
    // file cache by design — the walk streams in — so a grep that ran once and
    // never resumed searched nothing at all.)
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        var i: usize = 0;
        while (i < 60) : (i += 1) {
            var nb: [64]u8 = undefined;
            const pad = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, std.fmt.bufPrint(&nb, "pad_{d:0>3}.txt", .{i}) catch unreachable });
            defer ctx.gpa.free(pad);
            h.writeFile(ctx.io, pad, "nothing to see here\n");
        }
        const hit = try std.fmt.allocPrint(ctx.gpa, "{s}/zz_target.txt", .{dir});
        defer ctx.gpa.free(hit);
        h.writeFile(ctx.io, hit, "a line holding GREPMELATE in it\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "pad_000.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(300);
        s.send(" fwGREPMELATE"); // grep before the walk has produced anything
        s.drain(900);
        // The needle itself echoes in the query line, so look for the file.
        ctx.check("grep started mid-walk covers files the walk delivers later", s.containsPlain(ctx.gpa, "zz_target"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // Extending a grep query narrows the hits already found instead of
    // re-reading the project. The results must be the ones a rescan would
    // give: matched on the line text, not on the row's path prefix.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const files = [_][2][]const u8{
            .{ "one.txt", "alpha beta\n" },
            .{ "two.txt", "alphax gamma\n" },
            .{ "alphax_named.txt", "alpha only\n" }, // path matches, text does not
        };
        for (files) |f| {
            const p = try std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, f[0] });
            defer ctx.gpa.free(p);
            h.writeFile(ctx.io, p, f[1]);
        }
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(400);
        s.send(" fw");
        s.drain(300);

        var m = s.mark();
        s.send("alpha");
        s.drain(500);
        ctx.check("grep lists every file whose line matches", s.containsPlainSince(ctx.gpa, m, "one.txt:1") and
            s.containsPlainSince(ctx.gpa, m, "two.txt:1") and s.containsPlainSince(ctx.gpa, m, "alphax_named.txt:1"));

        m = s.mark();
        s.send("x"); // -> "alphax": narrows the hits instead of rescanning
        s.drain(500);
        ctx.check("extending the query narrows to the still-matching line", s.containsPlainSince(ctx.gpa, m, "two.txt:1"));
        ctx.check("narrowing drops a line that no longer matches", !s.containsPlainSince(ctx.gpa, m, "one.txt:1"));
        ctx.check("narrowing matches the line text, not the row's path", !s.containsPlainSince(ctx.gpa, m, "alphax_named.txt:1"));

        m = s.mark();
        s.send("\x7f"); // backspace -> "alpha" again: a shorter query rescans
        s.drain(500);
        ctx.check("shortening the query brings the other hits back", s.containsPlainSince(ctx.gpa, m, "one.txt:1") and
            s.containsPlainSince(ctx.gpa, m, "alphax_named.txt:1"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // Grep patterns are regexes (same modern syntax as `/`). A character
    // class finds what no literal query could: \d\d0 keeps the line with
    // three digits and drops the near-miss.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const f = h.join(ctx, dir, "r.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "value_19x0 nope\nvalue_1990 yes\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "r.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(400);
        const m = s.mark();
        s.send(" fwvalue_1\\d\\d0");
        s.drain(700); // covers the regex-rescan debounce
        ctx.check("grep matches a \\d class no literal could", s.containsPlainSince(ctx.gpa, m, "r.txt:2"));
        ctx.check("grep regex drops the near-miss line", !s.containsPlainSince(ctx.gpa, m, "r.txt:1"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // Alternation spans files: (cat|dog) lists a hit from each.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const files = [_][2][]const u8{
            .{ "cat.txt", "the cat sat\n" },
            .{ "dog.txt", "a dog ran\n" },
            .{ "none.txt", "nothing here\n" },
        };
        for (files) |f| {
            const p = h.join(ctx, dir, f[0]);
            defer ctx.gpa.free(p);
            h.writeFile(ctx.io, p, f[1]);
        }
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "cat.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(400);
        const m = s.mark();
        s.send(" fw(cat|dog)");
        s.drain(700);
        ctx.check("grep alternation matches both files", s.containsPlainSince(ctx.gpa, m, "cat.txt:1") and
            s.containsPlainSince(ctx.gpa, m, "dog.txt:1"));
        ctx.check("grep alternation skips the non-match", !s.containsPlainSince(ctx.gpa, m, "none.txt:1"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // ^ anchors to the line start: only the line that begins with the word.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const f = h.join(ctx, dir, "a.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "root at start\nnot root here\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(400);
        const m = s.mark();
        s.send(" fw^root");
        s.drain(700);
        ctx.check("grep ^ matches only at line start", s.containsPlainSince(ctx.gpa, m, "a.txt:1"));
        ctx.check("grep ^ drops the mid-line occurrence", !s.containsPlainSince(ctx.gpa, m, "a.txt:2"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // An invalid mid-typing pattern (a lone '(') must not crash or clear the
    // picker: the last good results stay on screen with an "incomplete" tag,
    // and completing the group brings the regex to life.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const f = h.join(ctx, dir, "one.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "alpha beta\n");
        const g = h.join(ctx, dir, "two.txt");
        defer ctx.gpa.free(g);
        h.writeFile(ctx.io, g, "gamma delta\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(400);
        s.send(" fwalp");
        s.drain(500);
        ctx.check("grep finds the literal before the '('", onScreen(ctx, &s, "one.txt:1"));

        s.send("(");
        s.drain(500);
        ctx.check("invalid pattern keeps the last good results", onScreen(ctx, &s, "one.txt:1"));
        ctx.check("invalid pattern shows the incomplete tag", onScreen(ctx, &s, "incomplete"));

        s.send("ha)"); // -> "alp(ha)": a valid group again
        s.drain(700);
        ctx.check("completing the group matches again", onScreen(ctx, &s, "one.txt:1"));
        ctx.check("completing the group clears the tag", !onScreen(ctx, &s, "incomplete"));
        ctx.check("the completed group only matches its line", !onScreen(ctx, &s, "two.txt:1"));

        s.send("\r"); // the picker is alive: Enter opens the hit
        s.drain(400);
        s.send("x:wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("picker survives the invalid detour and opens the hit", std.mem.eql(u8, got, "lpha beta\n"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // Ctrl-r re-walks the project under the grep picker. With a regex or a
    // mid-typing-invalid query the refilter cannot regrep synchronously, so
    // the refresh itself must reset the hits and the scan cursor — rows from
    // the old cache (here: a deleted file) must not survive the re-walk.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const keep = h.join(ctx, dir, "keep.txt");
        defer ctx.gpa.free(keep);
        h.writeFile(ctx.io, keep, "alpha keeps\n");
        const gone = h.join(ctx, dir, "gone.txt");
        defer ctx.gpa.free(gone);
        h.writeFile(ctx.io, gone, "alpha goes\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "keep.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(400);
        s.send(" fwalpha");
        s.drain(500);
        ctx.check("grep sees both files before the refresh", onScreen(ctx, &s, "keep.txt:1") and
            onScreen(ctx, &s, "gone.txt:1"));
        s.send("("); // mid-typing invalid: results held, rescan impossible
        s.drain(300);
        h.removeFile(ctx.io, gone); // the project changes under the picker
        s.send("\x12"); // Ctrl-r
        s.drain(700);
        ctx.check("Ctrl-r with an invalid query drops the deleted file's rows", !onScreen(ctx, &s, "gone.txt:1"));
        ctx.check("Ctrl-r with an invalid query re-greps the survivors", onScreen(ctx, &s, "keep.txt:1"));
        ctx.check("the incomplete tag survives the refresh", onScreen(ctx, &s, "incomplete"));
        s.send(")"); // "alpha()": valid again — the debounced rescan converges
        s.drain(700);
        ctx.check("completing the pattern after Ctrl-r rescans the new cache", onScreen(ctx, &s, "keep.txt:1") and
            !onScreen(ctx, &s, "gone.txt:1") and !onScreen(ctx, &s, "incomplete"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    try pickerClicks(ctx);
    try statusRow(ctx);
    try previewPaneReserved(ctx);
    try narrowByKeystroke(ctx);
    try nonameBuffer(ctx);
}

/// Collapsing the preview pane when nothing is selected has to key on the
/// *query*, not merely on an empty result list: `zedit <dir>` paints its
/// first frame before the walk has delivered a single row, so a pane that
/// only appears once rows land would re-lay the whole picker out under the
/// reader a frame later. An empty directory is that state made permanent.
fn previewPaneReserved(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    var s = try h.Session.spawn(ctx.gpa, .{
        .argv = &.{ ctx.zedit, "." },
        .cwd = dir,
        .cols = 110,
        .term = "xterm-256color",
    });
    defer s.finish();
    s.drain(700);
    {
        var scr = try h.Screen.init(ctx.gpa, 24, 110);
        defer scr.deinit();
        scr.apply(s.out.items);
        // The pane's header bar (tokyonight status_seg_bg) on the prompt row,
        // three quarters of the way across the box — found rather than
        // hardcoded, since the box floats.
        const box = boxRect(ctx, &s) orelse h.Rect{ .x = 1, .y = 1, .w = 110, .h = 24 };
        ctx.check("the preview pane is reserved before anything is typed",
            scr.at(box.y + 1, box.x + (box.w * 3) / 4).bg == h.rgb(0x29, 0x2e, 0x42));
    }
    s.send("zq"); // a query nothing matches: now the results do take the width
    s.drain(500);
    {
        var scr = try h.Screen.init(ctx.gpa, 24, 110);
        defer scr.deinit();
        scr.apply(s.out.items);
        const box2 = boxRect(ctx, &s) orelse h.Rect{ .x = 1, .y = 1, .w = 110, .h = 24 };
        ctx.check("a query with no match gives the width back to the results",
            scr.at(box2.y + 1, box2.x + (box2.w * 3) / 4).bg != h.rgb(0x29, 0x2e, 0x42));
    }
    s.send("\x1b:qa!\r");
    s.drain(300);
}

/// The picker has no statusline, so a message set while it is up (the
/// `zedit <dir>` scope hint, a remote listing's count) takes its bottom row.
/// That row must be *reserved* in the layout rather than painted over the
/// list: `pickerLayout` feeds both the renderer and the click hit-test, so a
/// row painted over would still resolve to the result underneath it and open
/// a file the reader cannot see.
fn statusRow(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    // More files than the list has rows (24 rows − title − prompt = 21), so
    // the bottom row would otherwise carry a real, clickable result.
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var nb: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "f{d:0>2}.txt", .{i});
        const p = h.join(ctx, dir, name);
        defer ctx.gpa.free(p);
        h.writeFile(ctx.io, p, "x\n");
    }

    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir, .cols = 110 });
    defer s.finish();
    s.drain(700);
    {
        var scr = try h.Screen.init(ctx.gpa, 24, 110);
        defer scr.deinit();
        scr.apply(s.out.items);
        const txt = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(txt);
        ctx.check("the picker's status message lands on the bottom row",
            std.mem.indexOf(u8, txt, "type to match file NAMES") != null);
    }
    // The picker floats now, so the message sits on the editor's own
    // statusline *outside* the box and there is no result hidden under it.
    // A click there is a click outside a window with a visible border, which
    // dismisses it — the promise the border makes.
    s.send("\x1b[<0;35;24M\x1b[<0;35;24m");
    s.drain(500);
    ctx.check("clicking outside the floating picker dismisses it", !onScreen(ctx, &s, "FILES"));
    s.send("\x1b:qa!\r");
    s.drain(300);
}

/// The files picker narrows instead of rescoring when the query only grows,
/// and a multi-term query must not break that: typed one key at a time,
/// "ed re" has to land on exactly the files a from-scratch rescore would
/// find. `Ctrl-r` forces that rescore (it clears `prev_query`), so the two
/// paths are compared against each other rather than against a guess.
fn narrowByKeystroke(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const names = [_][]const u8{
        "reduced.txt", // "ed" and "re"
        "pipeline_red.txt", // "ed" and "re"
        "edit.txt", // "ed" only  — dropped by the second term
        "order.txt", // "re" only  — dropped by the first
    };
    for (names) |n| {
        const p = h.join(ctx, dir, n);
        defer ctx.gpa.free(p);
        h.writeFile(ctx.io, p, "x\n");
    }

    // Opened on a file, not the directory: the explorer tree would list every
    // name in the sidebar columns and defeat the negative assertions.
    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "reduced.txt" }, .cwd = dir, .cols = 110 });
    defer s.finish();
    s.drain(600);
    s.send(" ff");
    s.drain(500);
    for ([_][]const u8{ "e", "d", " ", "r", "e" }) |k| { // one key, one refilter
        s.send(k);
        s.drain(250);
    }
    ctx.check("narrowing key by key keeps every multi-term match",
        onScreen(ctx, &s, "reduced.txt") and onScreen(ctx, &s, "pipeline_red.txt"));
    ctx.check("narrowing key by key drops the one-term files",
        !onScreen(ctx, &s, "edit.txt") and !onScreen(ctx, &s, "order.txt"));

    s.send("\x12"); // Ctrl-r: re-walk and rescore from scratch, same query
    s.drain(800);
    ctx.check("a full rescore of the same query agrees with the narrowing",
        onScreen(ctx, &s, "reduced.txt") and onScreen(ctx, &s, "pipeline_red.txt") and
            !onScreen(ctx, &s, "edit.txt") and !onScreen(ctx, &s, "order.txt"));
    s.send("\x1b:qa!\r");
    s.drain(300);
}

/// Where something is on screen. The picker floats now, so its rows and
/// columns are not constants any more — a click test that hardcoded them was
/// really testing the layout arithmetic twice instead of testing that the
/// renderer and the hit-test agree. Finding the cell first and clicking *it*
/// is the draw-here-click-here invariant stated directly.
const Cell = struct { row: usize, col: usize };

fn cellOf(ctx: *h.Ctx, s: *h.Session, needle: []const u8, max_col: usize) ?Cell {
    var scr = h.Screen.init(ctx.gpa, 24, 110) catch return null;
    defer scr.deinit();
    scr.apply(s.out.items);
    var row: usize = 1;
    while (row <= 24) : (row += 1) {
        const col = scr.colOf(ctx.gpa, row, needle) orelse continue;
        if (col > max_col) continue;
        return .{ .row = row, .col = col };
    }
    return null;
}

/// The `▶` selection marker's cell, wherever the results are drawn. The row
/// *and* the column: the results are in project-walk order, which is the
/// filesystem's and so differs between machines, meaning no particular
/// filename can be relied on to be the selected one. The marker can.
fn markerAt(ctx: *h.Ctx, s: *h.Session) ?Cell {
    var scr = h.Screen.init(ctx.gpa, 24, 110) catch return null;
    defer scr.deinit();
    scr.apply(s.out.items);
    var row: usize = 1;
    while (row <= 24) : (row += 1) {
        var col: usize = 1;
        while (col <= 110) : (col += 1) {
            if (scr.at(row, col).cp == 0x25B6) return .{ .row = row, .col = col };
        }
    }
    return null;
}

fn markerRow(ctx: *h.Ctx, s: *h.Session) ?usize {
    return (markerAt(ctx, s) orelse return null).row;
}

/// The floating picker's border rectangle, found by its own corner glyphs —
/// so a test never has to repeat the layout arithmetic it is checking.
fn boxRect(ctx: *h.Ctx, s: *h.Session) ?h.Rect {
    var scr = h.Screen.init(ctx.gpa, 24, 110) catch return null;
    defer scr.deinit();
    scr.apply(s.out.items);
    var tl: ?Cell = null;
    var br: ?Cell = null;
    var row: usize = 1;
    while (row <= 24) : (row += 1) {
        var col: usize = 1;
        while (col <= 110) : (col += 1) {
            const cp = scr.at(row, col).cp;
            if (cp == 0x256d and tl == null) tl = .{ .row = row, .col = col };
            if (cp == 0x256f) br = .{ .row = row, .col = col };
        }
    }
    const a = tl orelse return null;
    const b = br orelse return null;
    return .{ .x = a.col, .y = a.row, .w = b.col - a.col + 1, .h = b.row - a.row + 1 };
}

/// True when `row`,`col` has something other than a space on it.
fn cellFilled(ctx: *h.Ctx, s: *h.Session, row: usize, col: usize) bool {
    var scr = h.Screen.init(ctx.gpa, 24, 110) catch return false;
    defer scr.deinit();
    scr.apply(s.out.items);
    const cp = scr.at(row, col).cp;
    return cp != ' ' and cp != 0;
}

/// Where the terminal was left told to put its caret: the cursor-position
/// escape immediately before the last "show cursor". Parsed from the raw
/// stream because that *is* the thing under test — a Screen model would
/// replay it and agree with itself.
fn cursorAt(s: *h.Session) ?Cell {
    const out = s.out.items;
    const show = "\x1b[?25h";
    const at = std.mem.lastIndexOf(u8, out, show) orelse return null;
    const head = out[0..at];
    const esc = std.mem.lastIndexOf(u8, head, "\x1b[") orelse return null;
    const body = head[esc + 2 ..];
    if (body.len == 0 or body[body.len - 1] != 'H') return null;
    var it = std.mem.splitScalar(u8, body[0 .. body.len - 1], ';');
    const row = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    const col = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    return .{ .row = row, .col = col };
}

/// An SGR press+release at a cell.
fn clickAt(s: *h.Session, ctx: *h.Ctx, c: Cell) void {
    var buf: [64]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[<0;{d};{d}M\x1b[<0;{d};{d}m", .{ c.col, c.row, c.col, c.row }) catch return;
    _ = ctx;
    s.send(seq);
}

/// Mouse clicks in the picker view (the whole `zedit .` startup): explorer
/// rows act, result rows select then open, tab clicks land on the buffer,
/// and the prompt/preview stay inert. All zedit-native UI — no nvim ground
/// truth exists for a picker, so the assertions pin the spec directly.
/// Geometry at 110x24: sidebar cols 1-28, prompt row 2 (below the tab bar),
/// results rows 3+ starting at col 29 (41 wide), preview from col 70.
fn pickerClicks(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const sub = h.join(ctx, dir, "sub");
    defer ctx.gpa.free(sub);
    std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
    const a = h.join(ctx, dir, "alpha.txt");
    defer ctx.gpa.free(a);
    const b = h.join(ctx, dir, "beta.txt");
    defer ctx.gpa.free(b);
    const g = h.join(ctx, dir, "sub/gamma.txt");
    defer ctx.gpa.free(g);
    h.writeFile(ctx.io, a, "ALPHA MARKER\nsecond line\n");
    h.writeFile(ctx.io, b, "BETA MARKER\n");
    h.writeFile(ctx.io, g, "GAMMA MARKER\n");

    // The picker is a floating window: a border around it, the editor still
    // visible behind, and the way out written on it.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(600);
        s.send(" ff");
        s.drain(700);
        const box = boxRect(ctx, &s);
        ctx.check("the picker is drawn as a bordered box", box != null and
            box.?.w > 20 and box.?.h > 4 and box.?.x > 1 and box.?.y > 1);
        ctx.check("the box says how to leave", onScreen(ctx, &s, "Esc to close"));
        {
            // The file being edited is still on screen around the box, which
            // is what makes it read as a window over the editor rather than a
            // mode the editor has entered.
            var scr = try h.Screen.init(ctx.gpa, 24, 110);
            defer scr.deinit();
            scr.apply(s.out.items);
            const bar = try scr.rowText(ctx.gpa, 1);
            defer ctx.gpa.free(bar);
            ctx.check("the editor is still visible behind the picker",
                std.mem.indexOf(u8, bar, "alpha.txt") != null);
        }
        s.send("\x1b");
        s.drain(400);
        ctx.check("Esc closes it", !onScreen(ctx, &s, "Esc to close"));
        s.send(":qa!\r");
        s.drain(200);
    }

    // Nothing the picker draws may leave its box. The preview is the one that
    // can: it is told how many rows it has, and handing it the *screen*
    // height painted it straight through the bottom border and over the
    // statusline. A file longer than the box is what shows that.
    {
        const dir2 = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir2);
        defer h.removeTree(ctx.gpa, ctx.io, dir2);
        const long = try std.fmt.allocPrint(ctx.gpa, "{s}/big.zig", .{dir2});
        defer ctx.gpa.free(long);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(ctx.gpa);
        var n: usize = 0;
        while (n < 90) : (n += 1) {
            var lb: [48]u8 = undefined;
            try body.appendSlice(ctx.gpa, std.fmt.bufPrint(&lb, "pub fn overflow_{d}() void {{}}\n", .{n}) catch break);
        }
        h.writeFile(ctx.io, long, body.items);

        // Edit a *different*, short file: the editor renders behind the box, so
        // previewing the file you are already looking at would put "overflow_"
        // on screen legitimately and the leak check would prove nothing.
        const small = try std.fmt.allocPrint(ctx.gpa, "{s}/small.txt", .{dir2});
        defer ctx.gpa.free(small);
        h.writeFile(ctx.io, small, "just one line\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "small.txt" }, .cwd = dir2, .cols = 110, .term = "xterm-256color" });
        defer s.finish();
        s.drain(700);
        s.send(" ff");
        s.drain(600);
        s.send("big"); // select big.zig whatever order the walk returned
        s.drain(900);
        var box: ?h.Rect = null;
        {
            const until = h.nowMs() + 6000;
            while (h.nowMs() < until and box == null) {
                box = boxRect(ctx, &s);
                if (box == null) s.drain(150);
            }
        }
        ctx.check("the picker box is drawn", box != null);
        if (box) |bx| {
            var scr = try h.Screen.init(ctx.gpa, 24, 110);
            defer scr.deinit();
            scr.apply(s.out.items);
            // Every cell of the bottom edge is border or hint — never a line
            // of the previewed file.
            const edge = try scr.rowText(ctx.gpa, bx.y + bx.h - 1);
            defer ctx.gpa.free(edge);
            ctx.check("the preview does not paint through the bottom border",
                std.mem.indexOf(u8, edge, "overflow_") == null and
                    std.mem.indexOf(u8, edge, "Esc to close") != null);
            // And nothing of it is below the box at all.
            var leaked = false;
            var r: usize = bx.y + bx.h;
            while (r <= 24) : (r += 1) {
                const t = try scr.rowText(ctx.gpa, r);
                defer ctx.gpa.free(t);
                if (std.mem.indexOf(u8, t, "overflow_") != null) leaked = true;
            }
            ctx.check("nothing the picker draws lands below its box", !leaked);
            // The editor's statusline is still the editor's.
            const status = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(status);
            ctx.check("the statusline survives a picker with a long preview",
                std.mem.indexOf(u8, status, "overflow_") == null);
        }
        s.send("\x1b:qa!\r");
        s.drain(300);
    }

    // The caret sits after the text you typed. The prompt's width was being
    // recomputed at the cursor-placement line instead of taken from what the
    // renderer actually drew, so in a floating box — where the prompt is a
    // two-cell caret rather than the picker's name — it sat six columns past
    // the query.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(600);
        s.send(" ff");
        s.drain(800);
        var box: ?h.Rect = null;
        {
            const until = h.nowMs() + 6000;
            while (h.nowMs() < until and box == null) {
                box = boxRect(ctx, &s);
                if (box == null) s.drain(150);
            }
        }
        if (box) |bx| {
            // The query starts at the inside of the box plus the two-cell
            // caret, so after N characters the cursor is N cells further on.
            const query_x = bx.x + 1 + 2;
            for ([_][]const u8{ "a", "b", "c" }, 1..) |ch, n| {
                s.send(ch);
                s.drain(400);
                const cur = cursorAt(&s);
                ctx.check("the picker caret sits just after the typed query",
                    cur != null and cur.?.col == query_x + n);
            }
        }
        s.send("\x1b:qa!\r");
        s.drain(300);
    }

    // Explorer + result-row clicks, and the inert areas, in one session.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(700);
        ctx.check("click test starts in the picker view", onScreen(ctx, &s, "FILES") and onScreen(ctx, &s, "EXPLORER"));

        // (a) A directory row toggles under the live picker. The assert is
        // column-scoped to the sidebar: "gamma.txt" also shows in the result
        // column (as sub/gamma.txt), which must not satisfy it.
        // The tree lives to the left of the floating picker; find its "sub"
        // row and click exactly where it is drawn.
        {
            const until = h.nowMs() + 5000;
            while (h.nowMs() < until and cellOf(ctx, &s, "sub", 20) == null) s.drain(150);
        }
        if (cellOf(ctx, &s, "sub", 20)) |c| clickAt(&s, ctx, c);
        s.drain(500);
        {
            var scr = try h.Screen.init(ctx.gpa, 24, 110);
            defer scr.deinit();
            scr.apply(s.out.items);
            const col = scr.colOf(ctx.gpa, 3, "gamma.txt");
            ctx.check("clicking a directory row expands it in the tree", col != null and col.? < 28);
        }
        ctx.check("the picker survives a directory toggle", onScreen(ctx, &s, "FILES"));

        // (b) First click on a result row selects it (the ▶ moves; the
        // preview follows exactly as Ctrl-n would).
        // Wait for the walk to put alpha.txt on the selected row with another
        // result under it. Clicking a screen that has not settled clicks
        // nowhere, and CI walks the tree slower than a workstation does — the
        // outcome is what to wait for, never a fixed number of milliseconds.
        var first_row: usize = 0;
        var list_col: usize = 0;
        const settle = h.nowMs() + 5000;
        while (h.nowMs() < settle) {
            if (markerAt(ctx, &s)) |m| {
                first_row = m.row;
                list_col = m.col + 2; // the text starts after "▶ "
            }
            if (first_row != 0 and cellFilled(ctx, &s, first_row + 1, list_col)) break;
            s.drain(150);
        }
        ctx.check("the result list settled with a row to click",
            first_row != 0 and cellFilled(ctx, &s, first_row + 1, list_col));
        clickAt(&s, ctx, .{ .row = first_row + 1, .col = list_col });
        s.drain(400);
        ctx.check("clicking a result row selects it", markerRow(ctx, &s) == first_row + 1);

        // Inert areas: the prompt row, the preview pane, and non-press mouse
        // reports (wheel release, drag) change nothing.
        clickAt(&s, ctx, .{ .row = first_row - 1, .col = list_col }); // the prompt row
        s.drain(300);
        clickAt(&s, ctx, .{ .row = first_row + 1, .col = list_col + 40 }); // the preview pane
        s.drain(300);
        s.send("\x1b[<64;80;10m\x1b[<32;80;10M"); // wheel release + drag
        s.drain(300);
        ctx.check("prompt, preview and non-press reports stay inert", onScreen(ctx, &s, "FILES") and
            markerRow(ctx, &s) == first_row + 1);

        // (b) A click on the already-selected row opens it — a double-click
        // opens from anywhere, with no double-click timer.
        clickAt(&s, ctx, .{ .row = first_row + 1, .col = list_col });
        s.drain(500);
        ctx.check("clicking the selected row opens it", !onScreen(ctx, &s, "FILES") and onScreen(ctx, &s, "NORMAL"));
        s.send(":qa!\r");
        s.drain(200);
    }

    // (a) A file row in the explorer: the picker closes first (openFile never
    // touches the mode), then the file opens.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(700);
        {
            const until = h.nowMs() + 5000;
            while (h.nowMs() < until and cellOf(ctx, &s, "alpha.txt", 20) == null) s.drain(150);
        }
        if (cellOf(ctx, &s, "alpha.txt", 20)) |c| clickAt(&s, ctx, c); // the tree's row
        s.drain(600);
        ctx.check("an explorer file click closes the picker and opens the file", !onScreen(ctx, &s, "FILES") and
            onScreen(ctx, &s, "ALPHA MARKER") and onScreen(ctx, &s, "NORMAL"));
        s.send(":qa!\r");
        s.drain(200);
    }

    // (c) Tab clicks while the picker is up close it and land on the buffer.
    {
        const one = h.join(ctx, dir, "one.txt");
        defer ctx.gpa.free(one);
        const two = h.join(ctx, dir, "two.txt");
        defer ctx.gpa.free(two);
        h.writeFile(ctx.io, one, "first\n");
        h.writeFile(ctx.io, two, "second\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 110 });
        defer s.finish();
        s.drain(500);
        s.send(":e two.txt\r"); // two tabs; two.txt active
        s.drain(400);
        s.send(" ff");
        s.drain(400);
        ctx.check("the picker is up before the tab click", onScreen(ctx, &s, "FILES"));
        s.send("\x1b[<0;3;1M\x1b[<0;3;1m"); // the inactive one.txt tab
        s.drain(500);
        ctx.check("a tab click closes the picker", !onScreen(ctx, &s, "FILES"));
        s.send("x:w\r"); // the edit lands in one.txt: the click switched to it
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, one);
        defer ctx.gpa.free(got);
        ctx.check("a tab click lands on that buffer", std.mem.eql(u8, got, "irst\n"));

        s.send(" ff");
        s.drain(400);
        s.send("\x1b[<0;3;1M\x1b[<0;3;1m"); // the *active* tab: just closes
        s.drain(400);
        ctx.check("clicking the active tab just closes the picker", !onScreen(ctx, &s, "FILES") and
            onScreen(ctx, &s, "NORMAL"));
        s.send(":qa!\r");
        s.drain(200);
    }
}

/// vim's rule (nvim-verified: `:e file` from an *unmodified* unnamed buffer
/// reuses it — gone even from `:ls!`; a modified one is kept): opening a file
/// on top of the untouched [No Name] buffer a `zedit .`/empty session starts
/// with must not leave it behind in `:ls` and the tab bar.
fn nonameBuffer(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const hello = h.join(ctx, dir, "hello.txt");
    defer ctx.gpa.free(hello);
    h.writeFile(ctx.io, hello, "hello\n");
    const other = h.join(ctx, dir, "other.txt");
    defer ctx.gpa.free(other);
    h.writeFile(ctx.io, other, "other\n");

    // Picker route: `zedit .`, pick hello.txt.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir });
        defer s.finish();
        s.drain(600);
        s.send("hello\r");
        s.drain(600);
        s.send(":ls\r");
        s.drain(400);
        ctx.check("picker open adopts the untouched [No Name] buffer", onScreen(ctx, &s, "1*:hello.txt") and
            !onScreen(ctx, &s, "[No Name]"));
        s.send("\x0f"); // Ctrl-o: any jump entry into the freed doc must be purged
        s.drain(300);
        s.send(":q\r");
        s.drain(400);
        ctx.check("jumplist survives the adoption", s.contains("\x1b[?1049l"));
    }
    // `:e` route from the empty buffer behind a cancelled picker.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir });
        defer s.finish();
        s.drain(600);
        s.send("\x1b:e hello.txt\r");
        s.drain(500);
        s.send(":ls\r");
        s.drain(400);
        ctx.check(":e adopts the untouched [No Name] buffer", onScreen(ctx, &s, "1*:hello.txt") and
            !onScreen(ctx, &s, "[No Name]"));
        s.send(":q\r");
        s.drain(300);
    }
    // Negative: a *modified* unnamed buffer is kept (vim keeps it too).
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir });
        defer s.finish();
        s.drain(600);
        s.send("\x1bihi\x1b"); // dirty the unnamed buffer
        s.drain(300);
        s.send(":e hello.txt\r:ls\r");
        s.drain(500);
        ctx.check("a modified [No Name] buffer is kept", onScreen(ctx, &s, "1:[No Name]") and
            onScreen(ctx, &s, "2*:hello.txt"));
        s.send(":qa!\r");
        s.drain(300);
    }
    // Negative: an unnamed buffer still shown in another window is kept.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "." }, .cwd = dir });
        defer s.finish();
        s.drain(600);
        s.send("\x1b:split\r:e hello.txt\r:ls\r");
        s.drain(600);
        ctx.check("an unnamed buffer visible in another window is kept", onScreen(ctx, &s, "1:[No Name]") and
            onScreen(ctx, &s, "2*:hello.txt"));
        s.send(":qa\r");
        s.drain(300);
    }
    // Negative: the tutor buffer is unnamed but *non-empty* — never discarded.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--tutor" }, .cwd = dir });
        defer s.finish();
        s.drain(600);
        s.send(":e hello.txt\r:ls\r");
        s.drain(500);
        ctx.check("the tutor buffer is kept across :e", onScreen(ctx, &s, "1:[No Name]") and
            onScreen(ctx, &s, "2*:hello.txt"));
        s.send(":qa\r");
        s.drain(300);
    }
}
