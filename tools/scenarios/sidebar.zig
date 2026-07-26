//! File-tree sidebar (Space e) and git diff views (Space g d / g s): the tree
//! renders and opens files, directories expand, explorer mouse clicks act on
//! rows (dir toggles, file opens — VS Code's single-click rule) and focus the
//! tree from its header or the space below it, the sidebar honours the
//! config's `sidebar = right`, and the diff views open highlighted splits.
//! Clicks are sent as press+release pairs, the way real terminals report
//! them: the release must stay inert (no showcmd smear, no pending-state
//! reset — the wheel's choice), boundary rows/columns resolve on both sides
//! at 80 and 16 columns, and clicks during visual mode or an open picker are
//! swallowed. Click assertions use the harness Screen model: *where* things
//! landed and where the cursor is, not just whether bytes occurred in the
//! stream.

const std = @import("std");
const h = @import("../harness.zig");

// tokyonight values (theme.zig) for the Screen-model colour assertions.
const MODE_COMMAND = h.rgb(0xe0, 0xaf, 0x68); // focused EXPLORER header/segment
const UI_SEL = h.rgb(0x33, 0x46, 0x7c); // focused sidebar selection

/// The final screen for a session's captured output so far.
fn screen(ctx: *h.Ctx, s: *h.Session) !h.Screen {
    var scr = try h.Screen.init(ctx.gpa, 24, 80);
    scr.apply(s.out.items);
    return scr;
}

/// Whether `needle` appears on `row` starting within columns [min_col, max_col]
/// — i.e. inside the sidebar's span, not merely somewhere in the row.
fn rowHasAt(ctx: *h.Ctx, scr: *h.Screen, row: usize, needle: []const u8, min_col: usize, max_col: usize) bool {
    const col = scr.colOf(ctx.gpa, row, needle) orelse return false;
    return col >= min_col and col <= max_col;
}

/// Whether `needle` appears inside the given columns on any tree row (2..23).
fn treeHas(ctx: *h.Ctx, scr: *h.Screen, needle: []const u8, min_col: usize, max_col: usize) bool {
    var r: usize = 2;
    while (r < 24) : (r += 1) {
        if (rowHasAt(ctx, scr, r, needle, min_col, max_col)) return true;
    }
    return false;
}

