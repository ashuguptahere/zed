//! Multiple cursors end-to-end: Ctrl-n/Ctrl-p add carets, edits apply to all.
//! Port of tools/multicursor_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const CN = "\x0e"; // Ctrl-n: add cursor below
const CP = "\x10"; // Ctrl-p: add cursor above
const target = "/tmp/zed_it_mc.txt";

fn case(ctx: *h.Ctx, name: []const u8, chunks: []const []const u8, initial: []const u8, want: []const u8) void {
    const got = h.runEdit(ctx, target, initial, chunks);
    defer ctx.gpa.free(got);
    ctx.check(name, std.mem.eql(u8, got, want));
}

pub fn run(ctx: *h.Ctx) !void {
    case(ctx, "I inserts at all carets", &.{ CN, CN, "I", "X", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "Xaaa\nXbbb\nXccc\n");
    case(ctx, "A appends at all carets", &.{ CN, CN, "A", "!", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "aaa!\nbbb!\nccc!\n");
    case(ctx, "x deletes at all carets", &.{ CN, CN, "x", ":wq", CR }, "aaa\nbbb\nccc\n", "aa\nbb\ncc\n");
    case(ctx, "Esc collapses to one cursor", &.{ CN, CN, ESC, "x", ":wq", CR }, "aaa\nbbb\nccc\n", "aa\nbbb\nccc\n");
    case(ctx, "Ctrl-p adds above", &.{ "G", CP, CP, "I", ">", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", ">aaa\n>bbb\n>ccc\n");
}
