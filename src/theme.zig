//! Colour theme and 24-bit (true colour) SGR helpers.
//!
//! The palette below is a Tokyo Night-style dark theme, the kind of look
//! AstroNvim and Helix ship by default. Colours are RGB triples emitted as
//! ANSI true-colour escapes; terminals without true-colour support will
//! approximate them.

const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Write the "set foreground" escape into `buf`, returning the slice used.
    pub fn fg(self: Color, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ self.r, self.g, self.b }) catch buf[0..0];
    }

    /// Write the "set background" escape into `buf`.
    pub fn bg(self: Color, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ self.r, self.g, self.b }) catch buf[0..0];
    }
};

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b };
}

pub const Theme = struct {
    bg: Color,
    bg_dark: Color, // status bar / inactive areas
    cursorline: Color, // current line background
    fg: Color,
    fg_dim: Color,

    gutter: Color,
    gutter_active: Color,
    selection: Color,
    match: Color, // search match highlight (background)
    indent_guide: Color,

    // syntax
    comment: Color,
    keyword: Color,
    type_: Color,
    builtin: Color,
    function: Color,
    string_: Color,
    char_: Color,
    number: Color,
    operator: Color,
    preproc: Color,

    // git gutter signs
    git_add: Color,
    git_change: Color,
    git_delete: Color,

    // mode accent colours (used for the statusline block)
    mode_normal: Color,
    mode_insert: Color,
    mode_visual: Color,
    mode_command: Color,

    // statusline segment colours
    status_bg: Color,
    status_seg_bg: Color,
    status_seg_fg: Color,
};

pub const tokyonight: Theme = .{
    .bg = rgb(0x1a, 0x1b, 0x26),
    .bg_dark = rgb(0x16, 0x16, 0x1e),
    .cursorline = rgb(0x29, 0x2e, 0x42),
    .fg = rgb(0xc0, 0xca, 0xf5),
    .fg_dim = rgb(0x56, 0x5f, 0x89),

    .gutter = rgb(0x3b, 0x42, 0x61),
    .gutter_active = rgb(0x73, 0x7a, 0xa2),
    .selection = rgb(0x28, 0x34, 0x57),
    .match = rgb(0x3d, 0x59, 0xa1),
    .indent_guide = rgb(0x29, 0x2e, 0x42),

    .comment = rgb(0x56, 0x5f, 0x89),
    .keyword = rgb(0xbb, 0x9a, 0xf7),
    .type_ = rgb(0x2a, 0xc3, 0xde),
    .builtin = rgb(0xe0, 0xaf, 0x68),
    .function = rgb(0x7a, 0xa2, 0xf7),
    .string_ = rgb(0x9e, 0xce, 0x6a),
    .char_ = rgb(0x9e, 0xce, 0x6a),
    .number = rgb(0xff, 0x9e, 0x64),
    .operator = rgb(0x89, 0xdd, 0xff),
    .preproc = rgb(0x7d, 0xcf, 0xff),

    .git_add = rgb(0x9e, 0xce, 0x6a),
    .git_change = rgb(0xe0, 0xaf, 0x68),
    .git_delete = rgb(0xf7, 0x76, 0x8e),

    .mode_normal = rgb(0x7a, 0xa2, 0xf7),
    .mode_insert = rgb(0x9e, 0xce, 0x6a),
    .mode_visual = rgb(0xbb, 0x9a, 0xf7),
    .mode_command = rgb(0xe0, 0xaf, 0x68),

    .status_bg = rgb(0x16, 0x16, 0x1e),
    .status_seg_bg = rgb(0x29, 0x2e, 0x42),
    .status_seg_fg = rgb(0xc0, 0xca, 0xf5),
};

