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

    try bufferClose(ctx);
}

/// `:bd` semantics, pinned to nvim ground truth (0.12.4 --clean through a
/// pty, no -c args, one buffer /tmp/zbd/one.txt):
///   clean:  `:bd` -> the window STAYS over an empty buffer, statusline
///           `[No Name]  0,0-1  All`; `:ls` -> exactly one entry, a NEW
///           buffer number: `  2 %a   "[No Name]"   line 1`.
///   dirty:  `:bd` -> `E89: No write since last change for buffer 1 (add !
///           to override)`, buffer kept; `:bd!` discards -> `[No Name]`.
///   two buffers, one dirty: `:bd` -> E89 too (zedit used to close it and
///           silently discard the edits).
/// Message text is zedit's house style, not E89 verbatim, so the checks are
/// scenario-level rather than vim_compat byte-parity.
fn bufferClose(ctx: *h.Ctx) !void {
    const LEAVE_ALT = "\x1b[?1049l"; // emitted only when the editor exits
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const one = h.join(ctx, dir, "one.txt");
    defer ctx.gpa.free(one);
    const two = h.join(ctx, dir, "two.txt");
    defer ctx.gpa.free(two);

    // 1. Last buffer, clean: replaced by a fresh [No Name]; window stays.
    {
        h.writeFile(ctx.io, one, "alpha\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        var m = s.mark();
        s.send(":bd\r");
        s.drain(400);
        ctx.check(":bd on the last clean buffer leaves [No Name]", s.containsPlainSince(ctx.gpa, m, "[No Name]"));
        m = s.mark();
        s.send(":ls\r");
        s.drain(300);
        ctx.check("the closed file is gone from :ls", s.containsPlainSince(ctx.gpa, m, "1*:[No Name]") and
            !s.containsPlainSince(ctx.gpa, m, "one.txt"));
        s.send(":q\r"); // the replacement is clean: :q exits
        s.drain(400);
        ctx.check("the editor stays usable and :q exits", s.contains(LEAVE_ALT));
    }

    // 2. Last buffer, dirty: refused without !, discarded with :bd!.
    {
        h.writeFile(ctx.io, one, "alpha\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.send("ochanged\x1b");
        s.drain(200);
        var m = s.mark();
        s.send(":bd\r");
        s.drain(300);
        ctx.check("a dirty :bd refuses (E89 parity)", s.containsPlainSince(ctx.gpa, m, "no write since last change"));
        m = s.mark();
        s.send(":ls\r");
        s.drain(300);
        ctx.check("the refused buffer is kept", s.containsPlainSince(ctx.gpa, m, "1*:one.txt"));
        m = s.mark();
        s.send(":bd!\r");
        s.drain(300);
        ctx.check(":bd! discards the edits", s.containsPlainSince(ctx.gpa, m, "[No Name]"));
        m = s.mark();
        s.send(":ls\r");
        s.drain(300);
        ctx.check("after :bd! only [No Name] is listed", s.containsPlainSince(ctx.gpa, m, "1*:[No Name]") and
            !s.containsPlainSince(ctx.gpa, m, "one.txt"));
        s.send(":q\r");
        s.drain(400);
        ctx.check(":bd! left a clean buffer behind", s.contains(LEAVE_ALT));
        const kept = h.readFile(ctx.gpa, ctx.io, one);
        defer ctx.gpa.free(kept);
        ctx.check("the discarded edits never reached the file", std.mem.eql(u8, kept, "alpha\n"));
    }

    // 3. Two buffers, the dirty one active: :bd refuses (this used to close
    //    it and silently discard the edits); :bd! lands on the other buffer.
    {
        h.writeFile(ctx.io, one, "aaa\n");
        h.writeFile(ctx.io, two, "bbb\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.send(":e two.txt\r");
        s.drain(300);
        s.send(":bp\r"); // back to one.txt
        s.drain(300);
        s.send("x"); // dirty it
        s.drain(200);
        var m = s.mark();
        s.send(":bd\r");
        s.drain(300);
        ctx.check("a dirty :bd refuses with 2+ buffers too", s.containsPlainSince(ctx.gpa, m, "no write since last change"));
        m = s.mark();
        s.send(":ls\r");
        s.drain(300);
        ctx.check("both buffers survive the refusal", s.containsPlainSince(ctx.gpa, m, "1*:one.txt") and
            s.containsPlainSince(ctx.gpa, m, "2:two.txt"));
        m = s.mark();
        s.send(":bd!\r");
        s.drain(300);
        s.send(":ls\r");
        s.drain(300);
        ctx.check(":bd! lands on the other buffer", s.containsPlainSince(ctx.gpa, m, "1*:two.txt") and
            !s.containsPlainSince(ctx.gpa, m, "one.txt"));
        s.send(":q\r");
        s.drain(400);
        ctx.check("the survivor is clean and :q exits", s.contains(LEAVE_ALT));
    }

    // 4. Adoption chain: the fresh [No Name] satisfies openFile's adopt rule,
    //    so a later :e replaces it — vim's full cycle, no phantom buffer.
    {
        h.writeFile(ctx.io, one, "alpha\n");
        h.writeFile(ctx.io, two, "beta\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.send(":bd\r");
        s.drain(300);
        s.send(":e two.txt\r");
        s.drain(400);
        const m = s.mark();
        s.send(":ls\r");
        s.drain(300);
        ctx.check(":e after a last-buffer :bd adopts the [No Name]", s.containsPlainSince(ctx.gpa, m, "1*:two.txt") and
            !s.containsPlainSince(ctx.gpa, m, "[No Name]"));
        s.send(":q\r");
        s.drain(300);
    }

    // 5. Space c (and Space b c) route through the same close: clean replaces,
    //    dirty inherits the refusal.
    {
        h.writeFile(ctx.io, one, "alpha\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        var m = s.mark();
        s.send(" c"); // Space c: close buffer
        s.drain(300);
        ctx.check("Space c on the last clean buffer leaves [No Name]", s.containsPlainSince(ctx.gpa, m, "[No Name]"));
        s.send("ihello\x1b"); // dirty the replacement
        s.drain(200);
        m = s.mark();
        s.send(" c");
        s.drain(300);
        ctx.check("Space c inherits the dirty refusal", s.containsPlainSince(ctx.gpa, m, "no write since last change"));
        s.send(":q!\r");
        s.drain(300);
    }
}
