//! Command-line Tab completion (the "wildmenu"): command names, `:e`/`:w`
//! paths (directories complete with a trailing `/` and descend on the next
//! Tab), `:theme` names, the [matches..., original] cycle ring, hidden
//! files staying hidden, and the directory-navigation keys while a path
//! popup is open (Down descends into the selected directory, Up re-completes
//! in the parent — nvim 'wildmenu'). Semantics pinned to real nvim (see the
//! vim_compat history and mid-line editing cases for the Up/Down and cursor
//! side). Plus the fish-style inline suggestions ("ghost text"):
//! history/command-name completion shown dim after the cursor, accepted with
//! Right/End only at end-of-line (hidden mid-line, like fish), never executed
//! unaccepted, hidden while the wildmenu is open, sanitized, and
//! `cmdline_suggestions` turning it off. Mid-line editing itself (cursor
//! column, insert-at-cursor, the hardware cursor) is checked here through the
//! Screen model; the nvim-pinned file-effect cases live in vim_compat. Same
//! split for the rest of the vim command-line keys: `Delete`, `Ctrl-w`,
//! `Ctrl-u` and `c_CTRL-R` are pinned to nvim by their file effect there and
//! checked here for what they render (the erase rows, the pending `"`, a
//! register's untrusted bytes going through the sanitizer, the ghost being
//! recomputed) — plus the command line's wrapping when it outgrows the row,
//! which is what nvim does instead of scrolling sideways: the block geometry,
//! the cursor on the wrapped row, the repaint when it shrinks back, and the
//! wildmenu popup moving above it.

const std = @import("std");
const h = @import("../harness.zig");

