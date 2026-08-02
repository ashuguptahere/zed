//! Multiple cursors end-to-end: Ctrl-n/Ctrl-p add carets, edits apply to all.
//! Port of tools/multicursor_test.py.

const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const CN = "\x0e"; // Ctrl-n: add cursor below
const CP = "\x10"; // Ctrl-p: add cursor above
const target = "/tmp/zedit_it_mc.txt";

pub fn run(ctx: *h.Ctx) !void {
    h.case(ctx, target, "I inserts at all carets", &.{ CN, CN, "I", "X", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "Xaaa\nXbbb\nXccc\n");
    h.case(ctx, target, "A appends at all carets", &.{ CN, CN, "A", "!", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "aaa!\nbbb!\nccc!\n");
    h.case(ctx, target, "x deletes at all carets", &.{ CN, CN, "x", ":wq", CR }, "aaa\nbbb\nccc\n", "aa\nbb\ncc\n");
    h.case(ctx, target, "Esc collapses to one cursor", &.{ CN, CN, ESC, "x", ":wq", CR }, "aaa\nbbb\nccc\n", "aa\nbbb\nccc\n");
    h.case(ctx, target, "Ctrl-p adds above", &.{ "G", CP, CP, "I", ">", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", ">aaa\n>bbb\n>ccc\n");
}