pub fn run(ctx: *h.Ctx) !void {
    // Sidebar: tree renders, navigation opens a file, a directory expands.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "alpha.txt");
        defer ctx.gpa.free(a);
        const sub = h.join(ctx, dir, "subdir");
        defer ctx.gpa.free(sub);
        const inner = h.join(ctx, dir, "subdir/inner.txt");
        defer ctx.gpa.free(inner);
        h.writeFile(ctx.io, a, "aaa\n");
        std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
        h.writeFile(ctx.io, inner, "inner\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(" e"); // open + focus the explorer
        s.drain(400);
        ctx.check("sidebar renders the tree", s.containsPlain(ctx.gpa, "EXPLORER") and
            s.containsPlain(ctx.gpa, "subdir") and s.containsPlain(ctx.gpa, "alpha.txt"));

        s.send("\r"); // Enter on subdir (dirs sort first) expands it
        s.drain(400);
        ctx.check("directory expands inline", s.containsPlain(ctx.gpa, "inner.txt"));

        s.send("j\r"); // down to inner.txt, open it
        s.drain(400);
        s.send("x:w\r"); // inner -> nner
        s.drain(400);
        const it = h.readFile(ctx.gpa, ctx.io, inner);
        defer ctx.gpa.free(it);
        ctx.check("sidebar opens the selected file", std.mem.eql(u8, it, "nner\n"));

        // The leader menu works with the explorer focused, too.
        s.send(" e"); // refocus the tree
        s.drain(300);
        s.send(" ");
        s.drain(300);
        ctx.check("Space opens the leader menu in the explorer", s.containsPlain(ctx.gpa, "Find") and
            s.containsPlain(ctx.gpa, "explorer"));
        s.send("\x1b");
        s.drain(200);

        s.send(" e"); // toggle closed
        s.drain(300);
        s.send(":qa\r");
        s.drain(200);
    }

    // Explorer mouse clicks (sidebar left, 80x24: tree cols 1..28, rows 2..23).
    // Dirs sort first, so screen row 2 = subdir, row 3 = alpha.txt.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "alpha.txt");
        defer ctx.gpa.free(a);
        const sub = h.join(ctx, dir, "subdir");
        defer ctx.gpa.free(sub);
        const inner = h.join(ctx, dir, "subdir/inner.txt");
        defer ctx.gpa.free(inner);
        // 40 numbered lines so the wheel regression has something to scroll.
        var abuf: [400]u8 = undefined;
        var alen: usize = 0;
        var i: usize = 1;
        while (i <= 40) : (i += 1) {
            const part = std.fmt.bufPrint(abuf[alen..], "l{d}\n", .{i}) catch unreachable;
            alen += part.len;
        }
        h.writeFile(ctx.io, a, abuf[0..alen]);
        std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
        h.writeFile(ctx.io, inner, "inner\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "alpha.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(" e\x1b"); // open the explorer, then Esc: open but UNfocused
        s.drain(400);

        // Clicking the EXPLORER title-bar segment focuses the tree. Clicks are
        // sent as press+release pairs, the way a real terminal reports them —
        // the release must stay inert (never showcmd, never pending state).
        s.send("\x1b[<0;5;1M\x1b[<0;5;1m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("header click focuses the explorer", scr.at(1, 2).bg == MODE_COMMAND);
        }
        s.send("\x1b"); // unfocus again: row clicks must not need prior focus
        s.drain(300);

        // A click on a directory row expands it — while the tree is unfocused.
        s.send("\x1b[<0;5;2M\x1b[<0;5;2m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("click on a directory row expands it", rowHasAt(ctx, &scr, 3, "inner.txt", 1, 28));
            ctx.check("row click grabs explorer focus", scr.at(1, 2).bg == MODE_COMMAND);
            // The release used to decode as `unknown` and smear its raw bytes
            // into the showcmd indicator on the statusline.
            ctx.check("click release leaves the statusline clean", scr.colOf(ctx.gpa, 24, "[<0;") == null);
        }

        // The same click again collapses it — at the sidebar's last column
        // (28), the boundary of the hit-test.
        s.send("\x1b[<0;28;2M\x1b[<0;28;2m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("click on the directory again collapses it", !treeHas(ctx, &scr, "inner.txt", 1, 28));
        }

        // One column further (29, the first text column) is not the sidebar.
        s.send("\x1b[<0;29;2M\x1b[<0;29;2m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("border column click stays outside the tree", !treeHas(ctx, &scr, "inner.txt", 1, 28));
        }

        // A click on a file row opens it: expand again, click inner.txt.
        s.send("\x1b[<0;5;2M\x1b[<0;5;2m");
        s.drain(400);
        s.send("\x1b[<0;5;3M\x1b[<0;5;3m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("clicked file gets a tab", rowHasAt(ctx, &scr, 1, "inner.txt", 29, 80));
            ctx.check("clicked file's content shows", rowHasAt(ctx, &scr, 2, "inner", 29, 80));
        }
        s.send("x:w\r"); // proves focus returned to the buffer: x edits the text
        s.drain(400);
        const it = h.readFile(ctx.gpa, ctx.io, inner);
        defer ctx.gpa.free(it);
        ctx.check("file click opens it with focus in the buffer", std.mem.eql(u8, it, "nner\n"));

        // A click below the last row focuses the tree, selection untouched.
        s.send("\x1b[<0;5;10M\x1b[<0;5;10m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            const col = scr.colOf(ctx.gpa, 3, "inner.txt") orelse 0;
            ctx.check("below-tree click focuses the explorer", scr.at(1, 2).bg == MODE_COMMAND);
            ctx.check("below-tree click keeps the selection", col > 0 and scr.at(3, col).bg == UI_SEL);
            ctx.check("below-tree click opens nothing", rowHasAt(ctx, &scr, 2, "nner", 29, 80));
        }
        s.send("\x1b"); // back to the buffer for the regressions below
        s.drain(300);

        // Row 24 is the command line, one past the last tree row (23): a
        // click there must not grab focus.
        s.send("\x1b[<0;5;24M\x1b[<0;5;24m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("command-line row click grabs nothing", scr.at(1, 2).bg != MODE_COMMAND);
        }

        // Regression: a tab click still switches buffers (tabs start past the
        // sidebar at col 29; alpha.txt is the first tab).
        s.send("\x1b[<0;31;1M\x1b[<0;31;1m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("tab click still switches buffers", rowHasAt(ctx, &scr, 2, "l1", 29, 80));
        }

        // Regression: the wheel still scrolls (two notches = six lines).
        s.send("\x1b[<65;45;10M\x1b[<65;45;10M");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("wheel still scrolls the buffer", rowHasAt(ctx, &scr, 2, "l7", 29, 80));
        }

        // Pin: a click in the text area stays ignored — the cursor must not move.
        s.send("5j");
        s.drain(300);
        var before_row: usize = 0;
        var before_col: usize = 0;
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            before_row = scr.cur_row;
            before_col = scr.cur_col;
        }
        s.send("\x1b[<0;45;15M\x1b[<0;45;15m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("text-area click does not move the cursor", scr.cur_row == before_row and scr.cur_col == before_col);
            ctx.check("text-area click changes nothing", rowHasAt(ctx, &scr, 2, "l7", 29, 80));
        }

        // A fast double-click (both pairs in one write) is two toggles: the
        // expanded dir collapses and re-expands, with no state corruption —
        // the next single click still collapses it.
        s.send("\x1b[<0;5;2M\x1b[<0;5;2m\x1b[<0;5;2M\x1b[<0;5;2m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("fast double-click nets two toggles", treeHas(ctx, &scr, "inner.txt", 1, 28));
        }
        s.send("\x1b[<0;5;2M\x1b[<0;5;2m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("single click after the burst still works", !treeHas(ctx, &scr, "inner.txt", 1, 28));
        }
        s.send("\x1b"); // unfocus the tree
        s.drain(300);

        // Visual mode: clicks are ignored wholesale (the wheel scrolls there,
        // but a click must not activate a row under a live selection).
        s.send("v");
        s.drain(300);
        s.send("\x1b[<0;5;2M\x1b[<0;5;2m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("visual mode keeps the selection on a click", scr.colOf(ctx.gpa, 24, "VISUAL") != null);
            ctx.check("visual mode click toggles nothing", !treeHas(ctx, &scr, "inner.txt", 1, 28));
        }
        s.send("\x1b");
        s.drain(300);

        // With a picker open, the picker owns the screen: a click on the tree
        // it shows must be swallowed, exactly like every other picker key.
        s.send(" ff");
        s.drain(400);
        s.send("\x1b[<0;5;2M\x1b[<0;5;2m");
        s.drain(400);
        s.send("\x1b"); // close the picker
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("a click while the picker is open is swallowed", !treeHas(ctx, &scr, "inner.txt", 1, 28));
        }
        s.send(":qa\r");
        s.drain(200);
    }

    // The release side of a click is inert, like the wheel: `d` then a click
    // in the text area must leave the operator pending, so the following `w`
    // still completes `dw` (before the fix the release decoded as `unknown`,
    // cancelled the operator and left `^[[<…m` in the showcmd indicator).
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const b = h.join(ctx, dir, "b.txt");
        defer ctx.gpa.free(b);
        h.writeFile(ctx.io, b, "one two three\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "b.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send("d");
        s.drain(200);
        s.send("\x1b[<0;40;10M\x1b[<0;40;10m"); // text-area click: ignored, inert
        s.drain(300);
        s.send("w");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("click keeps the pending operator (wheel parity)", rowHasAt(ctx, &scr, 2, "two three", 1, 80) and
                scr.colOf(ctx.gpa, 2, "one") == null);
            ctx.check("release bytes never reach showcmd", scr.colOf(ctx.gpa, 24, "[<0;") == null);
        }
        s.send(":q!\r");
        s.drain(200);
    }

    // Clicking a file whose disk entry vanished after the tree was built is
    // `:e`'s new-file rule: an empty buffer, a sane status, no crash.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "a.txt");
        defer ctx.gpa.free(a);
        const gone = h.join(ctx, dir, "gone.txt");
        defer ctx.gpa.free(gone);
        h.writeFile(ctx.io, a, "aaa\n");
        h.writeFile(ctx.io, gone, "bye\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(" e\x1b"); // build the tree, unfocus
        s.drain(400);
        h.removeFile(ctx.io, gone);
        const m = s.mark();
        s.send("\x1b[<0;5;3M\x1b[<0;5;3m"); // row 3 = gone.txt (a.txt sorts first)
        s.drain(400);
        ctx.check("deleted file click opens an empty new buffer", s.containsPlainSince(ctx.gpa, m, "opened gone.txt"));
        s.send("istill alive\x1b"); // the editor took the click in stride
        s.drain(400);
        ctx.check("editor stays usable after the deleted-file click", s.containsPlainSince(ctx.gpa, m, "still alive"));
        s.send(":q!\r:qa\r");
        s.drain(200);
    }

    // A 16-column terminal: the sidebar shrinks to cols/2 = 8, and the click
    // hit-test shrinks with it (shared geometry) — col 8 is still the tree,
    // col 9 is the text area.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "a.txt");
        defer ctx.gpa.free(a);
        const sub = h.join(ctx, dir, "subdir");
        defer ctx.gpa.free(sub);
        const inner = h.join(ctx, dir, "subdir/inner.txt");
        defer ctx.gpa.free(inner);
        h.writeFile(ctx.io, a, "aaa\n");
        std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
        h.writeFile(ctx.io, inner, "inner\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir, .term = "xterm-256color", .cols = 16 });
        defer s.finish();
        s.drain(500);
        s.send(" e\x1b");
        s.drain(400);
        s.send("\x1b[<0;8;2M\x1b[<0;8;2m"); // last sidebar column: the dir row
        s.drain(400);
        {
            var scr = try h.Screen.init(ctx.gpa, 24, 16);
            defer scr.deinit();
            scr.apply(s.out.items);
            ctx.check("16-col terminal: col 8 click expands the dir", rowHasAt(ctx, &scr, 3, "inn", 1, 8));
        }
        s.send("\x1b[<0;9;2M\x1b[<0;9;2m"); // first text column: ignored
        s.drain(400);
        {
            var scr = try h.Screen.init(ctx.gpa, 24, 16);
            defer scr.deinit();
            scr.apply(s.out.items);
            ctx.check("16-col terminal: col 9 click is not the tree", rowHasAt(ctx, &scr, 3, "inn", 1, 8));
        }
        s.send(":qa\r");
        s.drain(200);
    }

    // Explorer clicks honour `sb_scroll`: 30 files, `G` scrolls the tree by 8
    // (22 visible rows), so the row-2 click must resolve to f09, not f01.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        var k: usize = 1;
        while (k <= 30) : (k += 1) {
            var nbuf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&nbuf, "f{d:0>2}.txt", .{k}) catch unreachable;
            const p = h.join(ctx, dir, name);
            defer ctx.gpa.free(p);
            var cbuf: [8]u8 = undefined;
            const cont = std.fmt.bufPrint(&cbuf, "c{d:0>2}\n", .{k}) catch unreachable;
            h.writeFile(ctx.io, p, cont);
        }
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f01.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(" e"); // open + focus
        s.drain(400);
        s.send("G"); // select f30: the next frame scrolls the tree to 8
        s.drain(400);
        const m = s.mark();
        s.send("\x1b[<0;5;2M"); // top visible row = entry 8 + 0 = f09.txt
        s.drain(400);
        ctx.check("scrolled tree resolves clicks through sb_scroll", s.containsPlainSince(ctx.gpa, m, "c09"));
        s.send(":qa\r");
        s.drain(200);
    }

    // Config `sidebar = right` still renders (position is config-driven), and
    // explorer clicks resolve at the mirrored columns (53..80 at 80 wide).
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "a.txt");
        defer ctx.gpa.free(a);
        const sub = h.join(ctx, dir, "subdir");
        defer ctx.gpa.free(sub);
        const inner = h.join(ctx, dir, "subdir/inner.txt");
        defer ctx.gpa.free(inner);
        const cfg = h.join(ctx, dir, "cfg");
        defer ctx.gpa.free(cfg);
        h.writeFile(ctx.io, a, "aaa\n");
        std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
        h.writeFile(ctx.io, inner, "inner\n");
        h.writeFile(ctx.io, cfg, "sidebar = right\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "a.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(400);
        s.send(" e");
        s.drain(400);
        ctx.check("sidebar = right renders the tree", s.containsPlain(ctx.gpa, "EXPLORER"));
        s.send("\x1b[<0;56;2M"); // dir row at the mirrored column
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("sidebar right: dir click expands", rowHasAt(ctx, &scr, 3, "inner.txt", 53, 80));
        }
        s.send("\x1b[<0;56;2M");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("sidebar right: second click collapses", !treeHas(ctx, &scr, "inner.txt", 53, 80));
        }
        // The mirrored boundaries: col 53 is the sidebar's first column and
        // col 80 its last (both act); col 52 is the last text column (inert).
        s.send("\x1b[<0;53;2M\x1b[<0;53;2m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("sidebar right: first-column click acts", treeHas(ctx, &scr, "inner.txt", 53, 80));
        }
        s.send("\x1b[<0;52;2M\x1b[<0;52;2m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("sidebar right: border column click is inert", treeHas(ctx, &scr, "inner.txt", 53, 80));
        }
        s.send("\x1b[<0;80;2M\x1b[<0;80;2m");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("sidebar right: last-column click acts", !treeHas(ctx, &scr, "inner.txt", 53, 80));
        }
        s.send("q:qa\r");
        s.drain(200);
    }

    // Git diff views in a real repo with a working-tree change.
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const f = h.join(ctx, dir, "f.txt");
        defer ctx.gpa.free(f);
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "init", "-q" });
        h.writeFile(ctx.io, f, "alpha\nbeta\ngamma\n");
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "add", "f.txt" });
        h.runQuiet(ctx.gpa, ctx.io, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t.t", "commit", "-q", "-m", "init" });
        h.writeFile(ctx.io, f, "alpha\nBETA\ngamma\nadded\n");

        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "f.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        s.send(" g"); // the Git which-key submenu must render (regression:
        s.drain(300); // .space_git was missing from the render switch)
        ctx.check("Space g shows the Git menu", s.containsPlain(ctx.gpa, "diff (inline)"));
        s.send("d"); // continue into the inline diff
        s.drain(600);
        ctx.check("inline diff shows hunks", s.containsPlain(ctx.gpa, "@@") and
            s.containsPlain(ctx.gpa, "+BETA") and s.containsPlain(ctx.gpa, "[diff] f.txt"));
        // The +/- lines are coloured by the .diff lexer (tokyonight green/red
        // fg set immediately before the line text).
        ctx.check("inline diff colours additions green", s.contains("\x1b[38;2;158;206;106m+BETA"));
        ctx.check("inline diff colours removals red", s.contains("\x1b[38;2;247;118;142m-beta"));

        s.send(":close\r"); // back to just the file
        s.drain(300);
        s.send(" gs"); // side-by-side with the index version
        s.drain(600);
        ctx.check("side-by-side shows the index version", s.containsPlain(ctx.gpa, "beta") and
            s.containsPlain(ctx.gpa, "(index)"));
        // Both panes tint changed/added rows (bg = 25% git colour into the
        // tokyonight background: add 59;71;55, change 75;64;54).
        ctx.check("side-by-side tints added lines", s.contains("\x1b[48;2;59;71;55m"));
        ctx.check("side-by-side tints changed lines", s.contains("\x1b[48;2;75;64;54m"));
        s.send(":qa\r");
        s.drain(200);
    }
}
