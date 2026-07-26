//! File-tree sidebar (Space e) and git diff views (Space g d / g s): the tree
//! renders and opens files, directories expand, the sidebar honours the
//! config's `sidebar = right`, and the diff views open highlighted splits.

const std = @import("std");
const h = @import("../harness.zig");

pub fn run(ctx: *h.Ctx) !void {
    // Sidebar: tree renders, navigation opens a file, a directory expands.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "alpha.txt");
        defer ctx.gpa.free(a);
        const sub = h.join(ctx, dir, "subdir");
        defer ctx.gpa.free(sub);
        const inner = h.join(ctx, dir, "subdir/inner.txt");
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

        // The leader menu works with the explorer focused, too.
        s.send(" e"); // refocus the tree
        s.drain(300);
        s.send(" ");
        s.drain(300);
        ctx.check("Space opens the leader menu in the explorer", s.containsPlain(ctx.gpa, "Find") and
            s.containsPlain(ctx.gpa, "explorer"));
        s.send("\x1b");
        s.drain(200);

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
        const a = h.join(ctx, dir, "a.txt");
        defer ctx.gpa.free(a);
        const cfg = h.join(ctx, dir, "cfg");
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
        const f = h.join(ctx, dir, "f.txt");
        defer ctx.gpa.free(f);
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "init", "-q" });
        h.writeFile(ctx.io, f, "alpha\nbeta\ngamma\n");
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "add", "f.txt" });
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "commit", "-q", "-m", "init" });
        h.writeFile(ctx.io, f, "alpha\nBETA\ngamma\nadded\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        s.send(" g"); // the Git which-key submenu must render (regression:
        s.drain(300); // .space_git was missing from the render switch)
        ctx.check("Space g shows the Git menu", s.containsPlain(ctx.gpa, "diff (inline)"));
        s.send("d"); // continue into the inline diff
        s.drain(600);
        ctx.check("inline diff shows hunks", s.containsPlain(ctx.gpa, "@@") and
            s.containsPlain(ctx.gpa, "+BETA") and s.containsPlain(ctx.gpa, "[diff] f.txt"));
        // The +/- lines are coloured by the .diff lexer (tokyonight green/red
        // fg set immediately before the line text).
        ctx.check("inline diff colours additions green", s.contains("\x1b[38;2;158;206;106m+BETA"));
        ctx.check("inline diff colours removals red", s.contains("\x1b[38;2;247;118;142m-beta"));

        s.send(":close\r"); // back to just the file
        s.drain(300);
        s.send(" gs"); // side-by-side with the index version
        s.drain(600);
        ctx.check("side-by-side shows the index version", s.containsPlain(ctx.gpa, "beta") and
            s.containsPlain(ctx.gpa, "(index)"));
        // Both panes tint changed/added rows (bg = 25% git colour into the
        // tokyonight background: add 59;71;55, change 75;64;54).
        ctx.check("side-by-side tints added lines", s.contains("\x1b[48;2;59;71;55m"));
        ctx.check("side-by-side tints changed lines", s.contains("\x1b[48;2;75;64;54m"));
        s.send(":qa\r");
        s.drain(200);
    }
}
