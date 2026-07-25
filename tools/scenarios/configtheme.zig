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
    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);
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
    try renderedSettings(ctx);

    const dir = try h.tempDir(ctx.gpa);
    defer ctx.gpa.free(dir);
    defer h.removeTree(ctx.gpa, ctx.io, dir);

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
        ctx.check("relative numbers by default", s2.containsPlain(ctx.gpa, "11") and !s2.containsPlain(ctx.gpa, "12"));
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
}
