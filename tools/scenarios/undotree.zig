//! The undo tree's own UI: `:undolist` lists every state and jumps to the one
//! picked, and the branch a redo cannot reach is still there to be chosen.
//!
//! The `g-`/`g+`/`:earlier`/`:later` semantics live in `vim_compat`, where they
//! are pinned byte-for-byte against real nvim.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";

pub fn run(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const path = try std.fmt.allocPrint(ctx.gpa, "{s}/u.txt", .{dir});
    defer ctx.gpa.free(path);

    // The list names every state, marks the current one, and flags the point
    // where history branched.
    {
        h.writeFile(ctx.io, path, "one\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "u.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ "IA", ESC, "u", "IB", ESC }); // two branches from "one"
        s.drain(300);
        s.send(":undolist\r");
        s.drain(400);
        ctx.check("undolist is labelled", s.containsPlain(ctx.gpa, "UNDO TREE"));
        ctx.check("undolist shows each state", s.containsPlain(ctx.gpa, "0") and s.containsPlain(ctx.gpa, "2"));
        ctx.check("undolist marks the branch point", s.containsPlain(ctx.gpa, "(branch)"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // Picking a state restores it — including one no amount of redo reaches,
    // because it is on the branch that undo-then-edit left behind.
    {
        h.writeFile(ctx.io, path, "one\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "u.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ "IA", ESC, "u", "IB", ESC }); // "Aone" is now stranded
        s.drain(300);
        s.send(":undolist\r");
        s.drain(400);
        // The list opens on the state the buffer is in (the last row, "Bone");
        // one step up is state 1, the abandoned "Aone".
        s.send("\x1b[A");
        s.drain(200);
        s.send("\r");
        s.drain(300);
        s.send(":wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        const ok = std.mem.eql(u8, got, "Aone\n");
        if (!ok) std.debug.print("       got  \"{f}\"\n", .{std.zig.fmtString(got)});
        ctx.check("picking a state restores the abandoned branch", ok);
    }

    // A count on g- travels several states at once, and running out says so
    // rather than failing silently.
    {
        h.writeFile(ctx.io, path, "one\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "u.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.sendKeys(&.{ "IA", ESC, "IB", ESC, "IC", ESC });
        s.drain(300);
        s.send("3g-");
        s.drain(300);
        ctx.check("a counted g- reports how far it went", s.containsPlain(ctx.gpa, "3 changes back"));
        s.send("g-");
        s.drain(300);
        ctx.check("and stops at the oldest state", s.containsPlain(ctx.gpa, "already at oldest change"));
        s.send(":wq\r");
        s.drain(400);
        const got = h.readFile(ctx.gpa, ctx.io, path);
        defer ctx.gpa.free(got);
        ctx.check("3g- reaches the original text", std.mem.eql(u8, got, "one\n"));
    }

    // A bad argument explains itself instead of doing something surprising.
    {
        h.writeFile(ctx.io, path, "one\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "u.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.send(":earlier soon\r");
        s.drain(300);
        ctx.check("a bad :earlier argument shows the usage", s.containsPlain(ctx.gpa, "usage: :earlier"));
        s.send(":q!\r");
        s.drain(200);
    }
}
