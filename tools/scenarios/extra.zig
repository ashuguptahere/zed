//! Surround (ys/cs/ds, visual S) and blockwise visual (Ctrl-v) end-to-end.
//! Port of tools/extra_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const CV = "\x16"; // Ctrl-v: blockwise visual
const target = "/tmp/zedit_it_extra.txt";

pub fn run(ctx: *h.Ctx) !void {
    // --- surround ---
    h.case(ctx, target, "ysiw) wraps word", &.{ "ysiw)", ":wq", CR }, "foo bar\n", "(foo) bar\n");
    h.case(ctx, target, "cs\"' changes", &.{ "cs\"'", ":wq", CR }, "say \"hi\"\n", "say 'hi'\n");
    h.case(ctx, target, "ds( deletes pair", &.{ "ds(", ":wq", CR }, "(abc)\n", "abc\n");
    h.case(ctx, target, "visual S surrounds", &.{ "v$S]", ":wq", CR }, "foo\n", "[foo]\n");

    // --- blockwise visual ---
    h.case(ctx, target, "block I inserts left", &.{ CV, "jj", "I", "X", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "Xaaa\nXbbb\nXccc\n");
    h.case(ctx, target, "block A appends right", &.{ CV, "jj", "A", "!", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "a!aa\nb!bb\nc!cc\n");
    h.case(ctx, target, "block d deletes column", &.{ CV, "jjl", "d", ":wq", CR }, "aaa\nbbb\nccc\n", "a\nb\nc\n");
    h.case(ctx, target, "block c changes column", &.{ CV, "jj", "c", "Z", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "Zaa\nZbb\nZcc\n");
}
