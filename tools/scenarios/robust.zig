//! Robustness: hostile bytes stay inert (control characters in file content
//! are rendered as placeholders, never emitted as terminal escapes), failed
//! saves are reported in plain English (`:w` and `:wa`), and `:qa` refuses to
//! discard unsaved buffers (nvim-verified; see vim_compat nvim#h5).

const std = @import("std");
const h = @import("../harness.zig");

pub fn run(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

    // A file smuggling an OSC title-set and a clear-screen CSI must render as
    // plain '?' text — the raw escape bytes must never reach the terminal.
    {
        const evil = h.join(ctx, dir, "evil.txt");
        defer ctx.gpa.free(evil);
        h.writeFile(ctx.io, evil, "before \x1b]0;pwned\x07 middle \x1b[2J after\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "evil.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        ctx.check("escape bytes are neutralised", !s.contains("\x1b]0;pwned") and !s.contains("\x1b[2J"));
        ctx.check("neutralised bytes still visible as text", s.containsPlain(ctx.gpa, "]0;pwned"));
        s.send(":q!\r");
        s.drain(200);
    }

    // :w on a read-only file reports "permission denied", not a raw enum.
    {
        const ro = h.join(ctx, dir, "ro.txt");
        defer ctx.gpa.free(ro);
        h.writeFile(ctx.io, ro, "locked\n");
        h.runQuiet(ctx.gpa, ctx.io, &.{ "chmod", "444", ro });
        defer h.runQuiet(ctx.gpa, ctx.io, &.{ "chmod", "644", ro });
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "ro.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send("x:w\r");
        s.drain(400);
        ctx.check(":w failure is plain English", s.containsPlain(ctx.gpa, "permission denied") and
            !s.containsPlain(ctx.gpa, "AccessDenied"));

        // :wa on the same dirty read-only buffer names the failure too.
        s.send(":wa\r");
        s.drain(400);
        ctx.check(":wa reports the failed save", s.containsPlain(ctx.gpa, "1 failed") and
            s.containsPlain(ctx.gpa, "ro.txt"));
        s.send(":q!\r");
        s.drain(200);
    }

    // :qa with unsaved changes refuses with a hint; :qa! then discards.
    {
        const f = h.join(ctx, dir, "f.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "aa\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send("x:qa\r");
        s.drain(400);
        ctx.check(":qa refuses with unsaved changes", s.containsPlain(ctx.gpa, ":wa or :qa!"));
        s.send(":qa!\r");
        s.drain(300);
        const t = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(t);
        ctx.check(":qa! discards the edit", std.mem.eql(u8, t, "aa\n"));
    }
}
