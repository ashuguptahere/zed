//! Multiple buffers + windows: a vertical split showing two buffers at once,
//! switching the active window between buffers with independent edits, and a
//! Ctrl-w split sharing one buffer.

const std = @import("std");
const h = @import("../harness.zig");

const CTRL_W = "\x17";

/// More splits than the terminal has cells must degrade, not abort: a
/// zero-width window used to underflow the row painter's `gw - 1`. Reachable
/// with no mouse involved, so it lives with the window tests.
fn tinyTerminalSplits(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const path = h.join(ctx, dir, "a.txt");
    defer ctx.gpa.free(path);
    h.writeFile(ctx.io, path, "one\ntwo\n");

    // Three columns, then five vertical splits: each window wants zero width.
    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir, .cols = 3 });
    defer s.finish();
    s.drain(400);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        s.send(":vsplit\r");
        s.drain(200);
    }
    // Still alive and still answering keys?
    s.send(":only\r");
    s.drain(400);
    ctx.check("a terminal too narrow for its splits does not abort", !s.containsPlain(ctx.gpa, "panic"));
    s.send("ix");
    s.drain(200);
    s.send("\x1b:wq\r");
    s.drain(400);
    const got = h.readFile(ctx.gpa, ctx.io, path);
    defer ctx.gpa.free(got);
    ctx.check("and still edits afterwards", std.mem.startsWith(u8, got, "xone"));

    // The same in the other orientation.
    var t = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir, .cols = 40 });
    defer t.finish();
    t.drain(400);
    t.resize(4, 40); // shorter than the splits about to be made
    t.drain(300);
    i = 0;
    while (i < 5) : (i += 1) {
        t.send(":split\r");
        t.drain(200);
    }
    t.send(":only\r");
    t.drain(400);
    ctx.check("a terminal too short for its splits does not abort", !t.containsPlain(ctx.gpa, "panic"));
    t.send(":q!\r");
    t.drain(200);
}

