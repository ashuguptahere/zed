//! Multiple buffers + windows: a vertical split showing two buffers at once,
//! switching the active window between buffers with independent edits, and a
//! Ctrl-w split sharing one buffer.

const std = @import("std");
const h = @import("../harness.zig");

const CTRL_W = "\x17";

pub fn run(ctx: *h.Ctx) !void {
    // A vertical split shows two different buffers side by side at once.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "a.txt");
        defer ctx.gpa.free(a);
        const b = h.join(ctx, dir, "b.txt");
        defer ctx.gpa.free(b);
        h.writeFile(ctx.io, a, "alpha\n");
        h.writeFile(ctx.io, b, "bravo\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        s.send(":vsplit\r");
        s.drain(400);
        s.send(":e b.txt\r");
        s.drain(500);
        const plain = s.plain(ctx.gpa) catch "";
        defer ctx.gpa.free(plain);
        const both = std.mem.indexOf(u8, plain, "alpha") != null and std.mem.indexOf(u8, plain, "bravo") != null;
        ctx.check("vsplit shows two buffers at once", both);
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // Two buffers, switched with :e / :bp, edited independently and saved.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "a.txt");
        defer ctx.gpa.free(a);
        const b = h.join(ctx, dir, "b.txt");
        defer ctx.gpa.free(b);
        h.writeFile(ctx.io, a, "aaa\n");
        h.writeFile(ctx.io, b, "bbb\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(500);
        s.send(":e b.txt\r"); // active window -> b
        s.drain(400);
        s.send("x"); // bbb -> bb
        s.drain(150);
        s.send(":w\r");
        s.drain(200);
        s.send(":bp\r"); // back to a
        s.drain(300);
        s.send("x"); // aaa -> aa
        s.drain(150);
        s.send(":w\r");
        s.drain(250);

        const at = h.readFile(ctx.gpa, ctx.io, a);
        defer ctx.gpa.free(at);
        const bt = h.readFile(ctx.gpa, ctx.io, b);
        defer ctx.gpa.free(bt);
        ctx.check("buffer a edited independently", std.mem.eql(u8, at, "aa\n"));
        ctx.check("buffer b edited independently", std.mem.eql(u8, bt, "bb\n"));

        // ]b cycles to the next buffer (AstroNvim binding).
        s.send("]b"); // a -> b
        s.drain(300);
        s.send("x:w\r"); // bb -> b
        s.drain(300);
        const bt2 = h.readFile(ctx.gpa, ctx.io, b);
        defer ctx.gpa.free(bt2);
        ctx.check("]b cycles to the next buffer", std.mem.eql(u8, bt2, "b\n"));

        // Ctrl-o jumps back across buffers (b -> a), Ctrl-i (Tab) forward again.
        s.send("\x0f"); // back to a.txt
        s.drain(300);
        s.send("x:w\r"); // a.txt is "aa" here: x makes it "a"
        s.drain(300);
        const at3 = h.readFile(ctx.gpa, ctx.io, a);
        defer ctx.gpa.free(at3);
        ctx.check("Ctrl-o jumps back across buffers", std.mem.eql(u8, at3, "a\n"));
        s.send("u:w\r"); // undo so the later picker check still sees "aa"
        s.drain(300);

        // Space f b opens the buffer picker; pick a.txt and edit it.
        s.send(" fb");
        s.drain(300);
        s.send("a.txt\r");
        s.drain(300);
        s.send("x:w\r"); // aa -> a
        s.drain(300);
        const at2 = h.readFile(ctx.gpa, ctx.io, a);
        defer ctx.gpa.free(at2);
        ctx.check("buffer picker switches buffers", std.mem.eql(u8, at2, "a\n"));

        s.send(":qa\r");
        s.drain(200);
    }

    // Ctrl-w v splits the same buffer; Ctrl-w w moves focus; the edit lands.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "a.txt");
        defer ctx.gpa.free(a);
        h.writeFile(ctx.io, a, "aaa\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(500);
        s.send(CTRL_W ++ "v"); // vertical split
        s.drain(300);
        s.send(CTRL_W ++ "w"); // focus the other window
        s.drain(300);
        s.send("x"); // shared buffer: aaa -> aa
        s.drain(150);
        s.send(":w\r");
        s.drain(250);
        const at = h.readFile(ctx.gpa, ctx.io, a);
        defer ctx.gpa.free(at);
        ctx.check("Ctrl-w split + navigation edits the shared buffer", std.mem.eql(u8, at, "aa\n"));
        s.send(":qa\r");
        s.drain(200);
    }
}