const TAB = "\t";
const LEFT = "\x1b[D";
const RIGHT = "\x1b[C";
const END = "\x1b[F";
const UP = "\x1b[A";
const DOWN = "\x1b[B";
const DEL = "\x1b[3~";
const BS = "\x7f";
const CTRLW = "\x17";
const CTRLU = "\x15";
const CTRLR = "\x12";
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
    // Two directories sharing the prefix "pa" (so ":e pa" Tab opens a popup
    // with a directory selected), one holding two files (so completion inside
    // it opens a popup too) — for the Down/Up directory-navigation keys.
    const pair = h.join(ctx, dir, "pair");
    defer ctx.gpa.free(pair);
    const park = h.join(ctx, dir, "park");
    defer ctx.gpa.free(park);
    const pone = h.join(ctx, dir, "pair/one.txt");
    defer ctx.gpa.free(pone);
    const ptwo = h.join(ctx, dir, "pair/two.txt");
    defer ctx.gpa.free(ptwo);
    h.writeFile(ctx.io, alpha, "aaa\n");
    h.writeFile(ctx.io, alpine, "ppp\n");
    h.writeFile(ctx.io, hidden, "hhh\n");
    std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
    h.writeFile(ctx.io, inner, "iii\n");
    std.Io.Dir.cwd().createDirPath(ctx.io, pair) catch {};
    std.Io.Dir.cwd().createDirPath(ctx.io, park) catch {};
    h.writeFile(ctx.io, pone, "11\n");
    h.writeFile(ctx.io, ptwo, "22\n");

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

    // Mid-line editing, on screen: typed chars insert at the cursor (not the
    // end), and the hardware cursor sits at prompt + width of the text before
    // it. ":abc" Left Left "X" must render ":aXbc" with the cursor on the 'b'
    // (column 4) — pinned to nvim in vim_compat (nvim#e1..e9); this checks
    // the rendering and cursor placement side through the Screen model.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":abc");
        s.drain(200);
        s.send(LEFT ++ LEFT);
        s.drain(200);
        s.send("X");
        s.drain(250);
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row);
        ctx.check("typing mid-line inserts at the cursor", std.mem.eql(u8, row, ":aXbc"));
        ctx.check("hardware cursor sits at the edit point", scr.cur_row == 24 and scr.cur_col == 4);
        // A bracketed paste inserts at the cursor too, and the cursor lands
        // after the pasted text (here: paste "Y" before the 'b').
        s.send("\x1b[200~Y\x1b[201~");
        s.drain(250);
        var scr2 = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr2.deinit();
        scr2.apply(s.out.items);
        const row2 = try scr2.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row2);
        ctx.check("paste mid-line inserts at the cursor", std.mem.eql(u8, row2, ":aXYbc"));
        ctx.check("cursor follows the pasted text", scr2.cur_row == 24 and scr2.cur_col == 5);
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // The ghost is a fish suggestion: it renders only with the cursor at
    // end-of-line, and mid-line Right MOVES the cursor rather than accepting.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":theme gruvbox\x1b"); // seed history (abandoned, not applied)
        s.drain(200);
        const m1 = s.mark();
        s.send(":th");
        s.drain(250);
        ctx.check("ghost shows at end-of-line", s.containsPlainSince(ctx.gpa, m1, "theme gruvbox"));
        s.send(LEFT); // cursor mid-line: the ghost must vanish from the frame
        s.drain(250);
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row);
        ctx.check("ghost hidden while the cursor is mid-line", std.mem.eql(u8, row, ":th"));
        ctx.check("cursor moved left of the 'h'", scr.cur_row == 24 and scr.cur_col == 3);
        const m2 = s.mark();
        s.send(RIGHT); // moves back to end-of-line — must NOT accept the ghost
        s.drain(250);
        ctx.check("ghost reappears at end-of-line", s.containsPlainSince(ctx.gpa, m2, "eme gruvbox"));
        s.send("\r");
        s.drain(300);
        ctx.check("mid-line Right moves, never accepts", s.containsPlain(ctx.gpa, "unknown command: th") and
            !s.contains(GRUVBOX_BG));
        s.send(":qa\r");
        s.drain(200);
    }

    // Wildmenu directory navigation (nvim 'wildmenu' probes W1/W2/W4/W6):
    // with a path popup open, Down descends into the selected directory and
    // re-completes inside it; Up re-completes in the parent directory.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e pa");
        s.drain(200);
        s.send(TAB); // popup [pair/ park/], line ":e pair/"
        s.drain(250);
        const m1 = s.mark();
        s.send(DOWN); // descend: popup [one.txt two.txt], line ":e pair/one.txt"
        s.drain(300);
        ctx.check("Down descends into the selected directory", s.containsPlainSince(ctx.gpa, m1, "pair/one.txt"));
        s.send(TAB); // the re-completed ring keeps cycling inside pair/
        s.drain(250);
        ctx.check("Tab cycles inside the descended directory", s.containsPlainSince(ctx.gpa, m1, "pair/two.txt"));
        s.send("\x1b[Z"); // Shift-Tab back to one.txt
        s.drain(250);
        s.send("\r");
        s.drain(400);
        s.send("x:w\r"); // prove the descended-to file really opened
        s.drain(300);
        const t = h.readFile(ctx.gpa, ctx.io, pone);
        defer ctx.gpa.free(t);
        ctx.check("Enter opens the descended-to file", std.mem.eql(u8, t, "1\n"));
        s.send(":e pair/");
        s.drain(200);
        s.send(TAB); // popup [one.txt two.txt] inside pair/
        s.drain(250);
        const m2 = s.mark();
        s.send(UP); // parent: re-completes in the temp dir — park/ appears
        s.drain(300);
        ctx.check("Up re-completes in the parent directory", s.containsPlainSince(ctx.gpa, m2, "park/"));
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // Up at the filesystem root: "/" is its own parent, so the popup simply
    // re-completes there — the line stays rooted, nothing crashes or climbs
    // out of the filesystem. (Entry names vary per machine; assert the stem.)
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e /");
        s.drain(200);
        s.send(TAB); // popup listing "/"
        s.drain(300);
        s.send(UP); // parent of "/" is "/"
        s.drain(300);
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row);
        ctx.check("Up at the root stays at the root", std.mem.startsWith(u8, row, ":e /"));
        ctx.check("still a completed entry on the line", row.len > ":e /".len);
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // History recall must keep working when no popup is open (the directory
    // keys are gated on the popup, exactly nvim's rule).
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":theme gruvbox\x1b"); // seed (abandoned, not applied)
        s.drain(200);
        const m = s.mark();
        s.send(":" ++ UP); // no popup: Up is plain history recall
        s.drain(250);
        ctx.check("Up without a popup recalls history", s.containsPlainSince(ctx.gpa, m, "theme gruvbox"));
        s.send("\r");
        s.drain(400);
        ctx.check("recalled line executes", s.contains(GRUVBOX_BG));
        s.send(":qa\r");
        s.drain(200);
    }

    // Each row of the line is filled by display cells, not bytes: on a
    // 20-column pty nine wide chars (18 cells) follow the prompt, the tenth
    // (2 cells into 1) starts the next row instead, and vim marks the cell it
    // left over with '>'. Probe (real nvim, 20 columns, tmux pty):
    //   ":日本語のファイル名がとても長い" painted ':日本語のファイル名>'
    //   then 'がとても長い', cursor x=12 — and ":012345678901234567日本"
    //   painted ':012345678901234567>' then '日本'. A row that ends exactly
    //   full gets no marker (probes H1/H6).
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color", .cols = 20 });
        defer s.finish();
        s.drain(400);
        const m = s.mark();
        s.send(":日本語のファイル名がとても長い");
        s.drain(400);
        ctx.check("a wide char that did not fit leaves vim's '>' marker", s.containsPlainSince(ctx.gpa, m, ":日本語のファイル名>"));
        ctx.check("…and starts the next row", s.containsPlainSince(ctx.gpa, m, "がとても長い"));
        ctx.check("no codepoint torn by the clip", !s.containsPlainSince(ctx.gpa, m, "?"));
        // A row filled exactly is not marked.
        s.send("\x1b");
        s.drain(200);
        const m2 = s.mark();
        s.send(":0123456789012345678901234");
        s.drain(400);
        ctx.check("an exactly-full row gets no marker", s.containsPlainSince(ctx.gpa, m2, ":0123456789012345678"));
        ctx.check("…not even a stray one", !s.containsPlainSince(ctx.gpa, m2, ">"));
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // A terminal narrower than a wide character: no screen row can hold it,
    // so a layout that only ever takes what *fits* consumes nothing and the
    // row loop never advances. Measured with that layout: the editor spun at
    // 100% CPU, drew nothing more and never saw `:q!` again. It must lay the
    // line out, go back to sleep, and still answer keys.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color", .cols = 1 });
        defer s.finish();
        s.drain(400);
        const m = s.mark();
        s.send(":日本");
        s.drain(400);
        ctx.check("a wide char on a one-column terminal still draws", s.out.items.len > m);
        const t0 = try s.cpuTicks(ctx.gpa, ctx.io);
        s.drain(1500);
        const t1 = try s.cpuTicks(ctx.gpa, ctx.io);
        const busy_ms = @as(f64, @floatFromInt(t1 - t0)) /
            @as(f64, @floatFromInt(h.clockTicksPerSec())) * 1000.0;
        ctx.check("…and does not spin (idle CPU stays negligible)", busy_ms < 50.0);
        const m2 = s.mark();
        s.send("\x1b");
        s.drain(400);
        ctx.check("…and still answers keys", s.out.items.len > m2);
        s.send(":qa!\r");
        s.drain(300);
    }

    // Mid-line editing across wide chars: Left from the end of ":日本語"
    // steps over 語 (one codepoint, never a byte), backspace deletes the
    // whole 本, and the hardware cursor lands after the 2-cell 日.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":日本語");
        s.drain(250);
        s.send(LEFT);
        s.drain(150);
        s.send("\x7f"); // backspace: delete the codepoint before the cursor (本)
        s.drain(250);
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        // The Screen model advances one column per codepoint (it does not
        // model wide cells), so assert the prefix rather than the whole row.
        const row = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row);
        ctx.check("backspace mid-CJK deletes one whole codepoint", std.mem.startsWith(u8, row, ":日語 ") and std.mem.indexOf(u8, row, "本") == null);
        ctx.check("no torn codepoint after mid-CJK edits", std.mem.indexOfScalar(u8, row, '?') == null);
        ctx.check("cursor sits after the 2-cell 日", scr.cur_row == 24 and scr.cur_col == 4);
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // A line wider than the row wraps onto further screen rows, the
    // command-line area growing upward over the window — nvim's behaviour, not
    // a horizontal scroll. Probe (real nvim, 20 columns, tmux pty):
    //   ":0123456789012345678901234" painted
    //      row 23 ':0123456789012345678'
    //      row 24 '901234'
    //   with the cursor at x=6,y=23 (0-based) = row 24, column 7.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color", .cols = 20 });
        defer s.finish();
        s.drain(400);
        s.send(":0123456789012345678901234"); // prompt + 25 chars > 20 cols
        s.drain(300);
        var scr = try h.Screen.init(ctx.gpa, 24, 20);
        defer scr.deinit();
        scr.apply(s.out.items);
        const top = try scr.rowText(ctx.gpa, 23);
        defer ctx.gpa.free(top);
        const bot = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(bot);
        ctx.check("a long line wraps onto the row above", std.mem.eql(u8, top, ":0123456789012345678"));
        ctx.check("…and continues on the last row", std.mem.eql(u8, bot, "901234"));
        ctx.check("the cursor follows onto the wrapped row", scr.cur_row == 24 and scr.cur_col == 7);
        // Home puts the cursor back on the first cell of the block's top row.
        s.send("\x1b[H");
        s.drain(250);
        var scr2 = try h.Screen.init(ctx.gpa, 24, 20);
        defer scr2.deinit();
        scr2.apply(s.out.items);
        ctx.check("Home returns to the start of the block", scr2.cur_row == 23 and scr2.cur_col == 2);
        // Shrinking back under one row must repaint the window row the block
        // covered — the overlay bookkeeping, not the frame diff.
        s.send(END ++ BS ++ BS ++ BS ++ BS ++ BS ++ BS ++ BS ++ BS ++ BS ++ BS);
        s.drain(350);
        var scr3 = try h.Screen.init(ctx.gpa, 24, 20);
        defer scr3.deinit();
        scr3.apply(s.out.items);
        const above = try scr3.rowText(ctx.gpa, 23);
        defer ctx.gpa.free(above);
        const line = try scr3.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(line);
        ctx.check("the block shrinks back to one row", std.mem.eql(u8, line, ":012345678901234"));
        ctx.check("the window row it covered is repainted", std.mem.eql(u8, above, "~"));
        ctx.check("the cursor comes back with it", scr3.cur_row == 24 and scr3.cur_col == 17);
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // The wildmenu popup sits above the command line — which is two rows here,
    // so the popup must move up with it rather than paint over the wrap.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color", .cols = 20 });
        defer s.finish();
        s.drain(400);
        s.send(":e paXXXXXXXXXXXXXXXXXXX"); // 24 chars: wraps at 20 columns
        s.drain(250);
        s.send(LEFT ** 19); // back to just after "pa"
        s.drain(250);
        s.send(TAB);
        s.drain(350);
        var scr = try h.Screen.init(ctx.gpa, 24, 20);
        defer scr.deinit();
        scr.apply(s.out.items);
        const r22 = try scr.rowText(ctx.gpa, 22);
        defer ctx.gpa.free(r22);
        const r23 = try scr.rowText(ctx.gpa, 23);
        defer ctx.gpa.free(r23);
        ctx.check("the popup sits above the wrapped line", std.mem.indexOf(u8, r22, "park/") != null);
        ctx.check("the wrapped line keeps its top row", std.mem.startsWith(u8, r23, ":e pair/"));
        s.send("\x1b\x1b:qa\r");
        s.drain(300);
    }

    // The ghost is painted after the cursor — on the cursor's row when the
    // line wraps, never back on the first one.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color", .cols = 20 });
        defer s.finish();
        s.drain(400);
        s.send(":0123456789012345678901234\x1b"); // seed (abandoned, not run)
        s.drain(250);
        s.send(":01234567890123456789"); // 21 cells: one char onto the second row
        s.drain(350);
        var scr = try h.Screen.init(ctx.gpa, 24, 20);
        defer scr.deinit();
        scr.apply(s.out.items);
        const bot = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(bot);
        ctx.check("the ghost continues on the cursor's row", std.mem.eql(u8, bot, "901234"));
        ctx.check("the cursor stays before the ghost", scr.cur_row == 24 and scr.cur_col == 2);
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // Delete, c_CTRL-W and c_CTRL-U on screen (their file effects are pinned
    // to nvim in vim_compat; this is the rendered row and the hardware
    // cursor). Probes, real nvim through a tmux pty, cmdline row read back:
    //   ":foo bar" + Ctrl-W  -> ':foo'  cursor x=5   (the trailing space stays)
    //   ":foo.bar" + Ctrl-W  -> ':foo.' cursor x=5
    //   ":foo..."  + Ctrl-W  -> ':foo'  cursor x=4
    //   ":abcdef" + 3 Lefts + Ctrl-U -> ':def' cursor x=1
    //   ":s/a/XY"  + Del     -> ':s/a/X'
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        const Row = struct {
            fn check(c: *h.Ctx, sess: *h.Session, name: []const u8, want: []const u8, col: usize) void {
                var scr = h.Screen.init(c.gpa, 24, 80) catch return;
                defer scr.deinit();
                scr.apply(sess.out.items);
                const row = scr.rowText(c.gpa, 24) catch return;
                defer c.gpa.free(row);
                c.check(name, std.mem.eql(u8, row, want) and scr.cur_row == 24 and scr.cur_col == col);
            }
        };
        s.send(":foo bar" ++ CTRLW);
        s.drain(300);
        Row.check(ctx, &s, "Ctrl-W erases the word, keeping the space", ":foo", 6);
        s.send("\x1b:foo.bar" ++ CTRLW);
        s.drain(300);
        Row.check(ctx, &s, "Ctrl-W stops at the punctuation", ":foo.", 6);
        // A prefix of its own: ":foo…" is already in this session's history,
        // which would ghost the row after the erase.
        s.send("\x1b:qux..." ++ CTRLW);
        s.drain(300);
        Row.check(ctx, &s, "Ctrl-W takes a punctuation run whole", ":qux", 5);
        s.send("\x1b:abcdef" ++ LEFT ++ LEFT ++ LEFT ++ CTRLU);
        s.drain(300);
        Row.check(ctx, &s, "Ctrl-U erases to the start, keeping the tail", ":def", 2);
        s.send("\x1b:s/a/XY" ++ DEL);
        s.drain(300);
        Row.check(ctx, &s, "Delete at end-of-line takes the char before", ":s/a/X", 7);
        s.send(LEFT ++ LEFT ++ DEL);
        s.drain(300);
        Row.check(ctx, &s, "Delete mid-line takes the char under the cursor", ":s/aX", 5);
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // Tab mid-line, rendered: the completion replaces only the text before the
    // cursor, the tail is kept and the cursor lands between them. Probes (real
    // nvim, 'wildmenu wildmode=full'): ":e alXY" + 2 Lefts + Tab left
    // ':e alpha.txtXY' with the cursor at x=12; a second Tab
    // ':e alpine.txtXY' x=13; a third restored ':e alXY' x=5. ("pa" here —
    // "pair/" and "park/" — because an earlier case in this file leaves a
    // third "al" candidate in the directory.)
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e paXY" ++ LEFT ++ LEFT ++ TAB);
        s.drain(350);
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row);
        ctx.check("Tab completes before the cursor and keeps the tail", std.mem.eql(u8, row, ":e pair/XY"));
        ctx.check("the cursor sits between them", scr.cur_row == 24 and scr.cur_col == 9);
        s.send(TAB);
        s.drain(300);
        var scr2 = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr2.deinit();
        scr2.apply(s.out.items);
        const row2 = try scr2.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row2);
        ctx.check("cycling keeps the tail too", std.mem.eql(u8, row2, ":e park/XY"));
        s.send(TAB); // past the last match: back to the typed stem
        s.drain(300);
        var scr3 = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr3.deinit();
        scr3.apply(s.out.items);
        const row3 = try scr3.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row3);
        ctx.check("the restored stem keeps the tail", std.mem.eql(u8, row3, ":e paXY"));
        ctx.check("…with the cursor back before it", scr3.cur_row == 24 and scr3.cur_col == 6);
        // Down descends into the selected directory with the tail intact.
        s.send("\x1b:e paXY" ++ LEFT ++ LEFT ++ TAB);
        s.drain(350);
        s.send(DOWN);
        s.drain(350);
        var scr4 = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr4.deinit();
        scr4.apply(s.out.items);
        const row4 = try scr4.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row4);
        ctx.check("directory navigation keeps the tail", std.mem.eql(u8, row4, ":e pair/one.txtXY"));
        s.send("\x1b\x1b:qa\r");
        s.drain(300);
    }

    // c_CTRL-R: the pending prompt, register text going through the render
    // sanitizer, and the newline rules. nvim probes: ":abc" + Ctrl-R rendered
    // ':abc"' with the cursor on the quote (x=4); Esc there kept the line
    // (':abcq' after typing q); a two-line register inserted
    // ':xhello world^Msecond line' — the interior newline shown, the trailing
    // one dropped. zedit renders that CR as '?' like any control byte.
    {
        const reg = h.join(ctx, dir, "reg.txt");
        defer ctx.gpa.free(reg);
        h.writeFile(ctx.io, reg, "heme\none\ntwo\nevil\x1b]0;pwned\x07tail\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "reg.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":abc" ++ CTRLR);
        s.drain(300);
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row);
        ctx.check("a pending Ctrl-R shows a quote at the cursor", std.mem.eql(u8, row, ":abc\""));
        ctx.check("…with the cursor on it", scr.cur_row == 24 and scr.cur_col == 5);
        s.send("\x1b" ++ "q"); // Esc abandons the register prompt, not the line
        s.drain(300);
        var scr2 = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr2.deinit();
        scr2.apply(s.out.items);
        const row2 = try scr2.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row2);
        ctx.check("Esc at the register prompt keeps the line", std.mem.eql(u8, row2, ":abcq"));
        // A two-line register: the interior newline renders, the trailing one
        // is dropped.
        s.send("\x1b" ++ "2G\"a2yy"); // register a = "one\ntwo\n"
        s.drain(300);
        s.send(":x" ++ CTRLR ++ "a");
        s.drain(300);
        var scr3 = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr3.deinit();
        scr3.apply(s.out.items);
        const row3 = try scr3.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row3);
        ctx.check("a multi-line register inserts one separator, no trailing one", std.mem.eql(u8, row3, ":xone?two"));
        // The clipboard register works the same (its shadow copy — the OSC 52
        // write goes out to the terminal, and comes back from nowhere).
        s.send("\x1b" ++ "gg\"+yiw");
        s.drain(300);
        const mc = s.mark();
        s.send(":x" ++ CTRLR ++ "+");
        s.drain(300);
        ctx.check("Ctrl-R + inserts the clipboard register", s.containsPlainSince(ctx.gpa, mc, ":xheme"));
        // Register text is untrusted: an escape sequence in it must render as
        // '?' and never reach the terminal live.
        s.send("\x1b");
        s.drain(150);
        const m = s.mark();
        s.send("\x1b" ++ "4G\"byy" ++ ":" ++ CTRLR ++ "b");
        s.drain(350);
        ctx.check("register text renders sanitized", s.containsPlainSince(ctx.gpa, m, ":evil?]0;pwned?tail"));
        ctx.check("no raw escape reaches the terminal", !s.contains("\x1b]0;pwned"));
        // An edit through Ctrl-R recomputes the inline suggestion, exactly as
        // typing would: register a = "heme" turns ":t" into ":theme", which the
        // seeded history then completes.
        s.send("\x1b" ++ ":theme gruvbox\x1b"); // seed (abandoned, not applied)
        s.drain(300);
        s.send("gg\"cyiw"); // register c = "heme"
        s.drain(300);
        const m2 = s.mark();
        s.send(":t" ++ CTRLR ++ "c");
        s.drain(350);
        ctx.check("Ctrl-R recomputes the ghost", s.containsPlainSince(ctx.gpa, m2, "theme gruvbox"));
        // …and so does Delete. (Its own seed: the ":theme…" lines above are in
        // this session's history, and the newest match is the one that ghosts.)
        s.send("\x1b" ++ ":vsplit zzz9\x1b");
        s.drain(300);
        s.send(":vspQ");
        s.drain(300);
        const m3 = s.mark();
        s.send(DEL); // at end-of-line: takes the 'Q', so ":vsp" ghosts again
        s.drain(350);
        ctx.check("Delete recomputes the ghost", s.containsPlainSince(ctx.gpa, m3, "vsplit zzz9"));
        s.send("\x1b:qa!\r");
        s.drain(300);
    }

    // While a popup is open, Left/Right select the previous/next match
    // (nvim probes W3a-W3d): from ":e pair/" Right selects ":e park/",
    // Left comes back.
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(":e pa");
        s.drain(200);
        s.send(TAB); // popup [pair/ park/], line ":e pair/"
        s.drain(250);
        s.send(RIGHT);
        s.drain(250);
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row = try scr.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row);
        ctx.check("Right selects the next match", std.mem.eql(u8, row, ":e park/"));
        s.send(LEFT);
        s.drain(250);
        var scr2 = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr2.deinit();
        scr2.apply(s.out.items);
        const row2 = try scr2.rowText(ctx.gpa, 24);
        defer ctx.gpa.free(row2);
        ctx.check("Left selects the previous match", std.mem.eql(u8, row2, ":e pair/"));
        s.send("\x1b:qa\r");
        s.drain(200);
    }

    // Popup rows clip by display cells too: a CJK filename wider than the
    // popup on a narrow pty must never be torn mid-codepoint into '?' (the
    // same clipCells rule as the cmdline row).
    {
        const cjkd = h.join(ctx, dir, "cjkd");
        defer ctx.gpa.free(cjkd);
        std.Io.Dir.cwd().createDirPath(ctx.io, cjkd) catch {};
        const ca = h.join(ctx, dir, "cjkd/a.txt");
        defer ctx.gpa.free(ca);
        const c1 = h.join(ctx, dir, "cjkd/日本語のとても長い名前.txt");
        defer ctx.gpa.free(c1);
        const c2 = h.join(ctx, dir, "cjkd/日本語のとても長い別名.txt");
        defer ctx.gpa.free(c2);
        h.writeFile(ctx.io, ca, "a\n");
        h.writeFile(ctx.io, c1, "1\n");
        h.writeFile(ctx.io, c2, "2\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = cjkd, .term = "xterm-256color", .cols = 20 });
        defer s.finish();
        s.drain(400);
        s.send(":e ");
        s.drain(200);
        const m = s.mark();
        s.send(TAB); // popup [a.txt 日本語… 日本語…], rows clipped to the pty
        s.drain(300);
        ctx.check("popup shows the clipped CJK names", s.containsPlainSince(ctx.gpa, m, "日本語"));
        ctx.check("popup never tears a codepoint", !s.containsPlainSince(ctx.gpa, m, "?"));
        s.send("\x1b\x1b:qa\r");
        s.drain(200);
    }
}