pub fn run(ctx: *h.Ctx) !void {
    try tinyTerminalSplits(ctx);

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

    // 3b. `Space b c` is AstroNvim's "close all buffers except this one" — the
    //     distinct meaning `b c` used to lack (it duplicated `Space c`). It
    //     refuses while any of the others is unsaved, naming it.
    {
        h.writeFile(ctx.io, one, "aaa\n");
        h.writeFile(ctx.io, two, "bbb\n");
        const three = h.join(ctx, dir, "three.txt");
        defer ctx.gpa.free(three);
        h.writeFile(ctx.io, three, "ccc\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        s.send(":e two.txt\r");
        s.drain(300);
        s.send("x"); // dirty two.txt
        s.drain(200);
        s.send(":e three.txt\r");
        s.drain(300);
        var m = s.mark();
        s.send(" bc");
        s.drain(400);
        ctx.check("Space b c refuses while another buffer is dirty", s.containsPlainSince(ctx.gpa, m, "no write since last change"));
        m = s.mark();
        s.send(":ls\r");
        s.drain(300);
        ctx.check("the refusal keeps every buffer", s.containsPlainSince(ctx.gpa, m, "one.txt") and
            s.containsPlainSince(ctx.gpa, m, "two.txt"));
        s.send(":bp\r"); // onto two.txt
        s.drain(300);
        s.send("u:w\r"); // undo the edit and save it
        s.drain(400);
        s.send(":e three.txt\r");
        s.drain(300);
        m = s.mark();
        s.send(" bc");
        s.drain(400);
        ctx.check("Space b c closes the others", s.containsPlainSince(ctx.gpa, m, "closed 2 buffers"));
        m = s.mark();
        s.send(":ls\r");
        s.drain(300);
        ctx.check("only the active buffer is left", s.containsPlainSince(ctx.gpa, m, "1*:three.txt") and
            !s.containsPlainSince(ctx.gpa, m, "one.txt") and !s.containsPlainSince(ctx.gpa, m, "two.txt"));
        m = s.mark();
        s.send("ix\x1b");
        s.drain(300);
        ctx.check("the surviving buffer is still editable", s.containsPlainSince(ctx.gpa, m, "xccc"));
        s.send(":q!\r");
        s.drain(400);
        ctx.check("the editor exits cleanly after close-others", s.contains(LEAVE_ALT));
    }

    // 3c. `Space n` (AstroNvim's <leader>n) opens an empty unnamed buffer in
    //     the active window, leaving the one it replaced open; `Space f u` is
    //     the undo history, which `:undolist` already had but no key did.
    {
        h.writeFile(ctx.io, one, "aaa\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        var m = s.mark();
        s.send(" ");
        s.drain(300);
        ctx.check("Space lists the new group", s.containsPlainSince(ctx.gpa, m, "new "));
        m = s.mark();
        s.send("n");
        s.drain(400);
        ctx.check("Space n lists buffer/file/folder", s.containsPlainSince(ctx.gpa, m, "new buffer") and
            s.containsPlainSince(ctx.gpa, m, "new file") and s.containsPlainSince(ctx.gpa, m, "new folder"));
        s.send("b");
        s.drain(400);
        m = s.mark();
        s.send(":ls\r");
        s.drain(300);
        ctx.check("Space n opens an empty buffer", s.containsPlainSince(ctx.gpa, m, "[No Name]") and
            s.containsPlainSince(ctx.gpa, m, "one.txt"));
        m = s.mark();
        s.send("inew text\x1b");
        s.drain(300);
        ctx.check("the new buffer is editable", s.containsPlainSince(ctx.gpa, m, "new text"));
        s.send(":bp\r");
        s.drain(300);
        ctx.check("the replaced buffer is still open", s.containsPlain(ctx.gpa, "aaa"));
        // The undo picker: two edits, then the history listed under Space f u.
        s.send("ix\x1bib\x1b");
        s.drain(300);
        m = s.mark();
        s.send(" fu");
        s.drain(500);
        ctx.check("Space f u opens the undo history", s.containsPlainSince(ctx.gpa, m, "UNDO TREE"));
        s.send("\x1b");
        s.drain(200);
        s.send(":qa!\r");
        s.drain(400);
    }

    // 3d. `Space n f` / `n d` create a file or folder without the tree — the
    //     same prompts `a`/`A` open there, and a whole path works, so one
    //     command makes every missing directory on the way.
    {
        const nested = h.join(ctx, dir, "deep/nest");
        defer ctx.gpa.free(nested);
        h.runQuiet(ctx.gpa, ctx.io, &.{ "rm", "-rf", nested });
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "one.txt" }, .cwd = dir, .cols = 100 });
        defer s.finish();
        s.drain(400);
        var m = s.mark();
        s.send(" nf");
        s.drain(400);
        ctx.check("Space n f prompts for a file", s.containsPlainSince(ctx.gpa, m, "new file:"));
        s.send("deep/nest/mod.zig\r");
        s.drain(700);
        ctx.check("Space n f creates it through missing directories",
            s.containsPlainSince(ctx.gpa, m, "created deep/nest/mod.zig"));
        m = s.mark();
        s.send("ihello\x1b:w\r");
        s.drain(600);
        const made = h.join(ctx, dir, "deep/nest/mod.zig");
        defer ctx.gpa.free(made);
        const got = h.readFile(ctx.gpa, ctx.io, made);
        defer ctx.gpa.free(got);
        ctx.check("the created file is the one being edited", std.mem.eql(u8, got, "hello\n"));
        m = s.mark();
        s.send(" nd");
        s.drain(400);
        s.send("\x15another/level\r"); // Ctrl-u clears the prefill
        s.drain(700);
        ctx.check("Space n d creates nested folders", s.containsPlainSince(ctx.gpa, m, "created another/level/"));
        s.send(":qa!\r");
        s.drain(400);
        const dirmade = h.join(ctx, dir, "another/level");
        defer ctx.gpa.free(dirmade);
        const st = std.Io.Dir.cwd().statFile(ctx.io, dirmade, .{}) catch {
            ctx.check("the folder exists on disk", false);
            return;
        };
        ctx.check("the folder exists on disk", st.kind == .directory);
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

    // 6. Ctrl-w resizes the split, and `:winsave` makes the proportions stick.
    {
        h.writeFile(ctx.io, one, "a\nb\nc\nd\ne\nf\n");
        const cfg = h.join(ctx, dir, "cfg");
        defer ctx.gpa.free(cfg);
        h.writeFile(ctx.io, cfg, "split_sizes =\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "--config", cfg, "one.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send(":split\r");
        s.drain(500);
        const even = try boundaryRow(ctx, &s);
        // The new (focused) split is the lower one; growing it by five rows
        // must move the boundary up by exactly five.
        s.send("5\x17+");
        s.drain(500);
        const grown = try boundaryRow(ctx, &s);
        ctx.check("5 Ctrl-w + grows the focused window by five rows",
            even != 0 and grown != 0 and even == grown + 5);

        // The other axis is refused with a message naming the keys that work,
        // rather than silently doing nothing.
        var m = s.mark();
        s.send("\x17>");
        s.drain(300);
        ctx.check("Ctrl-w > on a stacked split says which keys to use",
            s.containsPlainSince(ctx.gpa, m, "stacked"));

        // Save, and check what landed in the config: relative numbers summing
        // to the window count, so they mean the same on any terminal.
        m = s.mark();
        s.send(":winsave\r");
        s.drain(600);
        ctx.check(":winsave reports what it wrote", s.containsPlainSince(ctx.gpa, m, "window sizes saved"));
        const saved = h.readFile(ctx.gpa, ctx.io, cfg);
        defer ctx.gpa.free(saved);
        ctx.check("the proportions are in the config file",
            std.mem.indexOf(u8, saved, "split_sizes = 0.55,1.45") != null);

        // Ctrl-w = puts them back to even.
        m = s.mark();
        s.send("\x17=");
        s.drain(400);
        const equal = try boundaryRow(ctx, &s);
        ctx.check("Ctrl-w = tiles evenly again",
            s.containsPlainSince(ctx.gpa, m, "equalized") and equal == even);
        s.send(":q!\r:q!\r");
        s.drain(400);
    }

    // 7. A saved layout comes back in the next session, unasked.
    {
        h.writeFile(ctx.io, one, "a\nb\nc\nd\ne\nf\n");
        const cfg = h.join(ctx, dir, "cfg2");
        defer ctx.gpa.free(cfg);
        h.writeFile(ctx.io, cfg, "split_sizes = 0.55,1.45\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "--config", cfg, "one.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send(":split\r");
        s.drain(500);
        const restored = try boundaryRow(ctx, &s);
        // Even tiling on a 24-row terminal puts the boundary at 12; the saved
        // 0.55/1.45 split is the resized one, five rows higher.
        ctx.check("a split reuses the saved proportions", restored == 7);
        s.send(":q!\r:q!\r");
        s.drain(400);
    }
}

/// The screen row carrying the *first* window's status line — the boundary
/// between two stacked windows, and so a direct read of how the split is
/// divided. Row 1 is the tab bar, which names the file too, hence the skip.
fn boundaryRow(ctx: *h.Ctx, s: *h.Session) !usize {
    var scr = try h.Screen.init(ctx.gpa, 24, 80);
    defer scr.deinit();
    scr.apply(s.out.items);
    var r: usize = 2;
    while (r <= 23) : (r += 1) {
        const t = try scr.rowText(ctx.gpa, r);
        defer ctx.gpa.free(t);
        if (std.mem.indexOf(u8, t, "one.txt") != null and std.mem.indexOf(u8, t, "1:1") != null) return r;
    }
    return 0;
}
