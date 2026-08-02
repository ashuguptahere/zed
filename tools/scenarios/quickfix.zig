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
}
