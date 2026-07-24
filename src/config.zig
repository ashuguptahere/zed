//! Runtime configuration from a single documented file.
//!
//! The file lives at `$XDG_CONFIG_HOME/zedit/config` (falling back to
//! `~/.config/zedit/config`) and can be overridden with `--config <path>`.
//! Format: one `key = value` per line, `#` starts a comment, blank lines and
//! unknown keys are ignored (so configs stay forward/backward compatible).
//! `zedit --init-config` writes `default_text` — the fully documented default —
//! to the standard path. Parsed once at startup; no file watching.

const std = @import("std");
const theme = @import("theme.zig");

pub const Side = enum { left, right };

pub const Settings = struct {
    /// Cells a tab character occupies (rendering only; tabs are stored verbatim).
    tab_width: usize = 4,
    /// Use Nerd Font glyphs (powerline statusline separators). Set false if
    /// your terminal font shows boxes/question marks in the statusline.
    nerd_font: bool = true,
    /// Which side the file-tree sidebar (`Space e`) opens on.
    sidebar: Side = .left,
    /// Relative line numbers in the gutter (the cursor line stays absolute,
    /// AstroNvim's hybrid style). False shows absolute numbers everywhere.
    relative_numbers: bool = true,
    /// Files larger than this many megabytes open in large-file mode: syntax
    /// highlighting, LSP and git signs are skipped so the file opens instantly
    /// and nothing chokes on it. 0 treats every file as large.
    large_file_mb: usize = 64,
};

/// The live settings, read by the editor/renderer. Defaults apply when there
/// is no config file.
pub var settings: Settings = .{};

/// The documented default configuration, written by `zedit --init-config`.
pub const default_text =
    \\# zedit configuration
    \\# Location: ~/.config/zedit/config  (or $XDG_CONFIG_HOME/zedit/config)
    \\# One `key = value` per line; `#` starts a comment. Unknown keys are
    \\# ignored, so it is safe to keep settings for newer/older versions here.
    \\
    \\# Colour theme. Built-in themes:
    \\#   tokyonight   (default)
    \\#   gruvbox
    \\#   catppuccin
    \\#   nord
    \\#   onedark
    \\# Switch at runtime with `:theme <name>` or the `Space f t` picker.
    \\theme = tokyonight
    \\
    \\# How many cells a tab character occupies (1-16). Tabs are stored
    \\# verbatim in the file; this affects rendering only.
    \\tab_width = 4
    \\
    \\# Nerd Font glyphs. zedit's powerline statusline separators are private-use
    \\# glyphs that only patched "Nerd Fonts" contain. If your terminal font is
    \\# not a Nerd Font they render as boxes — set this to false for a flat
    \\# statusline that works with any font.
    \\nerd_font = true
    \\
    \\# Which side the file-tree sidebar (Space e) opens on: left or right.
    \\sidebar = left
    \\
    \\# Relative line numbers in the gutter (the cursor line stays absolute).
    \\# Set to false for absolute numbers everywhere.
    \\relative_numbers = true
    \\
    \\# Files larger than this many megabytes open in large-file mode:
    \\# highlighting, LSP and git signs are skipped so huge files open
    \\# instantly and nothing chokes on them.
    \\large_file_mb = 64
    \\
;

/// Apply `key = value` lines to the live settings. Forgiving by design:
/// malformed lines and unknown keys/values are skipped, never fatal.
pub fn apply(text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (std.mem.indexOfScalar(u8, line, '#')) |c| line = line[0..c];
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (key.len == 0 or value.len == 0) continue;

        if (std.mem.eql(u8, key, "theme")) {
            _ = theme.set(value); // unknown theme names keep the current one
        } else if (std.mem.eql(u8, key, "tab_width")) {
            const n = std.fmt.parseInt(usize, value, 10) catch continue;
            if (n >= 1 and n <= 16) settings.tab_width = n;
        } else if (std.mem.eql(u8, key, "nerd_font")) {
            if (std.mem.eql(u8, value, "true")) settings.nerd_font = true;
            if (std.mem.eql(u8, value, "false")) settings.nerd_font = false;
        } else if (std.mem.eql(u8, key, "sidebar")) {
            if (std.mem.eql(u8, value, "left")) settings.sidebar = .left;
            if (std.mem.eql(u8, value, "right")) settings.sidebar = .right;
        } else if (std.mem.eql(u8, key, "relative_numbers")) {
            if (std.mem.eql(u8, value, "true")) settings.relative_numbers = true;
            if (std.mem.eql(u8, value, "false")) settings.relative_numbers = false;
        } else if (std.mem.eql(u8, key, "large_file_mb")) {
            const n = std.fmt.parseInt(usize, value, 10) catch continue;
            settings.large_file_mb = n;
        }
    }
}

/// The standard config path, built into `buf`: $XDG_CONFIG_HOME/zedit/config or
/// ~/.config/zedit/config. Null when neither env var exists. (libc getenv — the
/// editor links libc for tree-sitter anyway.)
pub fn standardPath(buf: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg_z| {
        const xdg = std.mem.sliceTo(xdg_z, 0);
        if (xdg.len > 0)
            return std.fmt.bufPrint(buf, "{s}/zedit/config", .{xdg}) catch null;
    }
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.sliceTo(home_z, 0);
    return std.fmt.bufPrint(buf, "{s}/.config/zedit/config", .{home}) catch null;
}

/// Load the config file (from `override` if given, else the standard path) and
/// apply it. Best-effort: a missing or unreadable file just means defaults.
pub fn load(gpa: std.mem.Allocator, io: std.Io, override: ?[]const u8) void {
    var pbuf: [512]u8 = undefined;
    const path = override orelse (standardPath(&pbuf) orelse return);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return;
    defer gpa.free(text);
    apply(text);
}

/// Write the documented default config to the standard path (creating the
/// directory), refusing to overwrite an existing file. Returns the path.
pub fn writeDefault(io: std.Io, buf: []u8) ![]const u8 {
    const path = standardPath(buf) orelse return error.NoHome;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(1))) |data| {
        std.heap.page_allocator.free(data);
        return error.PathAlreadyExists;
    } else |_| {}
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.NoHome;
    std.Io.Dir.cwd().createDirPath(io, path[0..dir_end]) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = default_text });
    return path;
}

test "apply parses keys, comments, junk" {
    settings = .{};
    apply(
        \\# comment
        \\tab_width = 8
        \\nerd_font = false   # trailing comment
        \\not_a_setting = 42
        \\garbage line without equals
        \\tab_width = 99
    );
    try std.testing.expectEqual(@as(usize, 8), settings.tab_width); // 99 out of range, kept 8
    try std.testing.expectEqual(false, settings.nerd_font);
    settings = .{};
}

test "default config text applies cleanly to defaults" {
    settings = .{};
    apply(default_text);
    try std.testing.expectEqual(@as(usize, 4), settings.tab_width);
    try std.testing.expectEqual(true, settings.nerd_font);
}
