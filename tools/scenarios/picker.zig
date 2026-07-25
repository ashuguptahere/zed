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
        .term = "xterm",
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
        ctx.check("no tabline for a single buffer", !s.containsPlain(ctx.gpa, "one.txt  "));
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

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir, .term = "xterm" });
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
}
