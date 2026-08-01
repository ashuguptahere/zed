//! The powerline title bar (row 1): EXPLORER segment + buffer tabs sharing
//! the row (regression: the sidebar header used to overdraw the tabs), tab
//! clicks resolving where the tabs are drawn (sidebar left/right/closed),
//! the filename leaving the statusline while the bar is up, reveal-in-
//! explorer on buffer switches, ]b/[b cycling and the Space b buffer menu.
//! Assertions use the harness Screen model: *where* things are, not just
//! whether the bytes occurred somewhere in the stream.

const std = @import("std");
const h = @import("../harness.zig");

// tokyonight values the bar is painted with (theme.zig).
const ACCENT = h.rgb(0x7a, 0xa2, 0xf7); // mode_normal: the active tab
const STATUS_BG = h.rgb(0x16, 0x16, 0x1e); // inactive tabs + filler
const MODE_COMMAND = h.rgb(0xe0, 0xaf, 0x68); // focused EXPLORER segment
const UI_SEL = h.rgb(0x33, 0x46, 0x7c); // picker/sidebar selection
const UI_SEL_DIM = h.rgb(0x24, 0x2e, 0x4d); // mixColor(bg_dark, ui_sel, 50)

/// The final screen for a session's captured output so far.
fn screen(ctx: *h.Ctx, s: *h.Session) !h.Screen {
    var scr = try h.Screen.init(ctx.gpa, 24, 80);
    scr.apply(s.out.items);
    return scr;
}

fn rowHas(ctx: *h.Ctx, scr: *h.Screen, row: usize, needle: []const u8) bool {
    return scr.colOf(ctx.gpa, row, needle) != null;
}