// Gruvbox Dark (medium contrast)
pub const gruvbox: Theme = .{
    .bg = rgb(0x28, 0x28, 0x28),
    .bg_dark = rgb(0x1d, 0x20, 0x21), // bg0_h
    .cursorline = rgb(0x3c, 0x38, 0x36), // bg1
    .fg = rgb(0xeb, 0xdb, 0xb2),
    .fg_dim = rgb(0x92, 0x83, 0x74), // gray

    .gutter = rgb(0x7c, 0x6f, 0x64), // bg4
    .gutter_active = rgb(0xa8, 0x99, 0x84), // fg4
    .selection = rgb(0x50, 0x49, 0x45), // bg2
    .match = rgb(0x45, 0x85, 0x88), // neutral blue
    .indent_guide = rgb(0x3c, 0x38, 0x36),

    .comment = rgb(0x92, 0x83, 0x74),
    .keyword = rgb(0xfb, 0x49, 0x34), // red (gruvbox keywords are red)
    .type_ = rgb(0x8e, 0xc0, 0x7c), // aqua
    .builtin = rgb(0xfa, 0xbd, 0x2f), // yellow
    .function = rgb(0x83, 0xa5, 0x98), // blue
    .string_ = rgb(0xb8, 0xbb, 0x26), // green
    .char_ = rgb(0xb8, 0xbb, 0x26),
    .number = rgb(0xfe, 0x80, 0x19), // orange
    .operator = rgb(0x8e, 0xc0, 0x7c),
    .preproc = rgb(0x8e, 0xc0, 0x7c), // PreProc is aqua

    .git_add = rgb(0xb8, 0xbb, 0x26),
    .git_change = rgb(0xfa, 0xbd, 0x2f),
    .git_delete = rgb(0xfb, 0x49, 0x34),

    .mode_normal = rgb(0x83, 0xa5, 0x98),
    .mode_insert = rgb(0xb8, 0xbb, 0x26),
    .mode_visual = rgb(0xd3, 0x86, 0x9b), // purple
    .mode_command = rgb(0xfa, 0xbd, 0x2f),

    .status_bg = rgb(0x1d, 0x20, 0x21),
    .status_seg_bg = rgb(0x3c, 0x38, 0x36),
    .status_seg_fg = rgb(0xeb, 0xdb, 0xb2),
};

// Catppuccin Mocha
pub const catppuccin: Theme = .{
    .bg = rgb(0x1e, 0x1e, 0x2e), // base
    .bg_dark = rgb(0x18, 0x18, 0x25), // mantle
    .cursorline = rgb(0x31, 0x32, 0x44), // surface0
    .fg = rgb(0xcd, 0xd6, 0xf4), // text
    .fg_dim = rgb(0x6c, 0x70, 0x86), // overlay0

    .gutter = rgb(0x45, 0x47, 0x5a), // surface1
    .gutter_active = rgb(0xb4, 0xbe, 0xfe), // lavender (cursor line nr)
    .selection = rgb(0x45, 0x47, 0x5a), // surface1
    .match = rgb(0x89, 0xb4, 0xfa), // blue
    .indent_guide = rgb(0x31, 0x32, 0x44),

    .comment = rgb(0x6c, 0x70, 0x86),
    .keyword = rgb(0xcb, 0xa6, 0xf7), // mauve
    .type_ = rgb(0x94, 0xe2, 0xd5), // teal
    .builtin = rgb(0xf9, 0xe2, 0xaf), // yellow
    .function = rgb(0x89, 0xb4, 0xfa), // blue
    .string_ = rgb(0xa6, 0xe3, 0xa1), // green
    .char_ = rgb(0xa6, 0xe3, 0xa1),
    .number = rgb(0xfa, 0xb3, 0x87), // peach
    .operator = rgb(0x89, 0xdc, 0xeb), // sky
    .preproc = rgb(0x89, 0xdc, 0xeb),

    .git_add = rgb(0xa6, 0xe3, 0xa1),
    .git_change = rgb(0xf9, 0xe2, 0xaf),
    .git_delete = rgb(0xf3, 0x8b, 0xa8), // red

    .mode_normal = rgb(0x89, 0xb4, 0xfa),
    .mode_insert = rgb(0xa6, 0xe3, 0xa1),
    .mode_visual = rgb(0xcb, 0xa6, 0xf7),
    .mode_command = rgb(0xf9, 0xe2, 0xaf),

    .status_bg = rgb(0x18, 0x18, 0x25),
    .status_seg_bg = rgb(0x31, 0x32, 0x44),
    .status_seg_fg = rgb(0xcd, 0xd6, 0xf4),
};

