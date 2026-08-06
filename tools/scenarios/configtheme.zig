//! Config file + themes + tutor: `--config` applies `theme =` / `nerd_font =`,
//! `:theme` switches live, `Space t` opens the theme picker, `--tutor` opens
//! the embedded tutorial, and `:e` detects the new file's language (regression:
//! it used to leave lang = .none, so no highlighting and no LSP for files
//! opened after startup).

const std = @import("std");
const h = @import("../harness.zig");

// bg escapes of the built-in themes (24-bit SGR of each palette's `bg`).
const GRUVBOX_BG = "\x1b[48;2;40;40;40m"; // #282828
const NORD_BG = "\x1b[48;2;46;52;64m"; // #2e3440
const KEYWORD = "\x1b[38;2;187;154;247m"; // tokyonight keyword (purple)
const POWERLINE = "\xee\x82\xb0"; // U+E0B0

/// Settings that only show up in the rendered frame: a tab drawn at its width,
/// the buffer tabline present or gone, and the completion debounce accepted as
/// a number rather than ignored.
fn renderedSettings(ctx: *h.Ctx) !void {
    const dir = try ctx.tempDir();
    const cfg = try std.fmt.allocPrint(ctx.gpa, "{s}/cfg", .{dir});
    defer ctx.gpa.free(cfg);
    const a = try std.fmt.allocPrint(ctx.gpa, "{s}/a.txt", .{dir});
    defer ctx.gpa.free(a);
    const b = try std.fmt.allocPrint(ctx.gpa, "{s}/b.txt", .{dir});
    defer ctx.gpa.free(b);
    h.writeFile(ctx.io, a, "\tX\n"); // one tab, then a marker
    h.writeFile(ctx.io, b, "second\n");

    // tab_width: the marker after a tab moves by exactly the difference in
    // widths. Comparing the two runs rather than one absolute column keeps the
    // gutter's own width out of the assertion.
    var indent: [2]usize = .{ 0, 0 };
    for ([_][]const u8{ "2", "8" }, 0..) |w, i| {
        const text = try std.fmt.allocPrint(ctx.gpa, "tab_width = {s}\n", .{w});
        defer ctx.gpa.free(text);
        h.writeFile(ctx.io, cfg, text);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "a.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(500);
        const plain = try s.plain(ctx.gpa);
        defer ctx.gpa.free(plain);
        const at = std.mem.indexOfScalar(u8, plain, 'X') orelse 0;
        var spaces: usize = 0;
        while (spaces < at and plain[at - 1 - spaces] == ' ') spaces += 1;
        indent[i] = spaces;
        s.send(":q!\r");
        s.drain(200);
    }
    if (indent[1] != indent[0] + 6) std.debug.print("       tab indent {d} vs {d}\n", .{ indent[0], indent[1] });
    ctx.check("tab_width sets how wide a tab renders", indent[0] > 0 and indent[1] == indent[0] + 6);

    // buffer_tabs: two files open, tabline shown by default and gone when off.
    for ([_]struct { text: []const u8, want: bool }{
        .{ .text = "# default\n", .want = true },
        .{ .text = "buffer_tabs = false\n", .want = false },
    }) |case| {
        h.writeFile(ctx.io, cfg, case.text);
        var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "a.txt" }, .cwd = dir });
        defer s.finish();
        s.drain(400);
        s.send(":e b.txt\r");
        s.drain(500);
        const m = s.mark();
        s.send("i \x1b"); // force a redraw so the tabline (or its absence) is current
        s.drain(400);
        const shown = s.containsPlainSince(ctx.gpa, m, "a.txt") and s.containsPlainSince(ctx.gpa, m, "b.txt");
        ctx.check(if (case.want) "buffer tabs are shown by default" else "buffer_tabs = false hides them", shown == case.want);
        s.send(":q!\r:q!\r");
        s.drain(200);
    }

    // completion_delay_ms: a number the editor accepts and keeps working with
    // (the timer itself is covered by the LSP scenario).
    h.writeFile(ctx.io, cfg, "completion_delay_ms = 40\n");
    var s = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "--config", cfg, "a.txt" }, .cwd = dir });
    defer s.finish();
    s.drain(500);
    s.send("ihello\x1b");
    s.drain(400);
    ctx.check("completion_delay_ms is accepted and editing continues", s.containsPlain(ctx.gpa, "hello"));
    s.send(":q!\r");
    s.drain(200);
}