pub fn run(ctx: *h.Ctx) !void {
    // --- the tab close box ---------------------------------------------------
    {
        const dir = try h.tempDir(ctx.gpa);
        defer ctx.gpa.free(dir);
        defer h.removeTree(ctx.gpa, ctx.io, dir);
        const a = h.join(ctx, dir, "aa.txt");
        defer ctx.gpa.free(a);
        const b = h.join(ctx, dir, "bb.txt");
        defer ctx.gpa.free(b);
        h.writeFile(ctx.io, a, "one\n");
        h.writeFile(ctx.io, b, "two\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "aa.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send(":e bb.txt\r");
        s.drain(500);
        ctx.check("every tab carries a close box", s.contains("\u{2715}"));

        // Find the ✕ of the first tab and click it.
        var scr = try h.Screen.init(ctx.gpa, 24, 80);
        defer scr.deinit();
        scr.apply(s.out.items);
        const row1 = try scr.rowText(ctx.gpa, 1);
        defer ctx.gpa.free(row1);
        const cross = std.mem.indexOf(u8, row1, "\u{2715}") orelse {
            ctx.check("a close box is on the tab row", false);
            return;
        };
        // `rowText` is UTF-8; the cross is one cell, so count codepoints up to it.
        var col: usize = 1;
        var bi: usize = 0;
        while (bi < cross) : (col += 1) bi += std.unicode.utf8ByteSequenceLength(row1[bi]) catch 1;
        var click: [32]u8 = undefined;
        const press = try std.fmt.bufPrint(&click, "\x1b[<0;{d};1M", .{col});
        var rel: [32]u8 = undefined;
        const release = try std.fmt.bufPrint(&rel, "\x1b[<0;{d};1m", .{col});
        const m = s.mark();
        s.send(press);
        s.send(release);
        s.drain(700);
        ctx.check("clicking a tab's close box closes that buffer",
            !s.containsPlainSince(ctx.gpa, m, "aa.txt"));
        s.send(":qa!\r");
        s.drain(400);
    }


    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
    const a = h.join(ctx, dir, "a.txt");
    defer ctx.gpa.free(a);
    const b = h.join(ctx, dir, "b.txt");
    defer ctx.gpa.free(b);
    const sub = h.join(ctx, dir, "sub");
    defer ctx.gpa.free(sub);
    const inner = h.join(ctx, dir, "sub/inner.txt");
    defer ctx.gpa.free(inner);
    const cfg = h.join(ctx, dir, "cfg");
    defer ctx.gpa.free(cfg);
    h.writeFile(ctx.io, a, "alpha one\n");
    h.writeFile(ctx.io, b, "bravo one\n");
    std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
    h.writeFile(ctx.io, inner, "inner line\n");

    // ---- the bar itself: tabs, active styling, dirty dot, clicks, sidebar ----
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("single-buffer session shows the title bar", rowHas(ctx, &scr, 1, "a.txt"));
            const status = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(status);
            ctx.check("filename leaves the statusline while the bar is up", std.mem.indexOf(u8, status, "a.txt") == null and
                std.mem.indexOf(u8, status, "NORMAL") != null);
        }

        s.send(":e b.txt\r");
        s.drain(500);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            const ca = scr.colOf(ctx.gpa, 1, "a.txt") orelse 0;
            const cb = scr.colOf(ctx.gpa, 1, "b.txt") orelse 0;
            ctx.check("both tabs on row 1", ca > 0 and cb > ca);
            ctx.check("active tab is the accent segment", scr.at(1, cb).bg == ACCENT);
            ctx.check("inactive tab sits dim on status_bg", scr.at(1, ca).bg == STATUS_BG);
        }

        s.send("x"); // b.txt becomes dirty
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("dirty buffer keeps its dot in the tab", rowHas(ctx, &scr, 1, "b.txt \u{25CF}"));
        }

        // Clicks with no sidebar: tabs start at column 1.
        s.send("\x1b[<0;3;1M"); // first tab = a.txt
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("click switches tabs (sidebar closed)", rowHas(ctx, &scr, 2, "alpha one"));
        }
        s.send("\x1b[<0;12;1M"); // second tab = b.txt (cols 9..18)
        s.drain(400);

        // Open the sidebar: EXPLORER and the tabs must share row 1.
        s.send(" e");
        s.drain(500);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            const ce = scr.colOf(ctx.gpa, 1, "EXPLORER") orelse 0;
            const ca = scr.colOf(ctx.gpa, 1, "a.txt") orelse 0;
            const cb = scr.colOf(ctx.gpa, 1, "b.txt") orelse 0;
            ctx.check("EXPLORER segment on row 1", ce > 0 and ce <= 28);
            ctx.check("tabs drawn beside the header, not overdrawn", ca > 28 and cb > ca);
            ctx.check("focused EXPLORER segment uses the accent", scr.at(1, 2).bg == MODE_COMMAND);
        }

        // A click on the EXPLORER segment is not a tab (it focuses the tree —
        // the sidebar scenario pins that; here: the buffer must not switch).
        s.send("\x1b[<0;2;1M");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("click on EXPLORER does not switch buffers", rowHas(ctx, &scr, 2, "ravo one"));
        }
        // A click on the first drawn tab (past the sidebar) is.
        s.send("\x1b[<0;31;1M");
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("click switches tabs (sidebar left)", rowHas(ctx, &scr, 2, "alpha one"));
        }

        // Reveal in explorer: opening a nested file expands + selects it.
        s.send("\x1b"); // focus stays in the buffer, tree stays open
        s.drain(200);
        s.send(":e sub/inner.txt\r");
        s.drain(500);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            var found_row: usize = 0;
            var found_col: usize = 0;
            var r: usize = 2;
            while (r < 24) : (r += 1) {
                if (scr.colOf(ctx.gpa, r, "inner.txt")) |c| {
                    if (c <= 28) {
                        found_row = r;
                        found_col = c;
                        break;
                    }
                }
            }
            ctx.check("reveal expands the tree to the opened file", found_row != 0);
            ctx.check("revealed row is selected (dim ui_sel)", found_row != 0 and scr.at(found_row, found_col).bg == UI_SEL_DIM);
        }

        s.send(" e"); // the tree is open + unfocused: Space e refocuses it...
        s.drain(300);
        s.send("q"); // ...and q closes it for the cycling checks
        s.drain(300);

        // ]b / [b cycle through buffers; a count skips.
        var m = s.mark();
        s.send("[b"); // inner.txt -> b.txt
        s.drain(400);
        ctx.check("[b cycles to the previous buffer", s.containsPlainSince(ctx.gpa, m, "ravo one"));
        m = s.mark();
        s.send("2]b"); // b.txt +2 -> a.txt (wraps past inner.txt)
        s.drain(400);
        ctx.check("2]b takes the count", s.containsPlainSince(ctx.gpa, m, "alpha one"));

        // Space b: the Buffers which-key group.
        s.send(" ");
        s.drain(300);
        ctx.check("leader menu lists the Buffers group", s.containsPlain(ctx.gpa, "Buffers"));
        s.send("b");
        s.drain(300);
        ctx.check("Space b shows the buffer submenu", s.containsPlain(ctx.gpa, "next buffer") and
            s.containsPlain(ctx.gpa, "previous buffer"));
        m = s.mark();
        s.send("n"); // next buffer: a.txt -> b.txt
        s.drain(400);
        ctx.check("Space b n cycles forward", s.containsPlainSince(ctx.gpa, m, "ravo one"));
        s.send(" bb"); // the picker leaf
        s.drain(400);
        ctx.check("Space b b opens the buffer picker", s.containsPlain(ctx.gpa, "BUFFERS"));
        s.send("\x1b:qa!\r");
        s.drain(200);
    }

    // ---- sidebar = right mirrors the bar ----
    {
        h.writeFile(ctx.io, cfg, "sidebar = right\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "a.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        s.send(":e b.txt\r");
        s.drain(400);
        s.send(" e");
        s.drain(500);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            const ce = scr.colOf(ctx.gpa, 1, "EXPLORER") orelse 0;
            const ca = scr.colOf(ctx.gpa, 1, "a.txt") orelse 0;
            ctx.check("sidebar right: tabs at column 1, EXPLORER at the edge", ca > 0 and ca < 10 and ce > 52);
        }
        s.send("\x1b[<0;60;1M"); // inside the EXPLORER segment: not a tab
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("sidebar right: EXPLORER click switches no buffer", rowHas(ctx, &scr, 2, "bravo one"));
        }
        s.send("\x1b[<0;3;1M"); // first tab
        s.drain(400);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("sidebar right: tab click switches", rowHas(ctx, &scr, 2, "alpha one"));
        }
        s.send(":qa!\r");
        s.drain(200);
    }

    // ---- buffer_tabs = false: no bar, filename back in the statusline ----
    {
        h.writeFile(ctx.io, cfg, "buffer_tabs = false\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "a.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        s.send(":e b.txt\r");
        s.drain(500);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("buffer_tabs=false removes the bar", rowHas(ctx, &scr, 1, "bravo one") and
                !rowHas(ctx, &scr, 1, "a.txt"));
            const status = try scr.rowText(ctx.gpa, 24);
            defer ctx.gpa.free(status);
            ctx.check("buffer_tabs=false restores the statusline filename", std.mem.indexOf(u8, status, "b.txt") != null);
        }
        s.send(":qa!\r");
        s.drain(200);
    }

    // ---- flat mode: the statusline is painted to the last column ----
    // (regression: the width budget counted 1 cell per separator even when
    // nerd_font = false made them empty, leaving 4 stale cells at the edge)
    {
        h.writeFile(ctx.io, cfg, "nerd_font = false\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "a.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("flat statusline reaches the right edge", scr.at(24, 80).bg == ACCENT);
        }
        s.send(":qa!\r");
        s.drain(200);
    }

    // ---- narrow terminal, buffer_tabs = false: the sidebar draws its own
    // header again, which must clip to a sidebar narrower than its label
    // (regression: `emitSpaces(w - 9)` underflowed and panicked at 16 cols) ----
    {
        h.writeFile(ctx.io, cfg, "buffer_tabs = false\n");
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "a.txt" }, .cwd = dir, .term = "xterm-256color", .cols = 16 });
        defer s.finish();
        s.drain(400);
        s.send(" e"); // an 8-col sidebar: narrower than " EXPLORER"
        s.drain(400);
        ctx.check("narrow sidebar header clips, no panic", !s.containsPlain(ctx.gpa, "panic"));
        const m = s.mark();
        s.send("\x1bihi"); // the editor must still be alive and responsive
        s.drain(300);
        ctx.check("editor still responds after the narrow header", s.containsPlainSince(ctx.gpa, m, "hi"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // ---- the picker view keeps the title bar ----
    {
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "a.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s.finish();
        s.drain(500);
        s.send(":e b.txt\r");
        s.drain(400);
        s.send(" ff");
        s.drain(600);
        {
            var scr = try screen(ctx, &s);
            defer scr.deinit();
            ctx.check("picker view keeps the title bar", rowHas(ctx, &scr, 1, "b.txt"));
            // The picker floats, so its title is in the box border somewhere
            // below the bar rather than on row 2 — what matters is that the
            // bar is still there and the picker did not paint over it.
            var title_row: usize = 0;
            var sel_row: usize = 0;
            var sel_col: usize = 0;
            var r: usize = 1;
            while (r <= 24) : (r += 1) {
                if (rowHas(ctx, &scr, r, "FILES")) title_row = r;
                var c: usize = 1;
                while (c <= 80) : (c += 1) {
                    if (scr.at(r, c).cp == 0x25B6 and sel_row == 0) {
                        sel_row = r;
                        sel_col = c;
                    }
                }
            }
            ctx.check("picker prompt moves below the bar", title_row > 1);
            ctx.check("picker selection uses ui_sel", sel_row > 0 and scr.at(sel_row, sel_col).bg == UI_SEL);
        }
        s.send("\x1b:qa!\r");
        s.drain(200);
    }
}
