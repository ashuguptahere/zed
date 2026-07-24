//! The SSH story: OSC 52 clipboard writes (the escape reaches the *local*
//! terminal through the connection), bracketed paste (terminal pastes insert
//! literally — no auto-pairs, no command execution), and row-diffed rendering
//! (an unchanged row is not re-sent, so slow links stay snappy).

const std = @import("std");
const h = @import("../harness.zig");

const target = "/tmp/zedit_it_ssh.txt";

pub fn run(ctx: *h.Ctx) !void {
    // "+yy sends the yanked line to the terminal as OSC 52 base64.
    {
        h.writeFile(ctx.io, target, "hello\nworld\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, target } });
        defer s.finish();
        s.drain(400);
        s.send("\"+yy");
        s.drain(300);
        // base64("hello\n") == "aGVsbG8K"
        ctx.check("\"+yy emits OSC 52 with the yanked text", s.contains("\x1b]52;c;aGVsbG8K\x07"));
        s.send("j\"+yy"); // clipboard register also pastes back internally
        s.drain(200);
        s.send("\"+p");
        s.drain(200);
        s.send(":wq\r");
        s.drain(300);
        const text = h.readFile(ctx.gpa, ctx.io, target);
        defer ctx.gpa.free(text);
        ctx.check("\"+p pastes the clipboard register", std.mem.eql(u8, text, "hello\nworld\nworld\n"));
    }

    // Bracketed paste inserts literally: the "(" gets no auto-pair closer,
    // newlines split lines, and nothing is interpreted as a command.
    {
        h.writeFile(ctx.io, target, "");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, target } });
        defer s.finish();
        s.drain(400);
        s.send("i");
        s.drain(150);
        s.send("\x1b[200~foo (bar\ndd x\x1b[201~"); // "dd x" must NOT run as keys
        s.drain(300);
        s.send("\x1b:wq\r");
        s.drain(300);
        const text = h.readFile(ctx.gpa, ctx.io, target);
        defer ctx.gpa.free(text);
        ctx.check("bracketed paste is literal in insert mode", std.mem.eql(u8, text, "foo (bar\ndd x\n"));
    }

    // Bracketed paste in normal mode inserts at the cursor too (and undoes
    // as a single change).
    {
        h.writeFile(ctx.io, target, "abc\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, target } });
        defer s.finish();
        s.drain(400);
        s.send("\x1b[200~XY\x1b[201~");
        s.drain(250);
        s.send(":wq\r");
        s.drain(300);
        const text = h.readFile(ctx.gpa, ctx.io, target);
        defer ctx.gpa.free(text);
        ctx.check("bracketed paste works in normal mode", std.mem.eql(u8, text, "XYabc\n"));
    }

    // A paste fence split across reads still resolves (the harness sends the
    // pieces with a typing gap, so the editor sees separate reads).
    {
        h.writeFile(ctx.io, target, "");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, target } });
        defer s.finish();
        s.drain(400);
        s.send("i");
        s.drain(150);
        s.send("\x1b[200~split");
        s.drain(120);
        s.send("\x1b[201"); // end fence, missing its final byte
        s.drain(120);
        s.send("~");
        s.drain(250);
        s.send("\x1b:wq\r");
        s.drain(300);
        const text = h.readFile(ctx.gpa, ctx.io, target);
        defer ctx.gpa.free(text);
        ctx.check("paste fence split across reads resolves", std.mem.eql(u8, text, "split\n"));
    }

    // Row-diffed rendering: with absolute line numbers, moving the cursor
    // down re-sends only the rows whose bytes changed — the first line's
    // text must not be transmitted again on the second `j`.
    {
        const cfg = "/tmp/zedit_it_ssh_cfg";
        h.writeFile(ctx.io, cfg, "relative_numbers = false\n");
        h.writeFile(ctx.io, target, "UNIQUEFIRST\nsecond\nthird\nfourth\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, target } });
        defer s.finish();
        s.drain(500);
        s.send("j"); // rows 1 and 2 change (cursorline moves off/onto them)
        s.drain(250);
        const before = s.out.items.len;
        s.send("j"); // rows 2 and 3 change; row 1 must be skipped
        s.drain(250);
        const fresh = s.out.items[before..];
        ctx.check("row diff skips unchanged rows", std.mem.indexOf(u8, fresh, "UNIQUEFIRST") == null and
            std.mem.indexOf(u8, fresh, "third") != null);
        s.send(":q!\r");
        s.drain(200);
    }
}
