//! The non-modal keymaps (`keymap = vscode` / `zed`).
//!
//! These are not pinned against another editor: VS Code and Zed are not
//! installed here and cannot be driven through a pty, so every expectation is
//! zedit's own documented behaviour. What the suite is really for is the
//! promise the setting makes — that typing inserts, that the vim commands are
//! *not* reachable, and that each chord reaches the command it advertises.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";

// xterm modifier encoding: 1 + (1 shift, 2 alt, 4 ctrl).
const S_LEFT = "\x1b[1;2D";
const S_RIGHT = "\x1b[1;2C";
const S_DOWN = "\x1b[1;2B";
const C_RIGHT = "\x1b[1;5C";
const C_HOME = "\x1b[1;5H";
const C_END = "\x1b[1;5F";
const A_UP = "\x1b[1;3A";
const A_DOWN = "\x1b[1;3B";
const SA_DOWN = "\x1b[1;4B";

/// Run `keys` under a given keymap and return the saved file.
fn drive(ctx: *h.Ctx, keymap: []const u8, body: []const u8, keys: []const u8) ![]u8 {
    const dir = try ctx.tempDir();
    const cfg = h.join(ctx, dir, "cfg");
    defer ctx.gpa.free(cfg);
    const f = h.join(ctx, dir, "k.txt");
    defer ctx.gpa.free(f);
    var line: [64]u8 = undefined;
    h.writeFile(ctx.io, cfg, std.fmt.bufPrint(&line, "keymap = {s}\n", .{keymap}) catch "keymap = vim\n");
    h.writeFile(ctx.io, f, body);

    // `.keymap = null` keeps the harness from passing its own `--keymap`:
    // the point here is that the *config file* selects the table.
    var s = try h.Session.spawn(ctx.gpa, .{
        .argv = &.{ ctx.zedit, "--config", cfg, "--lsp", "", "k.txt" },
        .cwd = dir,
        .keymap = null,
    });
    defer s.finish();
    s.drain(600);
    s.send(keys);
    s.drain(700);
    return h.readFile(ctx.gpa, ctx.io, f);
}

fn expect(ctx: *h.Ctx, name: []const u8, got: []u8, want: []const u8) void {
    defer ctx.gpa.free(got);
    ctx.check(name, std.mem.eql(u8, got, want));
}

