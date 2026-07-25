//! Command-line Tab completion (the "wildmenu"): command names, `:e`/`:w`
//! paths (directories complete with a trailing `/` and descend on the next
//! Tab), `:theme` names, the [matches..., original] cycle ring, and hidden
//! files staying hidden. Semantics pinned to real nvim (see the vim_compat
//! history cases for the Up/Down side).

const std = @import("std");
const h = @import("../harness.zig");

const TAB = "\t";
const GRUVBOX_BG = "\x1b[48;2;40;40;40m"; // #282828

fn join(ctx: *h.Ctx, dir: []const u8, name: []const u8) []u8 {
    return std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ dir, name }) catch unreachable;
}

pub fn run(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const alpha = join(ctx, dir, "alpha.txt");
    defer ctx.gpa.free(alpha);
    const alpine = join(ctx, dir, "alpine.txt");
    defer ctx.gpa.free(alpine);
    const hidden = join(ctx, dir, ".hidden.txt");
    defer ctx.gpa.free(hidden);
    const sub = join(ctx, dir, "sub");
    defer ctx.gpa.free(sub);
    const inner = join(ctx, dir, "sub/inner.txt");
    defer ctx.gpa.free(inner);
    h.writeFile(ctx.io, alpha, "aaa\n");
    h.writeFile(ctx.io, alpine, "ppp\n");
    h.writeFile(ctx.io, hidden, "hhh\n");
    std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
    h.writeFile(ctx.io, inner, "iii\n");

    // Path completion: first Tab takes the first match and shows the menu;
    // the second Tab cycles to the next candidate, Enter opens it.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e alp");
        s.drain(200);
        s.send(TAB);
        s.drain(300);
        ctx.check("wildmenu lists both matches", s.containsPlain(ctx.gpa, "alpha.txt") and
            s.containsPlain(ctx.gpa, "alpine.txt"));
        s.send(TAB); // second candidate: alpine.txt
        s.drain(200);
        s.send("\r");
        s.drain(400);
        s.send("x:w\r"); // edit it to prove the right file opened
        s.drain(300);
        const t = h.readFile(ctx.gpa, ctx.io, alpine);
        defer ctx.gpa.free(t);
        ctx.check("Tab Tab Enter opens the second match", std.mem.eql(u8, t, "pp\n"));
        s.send(":qa\r");
        s.drain(200);
    }

    // Cycling past the last candidate restores the typed text (the nvim ring);
    // executing ":e alp" then opens a NEW empty buffer named "alp", which a
    // write materialises as that file.
    {
        const alp = join(ctx, dir, "alp");
        defer ctx.gpa.free(alp);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e alp");
        s.drain(200);
        s.send(TAB ++ TAB ++ TAB); // alpha.txt -> alpine.txt -> back to "alp"
        s.drain(300);
        s.send("\r");
        s.drain(400);
        s.send("iwrapped\x1b:w\r");
        s.drain(300);
        const t = h.readFile(ctx.gpa, ctx.io, alp);
        defer ctx.gpa.free(t);
        ctx.check("cycling wraps back to the typed text", std.mem.eql(u8, t, "wrapped\n"));
        s.send(":qa\r");
        s.drain(200);
    }

    // A unique directory match completes silently with a trailing "/" and the
    // next Tab descends into it; hidden files are never offered.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e su");
        s.drain(200);
        s.send(TAB); // -> :e sub/
        s.drain(250);
        s.send(TAB); // unique content -> :e sub/inner.txt
        s.drain(250);
        s.send("\r");
        s.drain(400);
        s.send("x:w\r");
        s.drain(300);
        const t = h.readFile(ctx.gpa, ctx.io, inner);
        defer ctx.gpa.free(t);
        ctx.check("directory completion descends on next Tab", std.mem.eql(u8, t, "ii\n"));
        ctx.check("hidden files are not offered", !s.containsPlain(ctx.gpa, ".hidden"));
        s.send(":qa\r");
        s.drain(200);
    }

    // Command-name completion: ":form" is not a command, but Tab completes it
    // to ":format", which executes (and reports the missing language server).
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":form" ++ TAB);
        s.drain(250);
        s.send("\r");
        s.drain(400);
        ctx.check("command name completes and executes", s.containsPlain(ctx.gpa, "no language server") and
            !s.containsPlain(ctx.gpa, "unknown command"));
        s.send(":qa\r");
        s.drain(200);
    }

    // --benchmark runs headless and prints the timing report to stdout.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--benchmark", "alpha.txt" }, .cwd = dir, .term = "xterm" });
        defer s.finish();
        s.drain(800);
        ctx.check("--benchmark prints a timing report", s.containsPlain(ctx.gpa, "open") and
            s.containsPlain(ctx.gpa, "serialize") and s.containsPlain(ctx.gpa, "alpha.txt"));
    }

    // Theme-name completion: ":theme gru" Tab -> gruvbox, applied on Enter.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":theme gru" ++ TAB);
        s.drain(250);
        s.send("\r");
        s.drain(400);
        ctx.check(":theme completion applies the theme", s.contains(GRUVBOX_BG));
        s.send(":qa\r");
        s.drain(200);
    }
}
