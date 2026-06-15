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
    status_fg: Color,
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
    .status_fg = rgb(0xa9, 0xb1, 0xd6),
    .status_seg_bg = rgb(0x29, 0x2e, 0x42),
    .status_seg_fg = rgb(0xc0, 0xca, 0xf5),
};

/// The active theme. A single global keeps call sites simple; swapping themes
/// later is a one-line change here.
pub const current = tokyonight;
