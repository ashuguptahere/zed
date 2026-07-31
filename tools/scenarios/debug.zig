//! The debugger (`Space d`, `:debug`): breakpoints in the gutter, a session
//! driven through a stub adapter (`tools/mock_dap.zig`, so nothing needs
//! lldb-dap or debugpy installed), the cursor following where the program
//! stops, and stepping from there.
//!
//! The DAP client's framing and the breakpoint set are unit-tested in
//! `jsonrpc.zig` and `dap.zig`; what is checked here is the editor's half —
//! the keys, the gutter sign, and the jump to the stop location.

const std = @import("std");
const h = @import("../harness.zig");

const CR = "\r";
const ESC = "\x1b";
// theme.zig git_delete / git_change (the breakpoint dot, and its "stopped
// here" colour).
const RED = "\x1b[38;2;247;118;142m";
const AMBER = "\x1b[38;2;224;175;104m";
const DOT = "\u{25CF}";

pub fn run(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const f = h.join(ctx, dir, "prog.c");
    defer ctx.gpa.free(f);
    h.writeFile(ctx.io,
        f,
        \\int main(void) {
        \\    int a = 1;
        \\    int b = 2;
        \\    int c = a + b;
        \\    return c;
        \\}
        \\
    );

    // --- breakpoints work with no adapter at all ----------------------------
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "prog.c" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(700);
        var m = s.mark();
        s.send(" ");
        s.drain(300);
        ctx.check("Space lists the debug group", s.containsPlainSince(ctx.gpa, m, "debug"));
        s.send("d");
        s.drain(300);
        ctx.check("Space d lists the debug keys", s.containsPlain(ctx.gpa, "toggle breakpoint") and
            s.containsPlain(ctx.gpa, "step over"));
        s.send(ESC); // dismiss the menu still up from the check above
        s.drain(200);
        m = s.mark();
        s.send("jj db"); // line 3
        s.drain(500);
        ctx.check("Space d b sets a breakpoint", s.containsPlainSince(ctx.gpa, m, "breakpoint set at line 3"));
        ctx.check("the breakpoint shows in the gutter", s.contains(RED ++ DOT));
        m = s.mark();
        s.send(" db");
        s.drain(400);
        ctx.check("Space d b again clears it", s.containsPlainSince(ctx.gpa, m, "breakpoint cleared at line 3"));

        // Stepping with no session says so rather than doing nothing.
        m = s.mark();
        s.send(" dn");
        s.drain(400);
        ctx.check("stepping with no session is reported", s.containsPlainSince(ctx.gpa, m, "no debug session"));
        m = s.mark();
        s.send(" dc");
        s.drain(400);
        ctx.check("continuing with no session points at :debug", s.containsPlainSince(ctx.gpa, m, ":debug <program>"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }

    // --- a session through the stub adapter ---------------------------------
    {
        const dap_arg = try std.fmt.allocPrint(ctx.gpa, "--dap={s}", .{ctx.mock_dap});
        defer ctx.gpa.free(dap_arg);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, dap_arg, "prog.c" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        // A breakpoint on line 4, then start: the adapter stops there.
        s.send("jjj db");
        s.drain(500);
        var m = s.mark();
        s.send(":debug ./prog" ++ CR);
        s.drain(1500);
        ctx.check("a session starts", s.containsPlainSince(ctx.gpa, m, "debugging ./prog"));
        ctx.check("the program stops at the breakpoint",
            s.containsPlainSince(ctx.gpa, m, "stopped (breakpoint)") and
                s.containsPlainSince(ctx.gpa, m, "prog.c:4"));
        ctx.check("the stopped line is marked in the gutter", s.contains(AMBER ++ DOT));
        // And the cursor is really *on* that line, not merely reported as
        // being there: `openFile` takes a 0-based row while DAP counts from 1,
        // and the clamp to the last row hides the difference near a file's end.
        m = s.mark();
        s.send("x:w" ++ CR);
        s.drain(600);
        {
            const got = h.readFile(ctx.gpa, ctx.io, f);
            defer ctx.gpa.free(got);
            // Line 4 is "    int c = a + b;" — deleting one character there
            // leaves three leading spaces.
            ctx.check("the cursor sits on the stopped line",
                std.mem.indexOf(u8, got, "\n   int c = a + b;\n") != null);
        }
        s.send("u"); // put it back before the steps below
        s.drain(300);

        // Each step moves one line on, and the message follows it.
        m = s.mark();
        s.send(" dn");
        s.drain(1200);
        ctx.check("step over advances the stop", s.containsPlainSince(ctx.gpa, m, "stopped (step)") and
            s.containsPlainSince(ctx.gpa, m, "prog.c:5"));
        m = s.mark();
        s.send(" di");
        s.drain(1200);
        ctx.check("step into advances again", s.containsPlainSince(ctx.gpa, m, "prog.c:6"));

        // Continue runs to the end, and the adapter terminates.
        m = s.mark();
        s.send(" dc");
        s.drain(1500);
        ctx.check("continue runs the program out", s.containsPlainSince(ctx.gpa, m, "exited"));
        m = s.mark();
        s.send(" dn");
        s.drain(500);
        ctx.check("stepping after the end is refused", s.containsPlainSince(ctx.gpa, m, "ended") or
            s.containsPlainSince(ctx.gpa, m, "no debug session"));
        s.send(":qa!" ++ CR);
        s.drain(500);
    }

    // --- an adapter that does not exist fails cleanly ------------------------
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--dap=/nonexistent/adapter", "prog.c" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        var m = s.mark();
        s.send(":debug ./prog" ++ CR);
        s.drain(1000);
        ctx.check("a missing adapter is reported, not fatal",
            s.containsPlainSince(ctx.gpa, m, "could not start"));
        m = s.mark();
        s.send("ix" ++ ESC);
        s.drain(400);
        ctx.check("the editor still works after a failed start", s.containsPlainSince(ctx.gpa, m, "xint"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }

    // --- a session must not cost CPU while it waits --------------------------
    {
        const dap_arg = try std.fmt.allocPrint(ctx.gpa, "--dap={s}", .{ctx.mock_dap});
        defer ctx.gpa.free(dap_arg);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, dap_arg, "prog.c" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        s.send("jjj db");
        s.drain(400);
        s.send(":debug ./prog" ++ CR);
        s.drain(1500);
        const before = try s.cpuTicks(ctx.gpa, ctx.io);
        s.drain(2000);
        const idle = try s.cpuTicks(ctx.gpa, ctx.io) - before;
        ctx.check("a stopped debug session costs no CPU", idle < 10);
        s.send(":qa!" ++ CR);
        s.drain(500);
    }
}
