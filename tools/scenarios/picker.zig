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
        ctx.check("preview is tree-sitter highlighted", s.contains(KEYWORD) and
            s.containsPlain(ctx.gpa, "const std"));

        var m = s.mark();
        s.send("\x04\x04\x04\x04\x04"); // Ctrl-d pages the preview to the end
        s.drain(700);
        ctx.check("Ctrl-d scrolls the preview", s.containsPlainSince(ctx.gpa, m, "DEEP_MARKER"));

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

    try nonameBuffer(ctx);
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
