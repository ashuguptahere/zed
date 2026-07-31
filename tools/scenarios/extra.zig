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
    // Helix-style `e`/`b`: the motion leaves what it travelled over selected,
    // so the next key acts on it. Only these two — Helix selects with every
    // motion, which would change what `d`, `.` and visual mode all mean.
    const words = "alpha beta gamma delta\n";
    h.case(ctx, target, "e selects the word it moved over", &.{ "ed", ":wq", CR }, words, " beta gamma delta\n");
    h.case(ctx, target, "a second e extends the selection", &.{ "eed", ":wq", CR }, words, " gamma delta\n");
    h.case(ctx, target, "b selects backwards", &.{ "wbd", ":wq", CR }, words, "eta gamma delta\n");
    // With an operator pending they stay plain motions: `de` deletes the word
    // rather than selecting it and waiting.
    h.case(ctx, target, "de is still the operator form", &.{ "de", ":wq", CR }, words, " beta gamma delta\n");
    h.case(ctx, target, "d2e takes two words", &.{ "d2e", ":wq", CR }, words, " gamma delta\n");

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