// Nord
pub const nord: Theme = .{
    .bg = rgb(0x2e, 0x34, 0x40), // nord0
    .bg_dark = rgb(0x3b, 0x42, 0x52), // nord1 (Nord has no darker shade)
    .cursorline = rgb(0x3b, 0x42, 0x52), // nord1
    .fg = rgb(0xd8, 0xde, 0xe9), // nord4
    .fg_dim = rgb(0x4c, 0x56, 0x6a), // nord3

    .gutter = rgb(0x4c, 0x56, 0x6a), // nord3
    .gutter_active = rgb(0xd8, 0xde, 0xe9), // nord4
    .selection = rgb(0x43, 0x4c, 0x5e), // nord2
    .match = rgb(0x5e, 0x81, 0xac), // nord10
    .indent_guide = rgb(0x3b, 0x42, 0x52),

    .comment = rgb(0x4c, 0x56, 0x6a),
    .keyword = rgb(0x81, 0xa1, 0xc1), // nord9 (Nord spec: keywords)
    .type_ = rgb(0x8f, 0xbc, 0xbb), // nord7 (types/classes)
    .builtin = rgb(0xeb, 0xcb, 0x8b), // nord13
    .function = rgb(0x88, 0xc0, 0xd0), // nord8 (functions)
    .string_ = rgb(0xa3, 0xbe, 0x8c), // nord14
    .char_ = rgb(0xa3, 0xbe, 0x8c),
    .number = rgb(0xb4, 0x8e, 0xad), // nord15 (Nord spec: numbers)
    .operator = rgb(0x81, 0xa1, 0xc1), // nord9 (operators)
    .preproc = rgb(0x5e, 0x81, 0xac), // nord10 (preprocessor)

    .git_add = rgb(0xa3, 0xbe, 0x8c),
    .git_change = rgb(0xeb, 0xcb, 0x8b),
    .git_delete = rgb(0xbf, 0x61, 0x6a), // nord11

    .mode_normal = rgb(0x88, 0xc0, 0xd0),
    .mode_insert = rgb(0xa3, 0xbe, 0x8c),
    .mode_visual = rgb(0xb4, 0x8e, 0xad),
    .mode_command = rgb(0xeb, 0xcb, 0x8b),

    .status_bg = rgb(0x3b, 0x42, 0x52),
    .status_seg_bg = rgb(0x43, 0x4c, 0x5e),
    .status_seg_fg = rgb(0xec, 0xef, 0xf4), // nord6
};

// Atom One Dark
pub const onedark: Theme = .{
    .bg = rgb(0x28, 0x2c, 0x34),
    .bg_dark = rgb(0x21, 0x25, 0x2b), // black
    .cursorline = rgb(0x2c, 0x31, 0x3c),
    .fg = rgb(0xab, 0xb2, 0xbf),
    .fg_dim = rgb(0x5c, 0x63, 0x70), // comment gray

    .gutter = rgb(0x4b, 0x52, 0x63), // gutter gray
    .gutter_active = rgb(0xab, 0xb2, 0xbf),
    .selection = rgb(0x3e, 0x44, 0x51),
    .match = rgb(0x52, 0x8b, 0xff), // Atom accent blue
    .indent_guide = rgb(0x2c, 0x31, 0x3c),

    .comment = rgb(0x5c, 0x63, 0x70),
    .keyword = rgb(0xc6, 0x78, 0xdd), // purple
    .type_ = rgb(0x56, 0xb6, 0xc2), // cyan
    .builtin = rgb(0xe5, 0xc0, 0x7b), // yellow
    .function = rgb(0x61, 0xaf, 0xef), // blue
    .string_ = rgb(0x98, 0xc3, 0x79), // green
    .char_ = rgb(0x98, 0xc3, 0x79),
    .number = rgb(0xd1, 0x9a, 0x66), // orange
    .operator = rgb(0x56, 0xb6, 0xc2),
    .preproc = rgb(0x56, 0xb6, 0xc2),

    .git_add = rgb(0x98, 0xc3, 0x79),
    .git_change = rgb(0xe5, 0xc0, 0x7b),
    .git_delete = rgb(0xe0, 0x6c, 0x75), // red

    .mode_normal = rgb(0x61, 0xaf, 0xef),
    .mode_insert = rgb(0x98, 0xc3, 0x79),
    .mode_visual = rgb(0xc6, 0x78, 0xdd),
    .mode_command = rgb(0xe5, 0xc0, 0x7b),

    .status_bg = rgb(0x21, 0x25, 0x2b),
    .status_seg_bg = rgb(0x2c, 0x31, 0x3c),
    .status_seg_fg = rgb(0xab, 0xb2, 0xbf),
};

/// The built-in themes, selectable in the config file (`theme = <name>`), with
/// `:theme <name>`, or via the `Space f t` picker.
pub const themes = [_]struct { name: []const u8, palette: *const Theme }{
    .{ .name = "tokyonight", .palette = &tokyonight },
    .{ .name = "gruvbox", .palette = &gruvbox },
    .{ .name = "catppuccin", .palette = &catppuccin },
    .{ .name = "nord", .palette = &nord },
    .{ .name = "onedark", .palette = &onedark },
};

/// The active theme. A single mutable global keeps call sites simple (they
/// copy `theme.current` at the top of each render pass).
pub var current: Theme = tokyonight;

/// Switch the active theme by name. Returns false (keeping the current theme)
/// for unknown names.
pub fn set(name: []const u8) bool {
    for (themes) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            current = t.palette.*;
            return true;
        }
    }
    return false;
}

test "set switches and rejects unknown" {
    try std.testing.expect(!set("no-such-theme"));
    try std.testing.expect(set("tokyonight"));
}
