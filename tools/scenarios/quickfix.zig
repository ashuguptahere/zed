//! The quickfix list: `Ctrl-q` in a picker keeps every result, `]q`/`[q` walk
//! them, `:copen` shows them in a split where Enter jumps.
//!
//! The stepping rules (wrapping, counts, an empty list) are unit-tested in
//! `quickfix.zig`; what is checked here is the editor's half — that a picker
//! really fills the list, that walking opens the right file at the right
//! line, and that the window is a read-only report rather than something that
//! can go dirty and block `:q`.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const CTRL_Q = "\x11";

pub fn run(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();
    const a = h.join(ctx, dir, "alpha.txt");
    defer ctx.gpa.free(a);
    const b = h.join(ctx, dir, "beta.txt");
    defer ctx.gpa.free(b);
    // Three hits for "needle", across two files and on known lines.
    h.writeFile(ctx.io, a, "one\nneedle here\nthree\nneedle again\n");
    h.writeFile(ctx.io, b, "x\ny\nneedle last\n");

    // --- an empty list refuses politely -------------------------------------
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--lsp", "", "alpha.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(500);
        var m = s.mark();
        s.send("]q");
        s.drain(300);
        ctx.check("]q with nothing in the list says so", s.containsPlainSince(ctx.gpa, m, "quickfix list is empty"));
        m = s.mark();
        s.send(":copen" ++ CR);
        s.drain(400);
        ctx.check(":copen with nothing in the list points at how to fill it",
            s.containsPlainSince(ctx.gpa, m, "Ctrl-q in a picker"));
        s.send(":q!" ++ CR);
        s.drain(300);
    }

    // --- fill it from the grep picker, then walk it -------------------------
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "alpha.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send(" fw"); // grep the project
        s.drain(500);
        s.send("needle");
        s.drain(900); // the debounced rescan
        var m = s.mark();
        s.send(CTRL_Q);
        s.drain(600);
        ctx.check("Ctrl-q sends the picker's results to the quickfix list",
            s.containsPlainSince(ctx.gpa, m, "3 grep results in the quickfix list"));

        // `]q` walks them. The first entry is alpha.txt:2 — jump on and delete
        // a character at each stop, so the files record where we landed.
        m = s.mark();
        s.send("]q");
        s.drain(500);
        ctx.check("]q opens the next entry", s.containsPlainSince(ctx.gpa, m, "(2 of 3)"));
        s.send("x");
        s.drain(200);
        m = s.mark();
        s.send("]q");
        s.drain(500);
        ctx.check("]q crosses into the next file", s.containsPlainSince(ctx.gpa, m, "(3 of 3)") and
            s.containsPlainSince(ctx.gpa, m, "beta.txt"));
        s.send("x");
        s.drain(200);
        // Wrapping: one more comes back to the first entry.
        m = s.mark();
        s.send("]q");
        s.drain(500);
        ctx.check("]q wraps round to the first entry", s.containsPlainSince(ctx.gpa, m, "(1 of 3)"));
        s.send("x");
        s.drain(200);
        s.send(":wa" ++ CR);
        s.drain(600);
        s.send(":qa!" ++ CR);
        s.drain(400);

        const ga = h.readFile(ctx.gpa, ctx.io, a);
        defer ctx.gpa.free(ga);
        const gb = h.readFile(ctx.gpa, ctx.io, b);
        defer ctx.gpa.free(gb);
        // Entries 1 and 2 are alpha.txt lines 2 and 4; entry 3 is beta line 3.
        ctx.check("each stop was the line the result named",
            std.mem.eql(u8, ga, "one\needle here\nthree\needle again\n"));
        ctx.check("and the stop in the other file too", std.mem.eql(u8, gb, "x\ny\needle last\n"));
    }

    // --- :copen lists them; Enter jumps; it cannot go dirty -----------------
    {
        h.writeFile(ctx.io, a, "one\nneedle here\nthree\nneedle again\n");
        h.writeFile(ctx.io, b, "x\ny\nneedle last\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "alpha.txt" },
            .cwd = dir,
            .term = "xterm-256color",
            .cols = 100,
        });
        defer s.finish();
        s.drain(600);
        s.send(" fw");
        s.drain(500);
        s.send("needle");
        s.drain(900);
        s.send(CTRL_Q);
        s.drain(600);
        var m = s.mark();
        s.send(":copen" ++ CR);
        s.drain(700);
        ctx.check(":copen lists every entry", s.containsPlainSince(ctx.gpa, m, "alpha.txt:2") and
            s.containsPlainSince(ctx.gpa, m, "alpha.txt:4") and s.containsPlainSince(ctx.gpa, m, "beta.txt:3"));
        ctx.check("the window names itself", s.containsPlainSince(ctx.gpa, m, "[quickfix] grep"));
        // It is a report: editing is refused, so it can never block `:q`.
        m = s.mark();
        s.send("dd");
        s.drain(300);
        ctx.check("the quickfix window is read-only", s.containsPlainSince(ctx.gpa, m, "read-only"));
        // Enter on the third line jumps to that entry.
        m = s.mark();
        s.send("jj" ++ CR);
        s.drain(700);
        ctx.check("Enter jumps to the entry under the cursor",
            s.containsPlainSince(ctx.gpa, m, "(3 of 3)") and s.containsPlainSince(ctx.gpa, m, "beta.txt"));
        s.send(":cclose" ++ CR);
        s.drain(500);
        m = s.mark(); // *after* the close: the window's own title is on screen until then
        s.send(":ls" ++ CR);
        s.drain(400);
        ctx.check(":cclose removes the window and its buffer",
            !s.containsPlainSince(ctx.gpa, m, "[quickfix]"));
        m = s.mark();
        s.send(":qa" ++ CR); // never "unsaved changes": a report cannot go dirty
        s.drain(600);
        ctx.check("a quickfix window does not block :qa", !s.containsPlainSince(ctx.gpa, m, "unsaved changes"));
    }

    // === the multibuffer (`:cedit` / `Space x e`) ==========================
    // The editable rendering of the same list: excerpts from every file, one
    // buffer, one save.

    // --- an empty list, again politely -------------------------------------
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--lsp", "", "alpha.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(500);
        const m = s.mark();
        s.send(":cedit" ++ CR);
        s.drain(400);
        ctx.check(":cedit with nothing in the list points at how to fill it",
            s.containsPlainSince(ctx.gpa, m, "Ctrl-q in a picker"));
        s.send(":q!" ++ CR);
        s.drain(300);
    }

    // --- it opens, shows every file, and writes them all back --------------
    {
        h.writeFile(ctx.io, a, "one\nneedle here\nthree\nneedle again\n");
        h.writeFile(ctx.io, b, "x\ny\nneedle last\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "alpha.txt" },
            .cwd = dir,
            .term = "xterm-256color",
            .cols = 100,
        });
        defer s.finish();
        s.drain(600);
        s.send(" fw");
        s.drain(500);
        s.send("needle");
        s.drain(900);
        s.send(CTRL_Q);
        s.drain(600);
        var m = s.mark();
        s.send(" xe"); // Space x e — the multibuffer
        s.drain(800);
        ctx.check("Space x e opens the multibuffer", s.containsPlainSince(ctx.gpa, m, "[multibuffer] grep"));
        // Two hits three lines apart in alpha.txt share their context, so
        // they merge into one excerpt: two files, two headers.
        ctx.check("...with a header naming each excerpt's file and line",
            s.containsPlainSince(ctx.gpa, m, "alpha.txt:1") and s.containsPlainSince(ctx.gpa, m, "beta.txt:1"));
        ctx.check("...and the lines around every hit", s.containsPlainSince(ctx.gpa, m, "needle here") and
            s.containsPlainSince(ctx.gpa, m, "needle again") and s.containsPlainSince(ctx.gpa, m, "needle last"));
        // It is editable, unlike `:copen` — that is the whole feature.
        // The buffer is: header, alpha's 4 lines, header, beta's 3 lines —
        // so row 3 is alpha's "needle here" and row 9 is beta's "needle last".
        m = s.mark();
        s.send("3GA!" ++ ESC);
        s.drain(400);
        ctx.check("the multibuffer is editable", !s.containsPlainSince(ctx.gpa, m, "read-only"));
        s.send("9GA?" ++ ESC);
        s.drain(400);
        m = s.mark();
        s.send(":w" ++ CR);
        s.drain(900);
        ctx.check("one :w writes every file it touched", s.containsPlainSince(ctx.gpa, m, "2 file(s) written"));
        const ga = h.readFile(ctx.gpa, ctx.io, a);
        defer ctx.gpa.free(ga);
        const gb = h.readFile(ctx.gpa, ctx.io, b);
        defer ctx.gpa.free(gb);
        ctx.check("the first file has the edit", std.mem.eql(u8, ga, "one\nneedle here!\nthree\nneedle again\n"));
        ctx.check("the second file has its own", std.mem.eql(u8, gb, "x\ny\nneedle last?\n"));
        // A second write has nothing to do — the excerpts now *are* the files.
        m = s.mark();
        s.send(":w" ++ CR);
        s.drain(700);
        ctx.check("writing again reports nothing changed", s.containsPlainSince(ctx.gpa, m, "0 file(s) written"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }

    // --- lines added inside an excerpt land in the file --------------------
    {
        h.writeFile(ctx.io, a, "one\nneedle here\nthree\nneedle again\n");
        h.writeFile(ctx.io, b, "x\ny\nneedle last\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "beta.txt" },
            .cwd = dir,
            .term = "xterm-256color",
            .cols = 100,
        });
        defer s.finish();
        s.drain(600);
        s.send(" fw");
        s.drain(500);
        s.send("needle last");
        s.drain(900);
        s.send(CTRL_Q);
        s.drain(600);
        s.send(":cedit" ++ CR);
        s.drain(800);
        // The one excerpt is beta.txt lines 1-3, under a header: open a line
        // after the last and type into it.
        s.send("Gonew line" ++ ESC);
        s.drain(400);
        s.send(":w" ++ CR);
        s.drain(900);
        const gb = h.readFile(ctx.gpa, ctx.io, b);
        defer ctx.gpa.free(gb);
        ctx.check("a line added in an excerpt is added to the file",
            std.mem.eql(u8, gb, "x\ny\nneedle last\nnew line\n"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }

    // --- the header rows are the structure, so breaking one refuses --------
    {
        h.writeFile(ctx.io, a, "one\nneedle here\nthree\nneedle again\n");
        h.writeFile(ctx.io, b, "x\ny\nneedle last\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "alpha.txt" },
            .cwd = dir,
            .term = "xterm-256color",
            .cols = 100,
        });
        defer s.finish();
        s.drain(600);
        s.send(" fw");
        s.drain(500);
        s.send("needle");
        s.drain(900);
        s.send(CTRL_Q);
        s.drain(600);
        s.send(":cedit" ++ CR);
        s.drain(800);
        var m = s.mark();
        s.send("ggdd:w" ++ CR); // delete the first header
        s.drain(700);
        ctx.check("a removed header refuses the write",
            s.containsPlainSince(ctx.gpa, m, "header line was added or removed"));
        s.send("u"); // put it back, then break one instead
        s.drain(300);
        m = s.mark();
        s.send("ggA!" ++ ESC ++ ":w" ++ CR);
        s.drain(700);
        ctx.check("an edited header refuses too", s.containsPlainSince(ctx.gpa, m, "header line was edited"));
        // Nothing was written on either refusal.
        const ga = h.readFile(ctx.gpa, ctx.io, a);
        defer ctx.gpa.free(ga);
        ctx.check("...and nothing reached the files", std.mem.eql(u8, ga, "one\nneedle here\nthree\nneedle again\n"));
        m = s.mark();
        s.send(":w name.txt" ++ CR);
        s.drain(500);
        ctx.check(":w <name> says what :w here means", s.containsPlainSince(ctx.gpa, m, "writes the files it came from"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }

    // --- a file changed behind its back is reported, not clobbered ---------
    // The excerpt remembers the lines it was built from. If they have moved
    // on, writing this back would silently undo whoever moved them.
    {
        h.writeFile(ctx.io, a, "one\nneedle here\nthree\nneedle again\n");
        h.writeFile(ctx.io, b, "x\ny\nneedle last\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "beta.txt" },
            .cwd = dir,
            .term = "xterm-256color",
            .cols = 100,
        });
        defer s.finish();
        s.drain(600);
        s.send(" fw");
        s.drain(500);
        s.send("needle last");
        s.drain(900);
        s.send(CTRL_Q);
        s.drain(600);
        s.send(":cedit" ++ CR);
        s.drain(800);
        s.send("Gozzz" ++ ESC); // an edit in the multibuffer, waiting to be written
        s.drain(400);
        // beta.txt is open in this session too (it was the file argument):
        // change it there, so the excerpt no longer matches its source.
        s.send(":bp" ++ CR);
        s.drain(500);
        s.send("ggIX" ++ ESC);
        s.drain(400);
        s.send(":bn" ++ CR); // back to the multibuffer
        s.drain(500);
        const m = s.mark();
        s.send(":w" ++ CR);
        s.drain(700);
        ctx.check("a source changed since the multibuffer opened refuses the write",
            s.containsPlainSince(ctx.gpa, m, "changed since this was opened"));
        const gb = h.readFile(ctx.gpa, ctx.io, b);
        defer ctx.gpa.free(gb);
        ctx.check("...and the file on disk is untouched", std.mem.eql(u8, gb, "x\ny\nneedle last\n"));
        s.send(":qa!" ++ CR);
        s.drain(400);
    }
}
