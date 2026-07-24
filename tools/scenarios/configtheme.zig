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

pub fn run(ctx: *h.Ctx) !void {
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
        s.send(" t");
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