pub fn run(ctx: *h.Ctx) !void {
    // --- the theme picker previews live, restores on cancel, and persists ---
    {
        const dir = try ctx.tempDir();
        const f = h.join(ctx, dir, "t.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "alpha\n");
        const xdg = try std.fmt.allocPrint(ctx.gpa, "XDG_CONFIG_HOME={s}/cfg", .{dir});
        defer ctx.gpa.free(xdg);
        const cfg_file = h.join(ctx, dir, "cfg/zedit/config");
        defer ctx.gpa.free(cfg_file);

        {
            var s = try h.Session.spawn(ctx.gpa, .{
                .argv = &.{ "env", xdg, ctx.zedit, "--lsp", "", "t.txt" },
                .cwd = dir,
                .term = "xterm-256color",
            });
            defer s.finish();
            s.drain(600);
            var m = s.mark();
            s.send(" ft"); // the theme picker
            s.drain(500);
            s.send("\x1b[B"); // move down one: gruvbox
            s.drain(500);
            ctx.check("moving in the theme picker repaints in that theme",
                s.containsSince(m, GRUVBOX_BG));
            // Cancelling puts back what was showing before.
            m = s.mark();
            s.send("\x1b");
            s.drain(500);
            ctx.check("cancelling the picker restores the previous theme",
                !s.containsSince(m, GRUVBOX_BG));
            // Choose it for real this time.
            m = s.mark();
            s.send(" ft");
            s.drain(400);
            s.send("\x1b[B\r");
            s.drain(600);
            ctx.check("choosing a theme says it was saved", s.containsPlainSince(ctx.gpa, m, "saved"));
            s.send(":q!\r");
            s.drain(300);
        }
        const written = h.readFile(ctx.gpa, ctx.io, cfg_file);
        defer ctx.gpa.free(written);
        ctx.check("the choice is written to the config",
            std.mem.indexOf(u8, written, "theme = gruvbox") != null);

        // And a fresh session comes up in it.
        {
            var s = try h.Session.spawn(ctx.gpa, .{
                .argv = &.{ "env", xdg, ctx.zedit, "--lsp", "", "t.txt" },
                .cwd = dir,
                .term = "xterm-256color",
            });
            defer s.finish();
            s.drain(700);
            ctx.check("the theme survives a restart", s.contains(GRUVBOX_BG));
            s.send(":q!\r");
            s.drain(300);
        }
    }


    try renderedSettings(ctx);

    const dir = try ctx.tempDir();

    const cfg_path = try std.fmt.allocPrint(ctx.gpa, "{s}/cfg", .{dir});
    defer ctx.gpa.free(cfg_path);
    const a_path = try std.fmt.allocPrint(ctx.gpa, "{s}/a.txt", .{dir});
    defer ctx.gpa.free(a_path);
    const z_path = try std.fmt.allocPrint(ctx.gpa, "{s}/b.zig", .{dir});
    defer ctx.gpa.free(z_path);
    h.writeFile(ctx.io, a_path, "hello\n");
    h.writeFile(ctx.io, z_path, "const x = 1;\n");

    // theme from the config file, then a live :theme switch.
    {
        h.writeFile(ctx.io, cfg_path, "# test config\ntheme = gruvbox\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg_path, "a.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(500);
        ctx.check("config file sets the theme", s.contains(GRUVBOX_BG));
        s.send(":theme nord\r");
        s.drain(400);
        ctx.check(":theme switches live", s.contains(NORD_BG));
        s.send(":q!\r");
        s.drain(200);
    }

    // Space t opens the theme picker listing the built-ins.
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "a.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(500);
        s.send(" ft");
        s.drain(400);
        ctx.check("theme picker lists themes", s.containsPlain(ctx.gpa, "THEMES") and
            s.containsPlain(ctx.gpa, "catppuccin"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // nerd_font = false renders a statusline without powerline glyphs.
    {
        h.writeFile(ctx.io, cfg_path, "nerd_font = false\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg_path, "a.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(500);
        ctx.check("nerd_font=false drops powerline glyphs", !s.contains(POWERLINE));
        s.send(":q!\r");
        s.drain(200);
    }

    // relative_numbers = false shows absolute numbers everywhere: with 12
    // lines and the cursor on line 1, the last gutter number is 12 (absolute)
    // instead of 11 (relative distance).
    {
        const many = try std.fmt.allocPrint(ctx.gpa, "{s}/many.txt", .{dir});
        defer ctx.gpa.free(many);
        h.writeFile(ctx.io, many, "x\n" ** 12);
        h.writeFile(ctx.io, cfg_path, "relative_numbers = false\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg_path, "many.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(500);
        ctx.check("relative_numbers=false shows absolute numbers", s.containsPlain(ctx.gpa, "12"));
        s.send(":q!\r");
        s.drain(200);

        var s2 = try h.Session.spawn(ctx.gpa, .{ .argv = &.{ ctx.zedit, "many.txt" }, .cwd = dir, .term = "xterm-256color" });
        defer s2.finish();
        s2.drain(500);
        // Match gutter+text ("11 x"), not a bare "11"/"12": the startup status
        // shows the version ("zedit 0.12.0 — …"), whose digits a bare needle
        // would false-match.
        ctx.check("relative numbers by default", s2.containsPlain(ctx.gpa, "11 x") and !s2.containsPlain(ctx.gpa, "12 x"));
        s2.send(":q!\r");
        s2.drain(200);
    }

    // large_file_mb = 0 forces large-file mode: no highlighting, and the
    // statusline explains why.
    {
        h.writeFile(ctx.io, cfg_path, "large_file_mb = 0\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg_path, "b.zig" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(500);
        ctx.check("large-file mode disables highlighting", !s.contains(KEYWORD));
        ctx.check("large-file mode is announced", s.containsPlain(ctx.gpa, "large file"));
        s.send(":q!\r");
        s.drain(200);
    }

    // autoindent = false restores the plain behaviour (new lines at column 0).
    {
        const ind = try std.fmt.allocPrint(ctx.gpa, "{s}/ind.txt", .{dir});
        defer ctx.gpa.free(ind);
        h.writeFile(ctx.io, ind, "    foo\n");
        h.writeFile(ctx.io, cfg_path, "autoindent = false\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg_path, "ind.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(400);
        s.send("obar");
        s.drain(250);
        s.send("\x1b:wq\r");
        s.drain(300);
        const text = h.readFile(ctx.gpa, ctx.io, ind);
        defer ctx.gpa.free(text);
        ctx.check("autoindent = false disables inheritance", std.mem.eql(u8, text, "    foo\nbar\n"));
    }

    // auto_completion = false restores manual completion: typing pops up
    // nothing, but Ctrl-n still requests the list.
    {
        h.writeFile(ctx.io, cfg_path, "auto_completion = false\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg_path, "--lsp", ctx.mock, "b.zig" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(1500);
        s.send("omock");
        s.drain(700);
        ctx.check("auto_completion=false stays quiet while typing", !s.containsPlain(ctx.gpa, "mockComplete"));
        const m = s.mark();
        s.send("\x0e"); // Ctrl-n still works on demand
        s.drain(800);
        ctx.check("manual Ctrl-n still completes", s.containsPlainSince(ctx.gpa, m, "mockComplete"));
        s.send("\x1b:q!\r");
        s.drain(200);
    }

    // inline_diagnostics = false keeps the buffer quiet (the gutter sign and
    // the statusline message still work — those are separate paths).
    {
        h.writeFile(ctx.io, cfg_path, "inline_diagnostics = false\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--config", cfg_path, "--lsp", ctx.mock, "b.zig" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(1500);
        ctx.check("inline_diagnostics=false hides the inline text", !s.containsPlain(ctx.gpa, "mock error"));
        s.send(":q!\r");
        s.drain(200);
    }

    // :e detects the opened file's language (highlighting for the .zig file).
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "a.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(500);
        s.send(":e b.zig\r");
        s.drain(600);
        ctx.check(":e detects the new file's language", s.contains(KEYWORD));
        s.send(":qa\r");
        s.drain(200);
    }

    // --tutor opens the embedded tutorial.
    {
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--tutor" },
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        ctx.check("--tutor opens the tutorial", s.containsPlain(ctx.gpa, "zedit tutor"));
        s.send(":q!\r");
        s.drain(200);
    }

    // The terminal's own window background — the padding outside the character
    // grid, which is the strip along the bottom and right edge of the window.
    // zedit asks what colour it is, paints it in the theme's, and puts the
    // original back on the way out.
    {
        const f = h.join(ctx, dir, "bg.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "alpha\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "bg.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        ctx.check("the background colour is queried at startup", s.contains("\x1b]11;?"));
        // Nothing is set until the terminal answers: one that ignores OSC 11
        // must never be left recoloured.
        ctx.check("nothing is set before the terminal answers", !s.contains("\x1b]11;rgb:"));

        // Answer as a terminal would, in a colour no theme uses so a restore
        // is unambiguous.
        var m = s.mark();
        s.send("\x1b]11;rgb:8080/0000/8080\x1b\\");
        s.drain(500);
        // (That the reply never reaches the *document* is the check below,
        // against the saved file — the output stream carries zedit's own OSC
        // writes, so searching it for the payload proves nothing.)
        ctx.check("the padding is painted in the theme's background",
            s.containsSince(m, "\x1b]11;rgb:1a/1b/26\x1b\\")); // tokyonight #1a1b26

        m = s.mark();
        s.send(":theme gruvbox\r");
        s.drain(500);
        ctx.check("and follows a theme change",
            s.containsSince(m, "\x1b]11;rgb:28/28/28\x1b\\")); // gruvbox #282828

        m = s.mark();
        s.send(":q!\r");
        s.drain(600);
        ctx.check("the terminal's own colour is restored on exit",
            s.containsSince(m, "\x1b]11;rgb:80/00/80\x1b\\"));
    }

    // The reply must never reach the document. Before OSC was decoded, `ESC ]`
    // read as the Escape key and the rest of the report was typed in as text.
    {
        const f = h.join(ctx, dir, "inert.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "alpha\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "inert.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send("i"); // insert mode: any stray byte would land in the buffer
        s.drain(200);
        s.send("\x1b]11;rgb:8080/0000/8080\x1b\\");
        s.drain(300);
        s.send("\x1b]10;rgb:c0c0/c0c0/c0c0\x07"); // an unrelated reply, BEL-terminated
        s.drain(300);
        s.send("X\x1b:wq\r");
        s.drain(600);
        const got = h.readFile(ctx.gpa, ctx.io, f);
        defer ctx.gpa.free(got);
        ctx.check("an OSC reply arriving in insert mode leaves the text alone",
            std.mem.eql(u8, got, "Xalpha\n"));
    }

    // Corner notifications: raised for a thing that just happened, gone on
    // their own, and never at the cost of the idle CPU rule.
    {
        const f = h.join(ctx, dir, "toast.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "alpha\nbeta\n");
        var s = try h.Session.spawn(ctx.gpa, .{
            .argv = &.{ ctx.zedit, "--lsp", "", "toast.txt" },
            .cwd = dir,
            .term = "xterm-256color",
        });
        defer s.finish();
        s.drain(600);
        s.send("\"+yy"); // yank to the clipboard register
        s.drain(500);
        {
            var scr = try h.Screen.init(ctx.gpa, 24, 80);
            defer scr.deinit();
            scr.apply(s.out.items);
            // Top right, under the title bar — not on the statusline, and not
            // over the text's left margin.
            const row = try scr.rowText(ctx.gpa, 2);
            defer ctx.gpa.free(row);
            const at = std.mem.indexOf(u8, row, "copied");
            ctx.check("a clipboard yank raises a toast in the top right",
                at != null and at.? > 40);
        }
        // It goes on its own, with no key pressed: the queue's deadline is
        // what the poll timeout woke for.
        const gone_by = h.nowMs() + 6000;
        var gone = false;
        while (h.nowMs() < gone_by and !gone) {
            s.drain(300);
            var scr = try h.Screen.init(ctx.gpa, 24, 80);
            defer scr.deinit();
            scr.apply(s.out.items);
            const row = try scr.rowText(ctx.gpa, 2);
            defer ctx.gpa.free(row);
            gone = std.mem.indexOf(u8, row, "copied") == null;
        }
        ctx.check("the toast expires by itself, with no keypress", gone);

        // And the editor is back to costing nothing. A toast that left a
        // repeating timer armed would show up here.
        const t0 = try s.cpuTicks(ctx.gpa, ctx.io);
        s.drain(2000);
        const t1 = try s.cpuTicks(ctx.gpa, ctx.io);
        const idle_ms = @as(f64, @floatFromInt(t1 - t0)) /
            @as(f64, @floatFromInt(h.clockTicksPerSec())) * 1000.0;
        ctx.check("an idle editor still burns no CPU after a toast", idle_ms < 20.0);

        s.send(":q!\r");
        s.drain(400);
    }

    // --- the project's own `.zedit`, layered over the user's config -------
    // nvim's `'exrc'` and Focus's project config. Safe to apply unasked here
    // because zedit's config is data, not code — no setting names a program.
    {
        const pdir = try ctx.tempDir();
        const cfg = h.join(ctx, pdir, "user.cfg");
        defer ctx.gpa.free(cfg);
        const proj = h.join(ctx, pdir, ".zedit");
        defer ctx.gpa.free(proj);
        const f = h.join(ctx, pdir, "p.txt");
        defer ctx.gpa.free(f);
        h.writeFile(ctx.io, f, "alpha\n");
        // The user asks for tokyonight; the project asks for gruvbox.
        h.writeFile(ctx.io, cfg, "theme = tokyonight\nrelative_numbers = true\n");
        h.writeFile(ctx.io, proj, "theme = gruvbox\n");
        {
            var s = try h.Session.spawn(ctx.gpa, .{
                .argv = &.{ ctx.zedit, "--config", cfg, "p.txt" },
                .cwd = pdir,
                .term = "xterm-256color",
            });
            defer s.finish();
            s.drainQuiet(1500);
            ctx.check("the project config wins over the user's", s.contains(GRUVBOX_BG));
            ctx.check("...and says where it came from", s.containsPlain(ctx.gpa, "project config:"));
            s.send(":q!\r");
            s.drain(300);
        }
        // It *layers*: the project overrides what it names and leaves the
        // rest of the user's config alone, so a one-line `.zedit` is a
        // one-setting override rather than a replacement.
        {
            const tf = h.join(ctx, pdir, "t.txt");
            defer ctx.gpa.free(tf);
            h.writeFile(ctx.io, tf, "\tX\n");
            h.writeFile(ctx.io, cfg, "theme = gruvbox\ntab_width = 2\n");
            var col: [2]usize = .{ 0, 0 };
            for ([_][]const u8{ "", "tab_width = 8\n" }, 0..) |text, i| {
                if (text.len == 0) {
                    std.Io.Dir.cwd().deleteFile(ctx.io, proj) catch {};
                } else h.writeFile(ctx.io, proj, text);
                var s = try h.Session.spawn(ctx.gpa, .{
                    .argv = &.{ ctx.zedit, "--config", cfg, "t.txt" },
                    .cwd = pdir,
                    .term = "xterm-256color",
                });
                defer s.finish();
                s.drainQuiet(1500);
                var scr = try h.screenOf(ctx, &s, 24, 80);
                defer scr.deinit();
                var r: usize = 1;
                while (r <= 24) : (r += 1) {
                    if (scr.colOf(ctx.gpa, r, "X")) |c| {
                        col[i] = c;
                        break;
                    }
                }
                // The user's theme is untouched either way: the project file
                // never mentions it.
                ctx.check("the user's other settings are untouched", s.contains(GRUVBOX_BG));
                s.send(":q!\r");
                s.drain(300);
            }
            ctx.check("the project overrides only what it names",
                col[0] > 0 and col[1] == col[0] + 6); // tab_width 2 -> 8
        }
        // Found from a subdirectory too — you are rarely at the project root.
        {
            const sub = h.join(ctx, pdir, "src");
            defer ctx.gpa.free(sub);
            std.Io.Dir.cwd().createDirPath(ctx.io, sub) catch {};
            const sf = h.join(ctx, sub, "q.txt");
            defer ctx.gpa.free(sf);
            h.writeFile(ctx.io, sf, "bravo\n");
            // Back to a user config that does *not* ask for gruvbox, so the
            // theme below can only have come from the project file.
            h.writeFile(ctx.io, cfg, "theme = tokyonight\n");
            h.writeFile(ctx.io, proj, "theme = gruvbox\n");
            var s = try h.Session.spawn(ctx.gpa, .{
                .argv = &.{ ctx.zedit, "--config", cfg, "q.txt" },
                .cwd = sub,
                .term = "xterm-256color",
            });
            defer s.finish();
            s.drainQuiet(1500);
            ctx.check("it is found from a subdirectory", s.contains(GRUVBOX_BG));
            s.send(":q!\r");
            s.drain(300);
        }
        // ...but the walk stops at a repository root, so a `.zedit` outside
        // the project never reaches into it.
        {
            const repo = h.join(ctx, pdir, "other");
            defer ctx.gpa.free(repo);
            std.Io.Dir.cwd().createDirPath(ctx.io, repo) catch {};
            const gitdir = h.join(ctx, repo, ".git");
            defer ctx.gpa.free(gitdir);
            std.Io.Dir.cwd().createDirPath(ctx.io, gitdir) catch {};
            const rf = h.join(ctx, repo, "r.txt");
            defer ctx.gpa.free(rf);
            h.writeFile(ctx.io, rf, "charlie\n");
            var s = try h.Session.spawn(ctx.gpa, .{
                .argv = &.{ ctx.zedit, "--config", cfg, "r.txt" },
                .cwd = repo,
                .term = "xterm-256color",
            });
            defer s.finish();
            s.drainQuiet(1500);
            ctx.check("the walk stops at a repository root", !s.contains(GRUVBOX_BG));
            ctx.check("...and nothing claims a project config", !s.containsPlain(ctx.gpa, "project config:"));
            s.send(":q!\r");
            s.drain(300);
        }
    }
}
