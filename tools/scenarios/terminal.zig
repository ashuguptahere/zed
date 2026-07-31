//! The embedded terminal (`Space t`, `:terminal`): a real shell on its own
//! pty, rendered from the `vt.zig` grid, with nvim's mode split — keys go to
//! the child in Terminal mode, `Ctrl-\ Ctrl-n` returns to normal, `i` goes
//! back. The emulator itself is unit-tested in `vt.zig`; what is checked here
//! is that a shell really runs, its output reaches the screen, the modes and
//! the window lifecycle behave, and an exited shell cannot be typed into.
//!
//! `sh` is used rather than the developer's `$SHELL`, so the prompt and the
//! startup files are the same everywhere this runs.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const CTRL_BACKSLASH = "\x1c";
const CTRL_N = "\x0e";

pub fn run(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const f = h.join(ctx, dir, "f.txt");
    defer ctx.gpa.free(f);
    h.writeFile(ctx.io, f, "alpha\nbeta\n");
    // A predictable shell: no rc files, a fixed one-character prompt.
    const shell_env = "SHELL=/bin/sh";
    const ps1_env = "PS1=$ ";

    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", shell_env, ps1_env, ctx.zedit, "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        var m = s.mark();
        s.send(" ");
        s.drain(300);
        ctx.check("Space lists the terminal key", s.containsPlainSince(ctx.gpa, m, "terminal"));
        m = s.mark();
        s.send("t");
        s.drain(1200);
        ctx.check("Space t enters Terminal mode", s.containsPlainSince(ctx.gpa, m, "TERMINAL"));
        ctx.check("the file is still open beside it", s.containsPlain(ctx.gpa, "alpha"));

        // The shell really runs: a command's output lands on the grid.
        m = s.mark();
        s.send("echo ZEDIT_SHELL_OK" ++ CR);
        s.drain(1500);
        ctx.check("the shell runs a command", s.containsPlainSince(ctx.gpa, m, "ZEDIT_SHELL_OK"));

        // Colour from the child reaches the screen as colour, not as text.
        m = s.mark();
        s.send("printf '\\033[31mREDTEXT\\033[0m\\n'" ++ CR);
        s.drain(1500);
        ctx.check("the child's colour is rendered", s.containsPlainSince(ctx.gpa, m, "REDTEXT") and
            s.contains("\x1b[38;2;205;0;0m"));
        // Untrusted bytes stay inert: a C1 control the child prints (U+009B is
        // the 8-bit CSI) must be sanitized, never forwarded to the *outer*
        // terminal where it would start a real escape sequence. `vt.zig`
        // filters C0 before the grid; a C1 arrives as a codepoint and is the
        // case `isControlCp` in the renderer exists for.
        m = s.mark();
        s.send("printf 'A\\302\\233B\\n'" ++ CR);
        s.drain(1500);
        const raw_out = s.out.items[m..];
        ctx.check("a C1 control from the child never reaches the terminal",
            std.mem.indexOf(u8, raw_out, "\xc2\x9b") == null);
        ctx.check("and the text around it still renders", s.containsPlainSince(ctx.gpa, m, "A?B"));

        // Ctrl-\ Ctrl-n leaves Terminal mode; `i` goes back in.
        m = s.mark();
        s.send(CTRL_BACKSLASH ++ CTRL_N);
        s.drain(600);
        ctx.check("Ctrl-backslash Ctrl-n returns to normal mode", s.containsPlainSince(ctx.gpa, m, "normal mode"));
        m = s.mark();
        s.send("i");
        s.drain(500);
        ctx.check("i re-enters the terminal", s.containsPlainSince(ctx.gpa, m, "TERMINAL"));

        // A second Space t opens *another* terminal in the same pane, named in
        // sequence, and the row above them lists both.
        s.send(CTRL_BACKSLASH ++ CTRL_N);
        s.drain(400);
        s.send(" t");
        s.drain(1200);
        var scr2 = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr2.deinit();
        scr2.apply(s.out.items);
        var tabs_row: []u8 = &.{};
        var rr: usize = 1;
        while (rr <= scr2.rows) : (rr += 1) {
            const rt = try scr2.rowText(ctx.gpa, rr);
            if (std.mem.indexOf(u8, rt, "t1") != null and std.mem.indexOf(u8, rt, "t2") != null) {
                if (tabs_row.len > 0) ctx.gpa.free(tabs_row);
                tabs_row = rt;
            } else ctx.gpa.free(rt);
        }
        defer if (tabs_row.len > 0) ctx.gpa.free(tabs_row);
        ctx.check("a second terminal is opened and both are named", tabs_row.len > 0);
        ctx.check("the terminal tabs carry a close box",
            tabs_row.len > 0 and std.mem.indexOf(u8, tabs_row, "\u{2715}") != null);
        s.send(CTRL_BACKSLASH ++ CTRL_N);
        s.drain(400);
        m = s.mark();
        s.send(":ls" ++ CR);
        s.drain(500);
        const listing = try s.plainSince(ctx.gpa, m);
        defer ctx.gpa.free(listing);
        ctx.check("the file is still listed beside them",
            std.mem.indexOf(u8, listing, "f.txt") != null);
        s.send(":qa!" ++ CR);
        s.drain(600);
    }

    // --- an exited shell is reported and dismissed, never typed into --------
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", shell_env, ps1_env, ctx.zedit, "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        s.send(" t");
        s.drain(1200);
        var m = s.mark();
        s.send("exit" ++ CR); // `exit` closes the terminal, as in VS Code
        s.drain(1500);
        ctx.check("exit closes the terminal by itself", s.containsPlainSince(ctx.gpa, m, "terminal closed"));
        ctx.check("and the file is back on screen", s.containsPlainSince(ctx.gpa, m, "alpha"));
        // No keypress needed to dismiss it: `x` here edits the file.
        m = s.mark();
        s.send("x:w" ++ CR);
        s.drain(700);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("the file is editable straight after the shell exits",
            std.mem.eql(u8, got, "lpha\nbeta\n"));
        s.send(":qa!" ++ CR);
        s.drain(500);
    }

    // --- the caret sits where you are typing --------------------------------
    // It belongs to the shell, not to the empty scratch buffer behind the
    // grid: without that it parks at the window's top-left corner while the
    // prompt is somewhere else entirely.
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", shell_env, ps1_env, ctx.zedit, "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        s.send(" t");
        s.drain(1200);
        s.send("echo hi");
        s.drain(800);
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        // The cell before the caret is the last character typed.
        const left = if (scr.cur_col > 1) scr.at(scr.cur_row, scr.cur_col - 1).cp else 0;
        ctx.check("the caret follows what is typed in the terminal", left == 'i');
        s.send(CTRL_BACKSLASH ++ CTRL_N);
        s.drain(400);
        s.send(":qa!" ++ CR);
        s.drain(400);
    }

    // --- Ctrl-backtick toggles it, from either mode -------------------------
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", shell_env, ps1_env, ctx.zedit, "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        var m = s.mark();
        s.send("\x00"); // Ctrl-` (NUL, as every terminal sends it)
        s.drain(1200);
        ctx.check("Ctrl-backtick opens the terminal", s.containsPlainSince(ctx.gpa, m, "TERMINAL"));
        // And closes it again from inside, without leaving Terminal mode first.
        m = s.mark();
        s.send("\x00");
        s.drain(800);
        ctx.check("Ctrl-backtick closes it from inside", !s.containsPlainSince(ctx.gpa, m, "TERMINAL"));
        m = s.mark();
        s.send(":ls" ++ CR);
        s.drain(500);
        ctx.check("closing it removes the buffer", !s.containsPlainSince(ctx.gpa, m, "[terminal]"));
        s.send(":q!" ++ CR);
        s.drain(400);
    }

    // --- the terminal tab's close box actually closes it --------------------
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", shell_env, ps1_env, ctx.zedit, "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        s.send(" t");
        s.drain(1200);
        s.send(CTRL_BACKSLASH ++ CTRL_N);
        s.drain(400);
        s.send(" t"); // a second terminal, so closing one leaves the pane up
        s.drain(1200);
        s.send(CTRL_BACKSLASH ++ CTRL_N);
        s.drain(400);
        // Find t1's ✕ on the terminals' tab row and click it.
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        var trow: usize = 0;
        var tcol: usize = 0;
        var r: usize = 1;
        while (r <= scr.rows) : (r += 1) {
            const rt = try scr.rowText(ctx.gpa, r);
            defer ctx.gpa.free(rt);
            const at = std.mem.indexOf(u8, rt, "t1") orelse continue;
            const cross = std.mem.indexOfPos(u8, rt, at, "\u{2715}") orelse continue;
            trow = r;
            var col: usize = 1;
            var bi: usize = 0;
            while (bi < cross) : (col += 1) bi += std.unicode.utf8ByteSequenceLength(rt[bi]) catch 1;
            tcol = col;
            break;
        }
        ctx.check("the terminal tab row shows a close box", trow != 0);
        if (trow != 0) {
            var pb: [32]u8 = undefined;
            var rb: [32]u8 = undefined;
            const m = s.mark();
            s.send(try std.fmt.bufPrint(&pb, "\x1b[<0;{d};{d}M", .{ tcol, trow }));
            s.send(try std.fmt.bufPrint(&rb, "\x1b[<0;{d};{d}m", .{ tcol, trow }));
            s.drain(900);
            var after = try h.Screen.init(ctx.gpa, 24, 80);
            defer after.deinit();
            after.apply(s.out.items);
            var still_t1 = false;
            var has_t2 = false;
            var rr: usize = 1;
            while (rr <= after.rows) : (rr += 1) {
                const rt = try after.rowText(ctx.gpa, rr);
                defer ctx.gpa.free(rt);
                if (std.mem.indexOf(u8, rt, "t1") != null) still_t1 = true;
                if (std.mem.indexOf(u8, rt, "t2") != null) has_t2 = true;
            }
            ctx.check("clicking it closes that terminal", !still_t1);
            ctx.check("and the pane stays for the other one", has_t2);
            _ = m;
        }
        s.send(":qa!" ++ CR);
        s.drain(500);
    }

    // --- scrollback: output that scrolled away is still reachable -----------
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", shell_env, ps1_env, ctx.zedit, "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        s.send(" t");
        s.drain(1200);
        // Print far more lines than the split can show, with a marker at the
        // very top that must have scrolled away.
        s.send("printf 'TOPMARK\\n'; i=0; while [ $i -lt 60 ]; do echo \"line$i\"; i=$((i+1)); done" ++ CR);
        s.drain(2000);
        var m = s.mark();
        ctx.check("the newest output is on screen", s.containsPlainSince(ctx.gpa, m -| 4000, "line59"));
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        scr.apply(s.out.items);
        var top_visible = false;
        var r: usize = 1;
        while (r <= scr.rows) : (r += 1) {
            const rt = try scr.rowText(ctx.gpa, r);
            defer ctx.gpa.free(rt);
            if (std.mem.indexOf(u8, rt, "TOPMARK") != null) top_visible = true;
        }
        scr.deinit();
        ctx.check("the oldest output has scrolled off", !top_visible);

        // Ctrl-\ Ctrl-n, then page back until the marker reappears.
        s.send(CTRL_BACKSLASH ++ CTRL_N);
        s.drain(500);
        var found = false;
        var tries: usize = 0;
        while (tries < 20 and !found) : (tries += 1) {
            s.send("\x15"); // Ctrl-u
            s.drain(250);
            var back = try h.Screen.init(ctx.gpa, 24, 80);
            defer back.deinit();
            back.apply(s.out.items);
            var rr: usize = 1;
            while (rr <= back.rows) : (rr += 1) {
                const rt = try back.rowText(ctx.gpa, rr);
                defer ctx.gpa.free(rt);
                if (std.mem.indexOf(u8, rt, "TOPMARK") != null) found = true;
            }
        }
        ctx.check("paging back reaches output that scrolled away", found);
        m = s.mark();
        // Enough forward pages to undo however many back pages it took above.
        var d: usize = 0;
        while (d < 30) : (d += 1) {
            s.send("\x04"); // Ctrl-d
            s.drain(60);
        }
        s.drain(600);
        ctx.check("paging forward returns to the live output",
            s.containsPlainSince(ctx.gpa, m, "live") or s.containsPlainSince(ctx.gpa, m, "already at the live"));
        s.send(":qa!" ++ CR);
        s.drain(500);
    }

    // --- an open shell must not cost CPU while it sits at its prompt --------
    // The whole editor is built on blocking in poll(2); adding a third fd to
    // that set must not turn the loop into a spin. An exited-but-unreaped pty
    // reports POLLHUP on every pass, which is exactly how that would happen.
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", shell_env, ps1_env, ctx.zedit, "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        s.send(" t");
        s.drain(1500); // the shell starts and prints its prompt
        const before = try s.cpuTicks(ctx.gpa, ctx.io);
        s.drain(2000); // idle at the prompt
        const idle_at_prompt = try s.cpuTicks(ctx.gpa, ctx.io) - before;
        ctx.check("an idle shell costs no CPU", idle_at_prompt < 10); // ticks = 10ms each

        // And after the shell exits: on Linux `waitpid` reaps it immediately,
        // so this passes through the ordinary path. The `hung_up` guard in
        // `term.zig` covers the platforms where the pty reports EOF *before*
        // the child is reapable — not reachable here, and said so in TODO.md
        // rather than pretended to be covered.
        s.send("exit" ++ CR);
        s.drain(1200);
        const after_exit = try s.cpuTicks(ctx.gpa, ctx.io);
        s.drain(2000);
        const idle_after_exit = try s.cpuTicks(ctx.gpa, ctx.io) - after_exit;
        ctx.check("an exited shell does not spin the loop", idle_after_exit < 10);
        s.send("x"); // dismiss
        s.drain(400);
        s.send(":qa!" ++ CR);
        s.drain(500);
    }

    // --- a terminal buffer refuses buffer edits and does not block :qa ------
    {
        h.writeFile(ctx.io, f, "alpha\nbeta\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ "env", shell_env, ps1_env, ctx.zedit, "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(700);
        s.send(" t");
        s.drain(1200);
        s.send(CTRL_BACKSLASH ++ CTRL_N);
        s.drain(400);
        var m = s.mark();
        s.send("dd"); // a buffer command over the grid
        s.drain(500);
        ctx.check("a terminal buffer refuses buffer edits", s.containsPlainSince(ctx.gpa, m, "this is a terminal"));
        m = s.mark();
        s.send(":qa" ++ CR); // never "unsaved changes": a grid cannot go dirty
        s.drain(800);
        ctx.check("a terminal does not block :qa", !s.containsPlainSince(ctx.gpa, m, "unsaved changes"));
    }
}
