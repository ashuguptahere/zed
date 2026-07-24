//! File-tree sidebar (Space e) and git diff views (Space g d / g s): the tree
//! renders and opens files, directories expand, the sidebar honours the
//! config's `sidebar = right`, and the diff views open highlighted splits.

const std = @import("std");
const h = @import("../harness.zig");

fn join(ctx: *h.Ctx, dir: []const u8, name: []const u8) []u8 {
    return std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, name }) catch unreachable;
}

fn git(ctx: *h.Ctx, argv: []const []const u8) void {
    const res = std.process.run(ctx.gpa, ctx.io, .{ .argv = argv }) catch return;
    ctx.gpa.free(res.stdout);
    ctx.gpa.free(res.stderr);
}

pub fn run(ctx: *h.Ctx) !void {
    // Sidebar: tree renders, navigation opens a file, a directory expands.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = join(ctx, dir, "alpha.txt");
        defer ctx.gpa.free(a);
        const sub = join(ctx, dir, "subdir");
        defer ctx.gpa.free(sub);
        const inner = join(ctx, dir, "subdir/inner.txt");
        defer ctx.gpa.free(inner);
        h.writeFile(ctx.io, a, "aaa\n");
        std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
        h.writeFile(ctx.io, inner, "inner\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(" e"); // open + focus the explorer
        s.drain(400);
        ctx.check("sidebar renders the tree", s.containsPlain(ctx.gpa, "EXPLORER") and
            s.containsPlain(ctx.gpa, "subdir") and s.containsPlain(ctx.gpa, "alpha.txt"));

        s.send("\r"); // Enter on subdir (dirs sort first) expands it
        s.drain(400);
        ctx.check("directory expands inline", s.containsPlain(ctx.gpa, "inner.txt"));

        s.send("j\r"); // down to inner.txt, open it
        s.drain(400);
        s.send("x:w\r"); // inner -> nner
        s.drain(400);
        const it = h.readFile(ctx.gpa, ctx.io, inner);
        defer ctx.gpa.free(it);
        ctx.check("sidebar opens the selected file", std.mem.eql(u8, it, "nner\n"));

        s.send(" e"); // toggle closed
        s.drain(300);
        s.send(":qa\r");
        s.drain(200);
    }

    // Config `sidebar = right` still renders (position is config-driven).
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = join(ctx, dir, "a.txt");
        defer ctx.gpa.free(a);
        const cfg = join(ctx, dir, "cfg");
        defer ctx.gpa.free(cfg);
        h.writeFile(ctx.io, a, "aaa\n");
        h.writeFile(ctx.io, cfg, "sidebar = right\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "a.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(" e");
        s.drain(400);
        ctx.check("sidebar = right renders the tree", s.containsPlain(ctx.gpa, "EXPLORER"));
        s.send("q:qa\r");
        s.drain(200);
    }

    // Git diff views in a real repo with a working-tree change.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const f = join(ctx, dir, "f.txt");
        defer ctx.gpa.free(f);
        git(ctx, &.{ "git", "-C", dir, "init", "-q" });
        h.writeFile(ctx.io, f, "alpha\nbeta\ngamma\n");
        git(ctx, &.{ "git", "-C", dir, "add", "f.txt" });
        git(ctx, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "commit", "-q", "-m", "init" });
        h.writeFile(ctx.io, f, "alpha\nBETA\ngamma\nadded\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        s.send(" gd"); // inline unified diff in a split
        s.drain(600);
        ctx.check("inline diff shows hunks", s.containsPlain(ctx.gpa, "@@") and
            s.containsPlain(ctx.gpa, "+BETA") and s.containsPlain(ctx.gpa, "[diff] f.txt"));

        s.send(":close\r"); // back to just the file
        s.drain(300);
        s.send(" gs"); // side-by-side with the index version
        s.drain(600);
        ctx.check("side-by-side shows the index version", s.containsPlain(ctx.gpa, "beta") and
            s.containsPlain(ctx.gpa, "(index)"));
        s.send(":qa\r");
        s.drain(200);
    }
}
