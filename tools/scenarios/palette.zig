//! The command palette: a searchable list of every command with its binding.
//!
//! Not pinned against another editor — VS Code is not installed here and
//! cannot be driven through a pty. What these checks are for is the promise
//! the list makes: that it names the binding that works under the keymap in
//! force, that filtering finds a command by its name *or* its spelling, and
//! that choosing one runs the same thing the key does.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";

/// A session on a two-line file, under `keymap`.
fn open(ctx: *h.Ctx, dir: []const u8, keymap: []const u8) !h.Session {
    var s = try h.Session.spawn(ctx.gpa, .{
        .argv = &.{ ctx.zedit, "--lsp", "", "p.txt" },
        .cwd = dir,
        .keymap = keymap,
    });
    s.drain(700);
    return s;
}

pub fn run(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();
    const f = h.join(ctx, dir, "p.txt");
    defer ctx.gpa.free(f);
    const body = "alpha\nbravo\n";

    // --- Space f C opens it, and it names the vim bindings -----------------
    {
        h.writeFile(ctx.io, f, body);
        var s = try open(ctx, dir, "vim");
        defer s.finish();
        var m = s.mark();
        s.send(" fC");
        s.drain(500);
        ctx.check("Space f C opens the palette", s.containsPlainSince(ctx.gpa, m, "COMMANDS"));
        ctx.check("...listing a command", s.containsPlainSince(ctx.gpa, m, "Find files"));
        ctx.check("...beside the key that runs it", s.containsPlainSince(ctx.gpa, m, "Space f f"));
        // Filtering matches the title.
        m = s.mark();
        s.send("references");
        s.drain(400);
        ctx.check("typing filters to the match", s.containsPlainSince(ctx.gpa, m, "Find references"));
        ctx.check("...and drops the rest", !s.containsPlainSince(ctx.gpa, m, "Terminal"));
        s.send(ESC);
        s.drain(300);
        // ...and the *spelling*, so an ex name finds the entry that runs it.
        m = s.mark();
        s.send(" fCvsplit");
        s.drain(500);
        ctx.check("an ex name finds its command", s.containsPlainSince(ctx.gpa, m, "Split window vertically"));
        s.send(ESC ++ ":q!" ++ CR);
        s.drain(300);
    }

    // --- the leader menu lists it ------------------------------------------
    {
        h.writeFile(ctx.io, f, body);
        var s = try open(ctx, dir, "vim");
        defer s.finish();
        const m = s.mark();
        s.send(" f");
        s.drain(400);
        ctx.check("Space f lists find commands", s.containsPlainSince(ctx.gpa, m, "find commands"));
        s.send(ESC ++ ":q!" ++ CR);
        s.drain(300);
    }

    // --- `>` in the file picker, VS Code's Quick Open prefix ---------------
    {
        h.writeFile(ctx.io, f, body);
        var s = try open(ctx, dir, "vim");
        defer s.finish();
        const m = s.mark();
        s.send(" ff");
        s.drain(600);
        s.send(">");
        s.drain(500);
        ctx.check("> turns the file picker into the palette", s.containsPlainSince(ctx.gpa, m, "COMMANDS"));
        s.send(ESC ++ ":q!" ++ CR);
        s.drain(300);
    }

    // --- under the non-modal keymap it names *those* keys ------------------
    // The palette is the only route there: Ctrl+Shift+P cannot be told from
    // Ctrl+P by a terminal, so Ctrl-P then `>` is it.
    {
        h.writeFile(ctx.io, f, body);
        var s = try open(ctx, dir, "vscode");
        defer s.finish();
        const m = s.mark();
        s.send("\x10"); // Ctrl-P: the file picker
        s.drain(600);
        s.send(">");
        s.drain(500);
        ctx.check("Ctrl-P then > opens the palette", s.containsPlainSince(ctx.gpa, m, "COMMANDS"));
        s.send("Find files");
        s.drain(400);
        ctx.check("it shows the non-modal binding", s.containsPlainSince(ctx.gpa, m, "Ctrl-p"));
        ctx.check("...not the vim one", !s.containsPlainSince(ctx.gpa, m, "Space f f"));
        s.send(ESC);
        s.drain(300);
    }

    // --- running an entry: the ex kind --------------------------------------
    {
        h.writeFile(ctx.io, f, body);
        var s = try open(ctx, dir, "vim");
        defer s.finish();
        s.send("ixyz" ++ ESC); // make it dirty
        s.drain(300);
        s.send(" fCSave" ++ CR);
        s.drain(700);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("choosing Save writes the file", std.mem.eql(u8, got, "xyzalpha\nbravo\n"));
        s.send(":q!" ++ CR);
        s.drain(300);
    }

    // --- running an entry: the act kind, which opens another picker --------
    {
        h.writeFile(ctx.io, f, body);
        var s = try open(ctx, dir, "vim");
        defer s.finish();
        const m = s.mark();
        s.send(" fCToggle explorer" ++ CR);
        s.drain(700);
        ctx.check("choosing Toggle explorer opens the tree", s.containsPlainSince(ctx.gpa, m, "EXPLORER"));
        s.send(":q!" ++ CR);
        s.drain(300);
    }

    // --- running an entry: the toggle kind ---------------------------------
    {
        h.writeFile(ctx.io, f, body);
        var s = try open(ctx, dir, "vim");
        defer s.finish();
        const m = s.mark();
        s.send(" fCsoft wrap" ++ CR);
        s.drain(700);
        ctx.check("choosing a UI toggle flips it and says so", s.containsPlainSince(ctx.gpa, m, "soft wrap"));
        s.send(":q!" ++ CR);
        s.drain(300);
    }

    // --- running an entry: the prompt kind ---------------------------------
    // A command that takes an argument puts itself on the command line
    // instead of guessing one. ("earlier" names exactly one entry — the
    // filter is fuzzy, so a query like "Set theme" also matches "Choose a
    // theme" and would be testing which of the two scored higher.)
    {
        h.writeFile(ctx.io, f, body);
        var s = try open(ctx, dir, "vim");
        defer s.finish();
        s.send("ixyz" ++ ESC);
        s.drain(300);
        const m = s.mark();
        s.send(" fCearlier" ++ CR);
        s.drain(600);
        ctx.check("an argument command opens the command line", s.containsPlainSince(ctx.gpa, m, ":earlier"));
        // ...and it is a real command line: finish it and the command runs.
        s.send("1" ++ CR);
        s.drain(500);
        s.send(":w" ++ CR);
        s.drain(600);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("...and finishing it runs the command", std.mem.eql(u8, got, body));
        s.send(":q!" ++ CR);
        s.drain(300);
    }

    // --- Esc closes without running ----------------------------------------
    {
        h.writeFile(ctx.io, f, body);
        var s = try open(ctx, dir, "vim");
        defer s.finish();
        s.send("ixyz" ++ ESC);
        s.drain(300);
        s.send(" fCSave" ++ ESC);
        s.drain(500);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("Esc runs nothing", std.mem.eql(u8, got, body));
        s.send(":q!" ++ CR);
        s.drain(300);
    }
}
