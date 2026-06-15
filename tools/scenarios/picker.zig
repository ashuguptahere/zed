//! Fuzzy file picker and global search picker end-to-end. Port of
//! tools/picker_test.py. Sets up a temp directory of files, opens zed there,
//! drives the pickers via the space-leader menu, then edits + saves to confirm
//! the right file/line was opened.

const std = @import("std");
const h = @import("../harness.zig");

const CR = "\r";

const File = struct { name: []const u8, content: []const u8 };

/// Create a temp dir, write `files`, open `open_arg` in zed there, replay
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
        .argv = &.{ ctx.zed, open_arg },
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
        const result = try run_picker(ctx, &files, "a.txt", &.{ " f", "b", CR, "x", ":wq", CR });
        defer freeResult(ctx, result);
        ctx.check("file picker opened b.txt and edited it", std.mem.eql(u8, result[1], "bb\n"));
        ctx.check("file picker left a.txt untouched", std.mem.eql(u8, result[0], "aaa\n"));
    }

    // Grep picker: search 'find', open match in c.txt at line 3, delete a char.
    {
        const files = [_]File{
            .{ .name = "a.txt", .content = "nothing\n" },
            .{ .name = "c.txt", .content = "one\ntwo\nfind me\n" },
        };
        const result = try run_picker(ctx, &files, "a.txt", &.{ " /", "find", CR, "x", ":wq", CR });
        defer freeResult(ctx, result);
        ctx.check("grep picker opened match at correct line", std.mem.eql(u8, result[1], "one\ntwo\nind me\n"));
    }
}
