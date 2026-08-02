//! Folds: `zf{motion}` collapses a range to one row, `zo`/`zc`/`za` open and
//! close it, `zR`/`zM` act on all of them, `zd`/`zE` remove them.
//!
//! Which rows are hidden, and how nesting resolves, is unit-tested in
//! `fold.zig`; what is checked here is the editor's half — that the fold
//! really is one row on screen, that `j`/`k` treat it as one line rather than
//! making you press `j` once per hidden line, and that the text is untouched
//! throughout (a fold hides, it does not edit).

const std = @import("std");
const h = @import("../harness.zig");


const ESC = "\x1b";
const CR = "\r";
const eight = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n";



pub fn run(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();
    const f = h.join(ctx, dir, "f.txt");
    defer ctx.gpa.free(f);

    // --- zf hides the body and leaves a header ------------------------------
    {
        h.writeFile(ctx.io, f, eight);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        const m = s.mark();
        s.send("jzf3j"); // fold lines 2..5
        s.drain(500);
        ctx.check("zf reports what it folded", s.containsPlainSince(ctx.gpa, m, "folded 4 lines"));
        var scr = try h.screenOf(ctx, &s, 24, 80);
        ctx.check("the fold header names the count", scr.has(ctx.gpa, "4 lines: l2"));
        ctx.check("the folded body is off screen", !scr.has(ctx.gpa, "l3") and !scr.has(ctx.gpa, "l5"));
        ctx.check("lines outside it still show", scr.has(ctx.gpa, "l1") and scr.has(ctx.gpa, "l6"));
        scr.deinit();

        // `j` treats the fold as one line: from the header it lands on l6, not
        // on a hidden line, and `k` comes back to the header.
        s.send("j");
        s.drain(300);
        s.send("x"); // mark where the cursor is
        s.drain(300);
        s.send("kx"); // back onto the fold header, mark it too
        s.drain(300);
        s.send(":wq" ++ CR);
        s.drain(600);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("j steps over a closed fold in one press and k returns to its header",
            std.mem.eql(u8, got, "l1\n2\nl3\nl4\nl5\n6\nl7\nl8\n"));
    }

    // --- zo / zc / za, and zR / zM -----------------------------------------
    {
        h.writeFile(ctx.io, f, eight);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send("jzf3j");
        s.drain(400);
        s.send("zo"); // open it
        s.drain(400);
        var scr = try h.screenOf(ctx, &s, 24, 80);
        ctx.check("zo shows the body again", scr.has(ctx.gpa, "l3") and scr.has(ctx.gpa, "l5"));
        scr.deinit();
        s.send("zc");
        s.drain(400);
        scr = try h.screenOf(ctx, &s, 24, 80);
        ctx.check("zc hides it again", !scr.has(ctx.gpa, "l3"));
        scr.deinit();
        s.send("za");
        s.drain(400);
        scr = try h.screenOf(ctx, &s, 24, 80);
        ctx.check("za toggles it open", scr.has(ctx.gpa, "l3"));
        scr.deinit();
        var m = s.mark();
        s.send("zM"); // close every fold
        s.drain(400);
        ctx.check("zM closes them all", s.containsPlainSince(ctx.gpa, m, "closed 1 folds"));
        m = s.mark();
        s.send("zR");
        s.drain(400);
        ctx.check("zR opens them all", s.containsPlainSince(ctx.gpa, m, "opened 1 folds"));
        // Removing a fold leaves the text alone.
        m = s.mark();
        s.send("zd");
        s.drain(400);
        ctx.check("zd removes the fold", s.containsPlainSince(ctx.gpa, m, "fold removed"));
        m = s.mark();
        s.send("zo");
        s.drain(300);
        ctx.check("and then there is no fold to open", s.containsPlainSince(ctx.gpa, m, "no fold here"));
        s.send(":q" ++ CR); // unmodified: folding never touched the text
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("folding never edited the buffer", std.mem.eql(u8, got, eight));
    }

    // --- a fold survives editing around it ----------------------------------
    {
        h.writeFile(ctx.io, f, eight);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "f.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send("3jzfj"); // fold lines 4..5
        s.drain(400);
        s.send("ggOnew" ++ ESC); // insert a line at the very top
        s.drain(500);
        var scr = try h.screenOf(ctx, &s, 24, 80);
        // The fold moved down with its text: l4 is still its header and l5 is
        // still hidden.
        ctx.check("a fold moves with the text an edit above it shifts",
            scr.has(ctx.gpa, "2 lines: l4") and !scr.has(ctx.gpa, "l5"));
        scr.deinit();
        s.send(":q!" ++ CR);
        s.drain(300);
    }
}
