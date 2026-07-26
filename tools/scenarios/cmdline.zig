//! Command-line Tab completion (the "wildmenu"): command names, `:e`/`:w`
//! paths (directories complete with a trailing `/` and descend on the next
//! Tab), `:theme` names, the [matches..., original] cycle ring, and hidden
//! files staying hidden. Semantics pinned to real nvim (see the vim_compat
//! history cases for the Up/Down side). Plus the fish-style inline
//! suggestions ("ghost text"): history/command-name completion shown dim
//! after the cursor, accepted with Right/End, never executed unaccepted,
//! hidden while the wildmenu is open, sanitized, and `cmdline_suggestions`
//! turning it off.

const std = @import("std");
const h = @import("../harness.zig");

const TAB = "\t";
const RIGHT = "\x1b[C";
const END = "\x1b[F";
const GRUVBOX_BG = "\x1b[48;2;40;40;40m"; // #282828
const NORD_BG = "\x1b[48;2;46;52;64m"; // #2e3440

pub fn run(ctx: *h.Ctx) !void {
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const alpha = h.join(ctx, dir, "alpha.txt");
    defer ctx.gpa.free(alpha);
    const alpine = h.join(ctx, dir, "alpine.txt");
    defer ctx.gpa.free(alpine);
    const hidden = h.join(ctx, dir, ".hidden.txt");
    defer ctx.gpa.free(hidden);
    const sub = h.join(ctx, dir, "sub");
    defer ctx.gpa.free(sub);
    const inner = h.join(ctx, dir, "sub/inner.txt");
    defer ctx.gpa.free(inner);
    h.writeFile(ctx.io, alpha, "aaa\n");
    h.writeFile(ctx.io, alpine, "ppp\n");
    h.writeFile(ctx.io, hidden, "hhh\n");
    std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
    h.writeFile(ctx.io, inner, "iii\n");

    // Path completion: first Tab takes the first match and shows the menu;
    // the second Tab cycles to the next candidate, Enter opens it.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e alp");
        s.drain(200);
        s.send(TAB);
        s.drain(300);
        ctx.check("wildmenu lists both matches", s.containsPlain(ctx.gpa, "alpha.txt") and
            s.containsPlain(ctx.gpa, "alpine.txt"));
        s.send(TAB); // second candidate: alpine.txt
        s.drain(200);
        s.send("\r");
        s.drain(400);
        s.send("x:w\r"); // edit it to prove the right file opened
        s.drain(300);
        const t = h.readFile(ctx.gpa, ctx.io, alpine);
        defer ctx.gpa.free(t);
        ctx.check("Tab Tab Enter opens the second match", std.mem.eql(u8, t, "pp\n"));
        s.send(":qa\r");
        s.drain(200);
    }

    // Cycling past the last candidate restores the typed text (the nvim ring);
    // executing ":e alp" then opens a NEW empty buffer named "alp", which a
    // write materialises as that file.
    {
        const alp = h.join(ctx, dir, "alp");
        defer ctx.gpa.free(alp);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e alp");
        s.drain(200);
        s.send(TAB ++ TAB ++ TAB); // alpha.txt -> alpine.txt -> back to "alp"
        s.drain(300);
        s.send("\r");
        s.drain(400);
        s.send("iwrapped\x1b:w\r");
        s.drain(300);
        const t = h.readFile(ctx.gpa, ctx.io, alp);
        defer ctx.gpa.free(t);
        ctx.check("cycling wraps back to the typed text", std.mem.eql(u8, t, "wrapped\n"));
        s.send(":qa\r");
        s.drain(200);
    }

    // A unique directory match completes silently with a trailing "/" and the
    // next Tab descends into it; hidden files are never offered.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e su");
        s.drain(200);
        s.send(TAB); // -> :e sub/
        s.drain(250);
        s.send(TAB); // unique content -> :e sub/inner.txt
        s.drain(250);
        s.send("\r");
        s.drain(400);
        s.send("x:w\r");
        s.drain(300);
        const t = h.readFile(ctx.gpa, ctx.io, inner);
        defer ctx.gpa.free(t);
        ctx.check("directory completion descends on next Tab", std.mem.eql(u8, t, "ii\n"));
        ctx.check("hidden files are not offered", !s.containsPlain(ctx.gpa, ".hidden"));
        s.send(":qa\r");
        s.drain(200);
    }

    // Command-name completion: ":form" is not a command, but Tab completes it
    // to ":format", which executes (and reports the missing language server).
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":form" ++ TAB);
        s.drain(250);
        s.send("\r");
        s.drain(400);
        ctx.check("command name completes and executes", s.containsPlain(ctx.gpa, "no language server") and
            !s.containsPlain(ctx.gpa, "unknown command"));
        s.send(":qa\r");
        s.drain(200);
    }

    // --benchmark runs headless and prints the timing report to stdout.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--benchmark", "alpha.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(800);
        ctx.check("--benchmark prints a timing report", s.containsPlain(ctx.gpa, "open") and
            s.containsPlain(ctx.gpa, "serialize") and s.containsPlain(ctx.gpa, "alpha.txt"));
    }

    // Theme-name completion: ":theme gru" Tab -> gruvbox, applied on Enter.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":theme gru" ++ TAB);
        s.drain(250);
        s.send("\r");
        s.drain(400);
        ctx.check(":theme completion applies the theme", s.contains(GRUVBOX_BG));
        s.send(":qa\r");
        s.drain(200);
    }

    // Inline suggestions (fish-style ghost text), core behaviour: the newest
    // history entry extending the typed text shows dim after the cursor,
    // Enter runs ONLY the typed text, Right accepts the ghost.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        // Seed the ex history WITHOUT applying: an Esc-abandoned line is
        // remembered too (vim's rule), so the theme itself never changes.
        s.send(":theme gruvbox\x1b");
        s.drain(200);
        const m1 = s.mark();
        s.send(":th");
        s.drain(250);
        ctx.check("ghost completes from history", s.containsPlainSince(ctx.gpa, m1, "theme gruvbox"));
        s.send("\r"); // must run ONLY ":th" — a ghost can never execute unaccepted
        s.drain(300);
        ctx.check("Enter runs only the typed text", s.containsPlain(ctx.gpa, "unknown command: th") and
            !s.contains(GRUVBOX_BG));
        s.send(":th");
        s.drain(250);
        s.send(RIGHT); // accept the ghost -> ":theme gruvbox"
        s.drain(150);
        s.send("\r");
        s.drain(400);
        ctx.check("Right accepts the ghost, Enter applies it", s.contains(GRUVBOX_BG));
        s.send(":qa\r");
        s.drain(200);
    }

    // End accepts too; with no history the ghost falls back to the first
    // command name; backspace recomputes; the ghost hides while the wildmenu
    // ring holds the line; the search prompt ghosts from the search history.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":theme nord\x1b"); // seed (abandoned, not applied)
        s.drain(200);
        s.send(":th" ++ END ++ "\r");
        s.drain(400);
        ctx.check("End accepts the ghost", s.contains(NORD_BG));
        const m2 = s.mark();
        s.send(":und"); // no matching history -> first command name: undolist
        s.drain(250);
        ctx.check("ghost falls back to a command name", s.containsPlainSince(ctx.gpa, m2, "undolist"));
        s.send("\x1b");
        s.drain(150);
        s.send(":vs"); // -> vsplit
        s.drain(250);
        const m3 = s.mark();
        s.send("\x7f"); // backspace: ":v" -> the suggestion changes to vdiff
        s.drain(250);
        ctx.check("backspace recomputes the ghost", s.containsPlainSince(ctx.gpa, m3, "vdiff"));
        s.send("\x1b");
        s.drain(150);
        // Search prompt: seed the (separate) search history, then ghost it.
        s.send("/zebra42\x1b");
        s.drain(200);
        const m4 = s.mark();
        s.send("/ze");
        s.drain(250);
        ctx.check("search prompt ghosts from search history", s.containsPlainSince(ctx.gpa, m4, "zebra42"));
        s.send("\x1b");
        s.drain(150);
        // Wildmenu hiding: cycling to ":bnext" would ghost " 12345" from the
        // seeded entry — but the ring has the line, so it must stay hidden.
        s.send(":bnext 12345\x1b");
        s.drain(200);
        const m5 = s.mark();
        s.send(":b");
        s.drain(250);
        ctx.check("ghost shows before the wildmenu opens", s.containsPlainSince(ctx.gpa, m5, "bnext 12345"));
        const m6 = s.mark();
        s.send(TAB); // popup: bdelete bnext bprevious buffers; line -> :bdelete
        s.drain(250);
        s.send(TAB); // cycle -> :bnext (history would extend it)
        s.drain(250);
        ctx.check("ghost hidden while the wildmenu is open", !s.containsPlainSince(ctx.gpa, m6, "12345"));
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // cmdline_suggestions = false disables the ghost entirely: nothing is
    // painted and Right accepts nothing.
    {
        const cfg = h.join(ctx, dir, "cfg");
        defer ctx.gpa.free(cfg);
        h.writeFile(ctx.io, cfg, "cmdline_suggestions = false\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":theme gruvbox\x1b");
        s.drain(200);
        const m = s.mark();
        s.send(":th");
        s.drain(250);
        ctx.check("no ghost when cmdline_suggestions = false", !s.containsPlainSince(ctx.gpa, m, "theme gruvbox"));
        s.send(RIGHT ++ "\r"); // Right must accept nothing; Enter runs ":th"
        s.drain(300);
        ctx.check("Right accepts nothing when disabled", s.containsPlainSince(ctx.gpa, m, "unknown command: th") and
            !s.contains(GRUVBOX_BG));
        s.send(":qa\r");
        s.drain(200);
    }

    // Untrusted bytes stay inert: a history entry seeded through a bracketed
    // paste carries a raw ESC + OSC — the ghost must render it as '?', never
    // as a live escape sequence. The paste itself must also recompute the
    // ghost (paste edits the line exactly like typing).
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":");
        s.drain(100);
        s.send("\x1b[200~evil\x1b]0;pwned\x07tail\x1b[201~"); // paste with control bytes
        s.drain(200);
        s.send("\x1b"); // abandon -> remembered in history
        s.drain(150);
        const m1 = s.mark();
        s.send(":ev");
        s.drain(250);
        ctx.check("hostile history ghost renders sanitized", s.containsPlainSince(ctx.gpa, m1, "il?]0;pwned?tail"));
        ctx.check("no raw escape reaches the terminal", !s.contains("\x1b]0;pwned"));
        s.send("\x1b");
        s.drain(150);
        const m2 = s.mark();
        s.send(":");
        s.drain(100);
        s.send("\x1b[200~ev\x1b[201~"); // pasting the prefix must ghost too
        s.drain(250);
        ctx.check("paste recomputes the ghost", s.containsPlainSince(ctx.gpa, m2, "il?]0;pwned?tail"));
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // Width edge cases, on a narrow pty with the Screen model: a ghost longer
    // than the row is clipped to it, and a CJK ghost is clipped on a codepoint
    // boundary (wide chars counted as the 2 cells emitSanitized renders, so
    // the row never overflows and no codepoint is ever torn).
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color", .cols = 30 });
        defer s.finish();
        s.drain(400);
        s.send(":theme gruvbox with a very long tail that cannot fit on thirty columns\x1b");
        s.drain(200);
        s.send(":th");
        s.drain(300);
        var scr = try h.Screen.init(ctx.gpa, 24, 30);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row);
        ctx.check("narrow pty: ghost clipped to the row", std.mem.startsWith(u8, row, ":theme gruvbox") and
            (std.unicode.utf8CountCodepoints(row) catch 999) <= 30);
        s.send("\x1b:qa\r");
        s.drain(200);
    }
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color", .cols = 20 });
        defer s.finish();
        s.drain(400);
        s.send(":");
        s.drain(100);
        s.send("\x1b[200~e 日本語のファイル名がとても長いのです.txt\x1b[201~");
        s.drain(200);
        s.send("\x1b"); // abandon -> history
        s.drain(150);
        s.send(":e");
        s.drain(300);
        var scr = try h.Screen.init(ctx.gpa, 24, 20);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row);
        ctx.check("CJK ghost clips on a codepoint boundary", std.mem.startsWith(u8, row, ":e 日本") and
            std.mem.indexOf(u8, row, "\u{FFFD}") == null);
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // Accepting a search-history ghost is a live edit: searchLive must jump
    // the preview to the completed pattern's match, exactly as typing it
    // would (then Enter commits there — proven by `x` landing on the match).
    {
        const zeb = h.join(ctx, dir, "zeb.txt");
        defer ctx.gpa.free(zeb);
        h.writeFile(ctx.io, zeb, "zebra42 lives here\nsecond line\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "zeb.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send("/zebra42\x1b"); // seed search history (Esc restores the cursor)
        s.drain(200);
        s.send("j"); // move off line 1 so the jump is observable
        s.drain(150);
        s.send("/ze" ++ RIGHT ++ "\r"); // ghost "bra42" accepted, committed
        s.drain(300);
        s.send("x:w\r"); // deletes the 'z' of zebra42 iff the preview jumped
        s.drain(300);
        const got = h.readFile(ctx.gpa, ctx.io, zeb);
        defer ctx.gpa.free(got);
        ctx.check("accepted search ghost drives the live jump", std.mem.startsWith(u8, got, "ebra42"));
        s.send(":qa\r");
        s.drain(200);
    }
}