pub fn run(ctx: *h.Ctx) !void {
    const abc = "alpha\nbravo\ncharlie\n";

    // --- non-modal: typing inserts, and the vim keys do not command --------
    // Under `vim` these letters are commands; under `vscode` they are text.
    // That contrast is the whole setting in one pair of checks.
    expect(ctx, "vim: dd deletes a line", try drive(ctx, "vim", abc, "dd:wq\r"), "bravo\ncharlie\n");
    expect(ctx, "vscode: typing inserts instead", try drive(ctx, "vscode", abc, "dd\x13"), "ddalpha\nbravo\ncharlie\n");
    expect(ctx, "zed is the same table", try drive(ctx, "zed", abc, "xy\x13"), "xyalpha\nbravo\ncharlie\n");

    // --- Ctrl-S saves ------------------------------------------------------
    // Every case above already relies on it; this one names it.
    expect(ctx, "Ctrl-S writes the file", try drive(ctx, "vscode", abc, "Z\x13"), "Zalpha\nbravo\ncharlie\n");

    // --- selection by Shift+motion, and clipboard chords -------------------
    // Two Shift-Rights put the caret on the third cell, and the selection
    // *includes* it — zedit's visual model. VS Code's caret sits between
    // characters and would have cut two. The divergence is documented rather
    // than papered over: making it exact needs the selection model itself to
    // change, which is the multi-selection item still on the roadmap.
    expect(ctx, "Shift+Right selects, Ctrl-X cuts", try drive(ctx, "vscode", abc, S_RIGHT ++ S_RIGHT ++ "\x18\x13"), "ha\nbravo\ncharlie\n");
    // An unshifted motion drops the selection, so the next key just types.
    expect(ctx, "an unshifted motion drops it", try drive(ctx, "vscode", abc, S_RIGHT ++ "\x1b[C" ++ "Z\x13"), "alZpha\nbravo\ncharlie\n");
    // Ctrl-A selects everything; Ctrl-X then empties the file.
    expect(ctx, "Ctrl-A selects all", try drive(ctx, "vscode", abc, "\x01\x18\x13"), "");

    // --- word motion and the line ends -------------------------------------
    expect(ctx, "Ctrl+Right moves a word", try drive(ctx, "vscode", "one two\n", C_RIGHT ++ "Z\x13"), "one Ztwo\n");
    expect(ctx, "Ctrl+Home goes to the top", try drive(ctx, "vscode", abc, C_END ++ C_HOME ++ "Z\x13"), "Zalpha\nbravo\ncharlie\n");
    expect(ctx, "Ctrl+End goes to the bottom", try drive(ctx, "vscode", abc, C_END ++ "Z\x13"), "alpha\nbravo\ncharlieZ\n");

    // --- Alt+Up/Down move a line, Shift+Alt+Down copies it -----------------
    expect(ctx, "Alt+Down moves the line down", try drive(ctx, "vscode", abc, A_DOWN ++ "\x13"), "bravo\nalpha\ncharlie\n");
    expect(ctx, "Alt+Up moves it back", try drive(ctx, "vscode", abc, A_DOWN ++ A_UP ++ "\x13"), abc);
    expect(ctx, "Shift+Alt+Down duplicates it", try drive(ctx, "vscode", abc, SA_DOWN ++ "\x13"), "alpha\nalpha\nbravo\ncharlie\n");

    // --- undo / redo -------------------------------------------------------
    expect(ctx, "Ctrl-Z undoes", try drive(ctx, "vscode", abc, "ZZ\x1a\x13"), abc);
    expect(ctx, "Ctrl-Y redoes", try drive(ctx, "vscode", abc, "Z\x1a\x19\x13"), "Zalpha\nbravo\ncharlie\n");

    // --- Ctrl-/ toggles the comment ----------------------------------------
    // A .txt file has no comment syntax, so this uses a .zig one.
    {
        const dir = try ctx.tempDir();
        const cfg = h.join(ctx, dir, "cfg");
        defer ctx.gpa.free(cfg);
        const f = h.join(ctx, dir, "c.zig");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, cfg, "keymap = vscode\n");
        h.writeFile(ctx.io, f, "const a = 1;\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg, "--lsp", "", "c.zig" },
            .cwd = dir,
            .keymap = null,
        });
        defer s.finish();
        s.drain(700);
        s.send("\x1f\x13"); // Ctrl-/ then Ctrl-S
        s.drain(700);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("Ctrl-/ comments the line", std.mem.eql(u8, got, "// const a = 1;\n"));
    }

    // --- Esc never strands you in a mode you cannot type in ----------------
    expect(ctx, "Esc leaves you able to type", try drive(ctx, "vscode", abc, ESC ++ ESC ++ "Z\x13"), "Zalpha\nbravo\ncharlie\n");
    // ...and it drops a selection rather than deleting it, leaving the caret
    // after it. VS Code would leave it one earlier, because its selection is
    // one character narrower — the same inclusive-caret divergence, showing
    // through at the other end.
    expect(ctx, "Esc drops the selection, caret after it", try drive(ctx, "vscode", abc, S_RIGHT ++ S_RIGHT ++ ESC ++ "Z\x13"), "alpZha\nbravo\ncharlie\n");

    // --- Ctrl-D: multiple selections ---------------------------------------
    const foo3 = "foo one\nfoo two\nfoo three\n";
    // The first press selects the word; the next adds the following match,
    // and typing replaces every selection at once.
    expect(ctx, "Ctrl-D selects the word", try drive(ctx, "vscode", foo3, "\x04X\x13"), "X one\nfoo two\nfoo three\n");
    expect(ctx, "a second Ctrl-D adds the next match", try drive(ctx, "vscode", foo3, "\x04\x04X\x13"), "X one\nX two\nfoo three\n");
    expect(ctx, "a third takes the one after", try drive(ctx, "vscode", foo3, "\x04\x04\x04X\x13"), "X one\nX two\nX three\n");
    // Typing more than one character keeps every caret in step.
    expect(ctx, "typing continues at every caret", try drive(ctx, "vscode", foo3, "\x04\x04bar\x13"), "bar one\nbar two\nfoo three\n");
    // Backspace over the selections deletes them and nothing else.
    expect(ctx, "backspace deletes each selection", try drive(ctx, "vscode", foo3, "\x04\x04\x7f\x13"), " one\n two\nfoo three\n");
    // Esc collapses back to a single caret, so the next key types once.
    expect(ctx, "Esc collapses to one caret, after the word", try drive(ctx, "vscode", foo3, "\x04\x04" ++ ESC ++ "X\x13"), "fooX one\nfoo two\nfoo three\n");
    // Asking past the last match says so rather than wrapping onto itself.
    expect(ctx, "no more matches leaves it alone", try drive(ctx, "vscode", "foo\nbar\n", "\x04\x04X\x13"), "X\nbar\n");

    // --- the chords that open UI, checked on screen ------------------------
    {
        const dir = try ctx.tempDir();
        const cfg = h.join(ctx, dir, "cfg");
        defer ctx.gpa.free(cfg);
        const f = h.join(ctx, dir, "u.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, cfg, "keymap = vscode\n");
        h.writeFile(ctx.io, f, "findme here\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg, "--lsp", "", "u.txt" },
            .cwd = dir,
            .keymap = null,
        });
        defer s.finish();
        s.drain(700);
        var m = s.mark();
        s.send("\x06"); // Ctrl-F: find
        s.drain(400);
        ctx.check("Ctrl-F opens the search prompt", s.containsPlainSince(ctx.gpa, m, "/"));
        s.send(ESC);
        s.drain(200);
        m = s.mark();
        s.send("\x10"); // Ctrl-P: file picker
        s.drain(600);
        ctx.check("Ctrl-P opens the file picker", s.containsPlainSince(ctx.gpa, m, "u.txt"));
        s.send(ESC);
        s.drain(300);
        m = s.mark();
        s.send("\x02"); // Ctrl-B: sidebar
        s.drain(500);
        ctx.check("Ctrl-B toggles the explorer", s.containsPlainSince(ctx.gpa, m, "EXPLORER"));
        s.send(ESC);
        s.drain(200);
        s.send(":q!" ++ CR);
        s.drain(300);
    }

    // --- the tutor teaches vim, so it brings its own keymap ----------------
    // Under the shipped default `j` would type a letter into lesson 1.
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--tutor", "--lsp", "" },
            .keymap = null,
        });
        defer s.finish();
        s.drain(800);
        ctx.check("--tutor opens in Normal mode whatever the default is", s.containsPlain(ctx.gpa, "NORMAL"));
        // ...and an explicit --keymap still outranks it.
        s.send(":q!" ++ CR);
        s.drain(300);
    }
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--tutor", "--lsp", "" },
            .keymap = "vscode",
        });
        defer s.finish();
        s.drain(800);
        ctx.check("...but --keymap vscode still wins", s.containsPlain(ctx.gpa, "INSERT"));
    }

    // --- what a user gets with no config at all ----------------------------
    // `.keymap = null` passes no config, so this is the shipped default —
    // the one thing in this file that must not be told what to be.
    {
        const dir = try ctx.tempDir();
        const f = h.join(ctx, dir, "d.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, abc);
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "d.txt" },
            .cwd = dir,
            .keymap = null,
        });
        defer s.finish();
        s.drain(600);
        s.send("dd\x13"); // typing, then Ctrl-S — non-modal out of the box
        s.drain(700);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("out of the box the editor is non-modal", std.mem.eql(u8, got, "ddalpha\nbravo\ncharlie\n"));
    }
}
