//! Surround (ys/cs/ds, visual S) and blockwise visual (Ctrl-v) end-to-end.
//! Port of tools/extra_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const CV = "\x16"; // Ctrl-v: blockwise visual
const target = "/tmp/zed_it_extra.txt";

fn case(ctx: *h.Ctx, name: []const u8, chunks: []const []const u8, initial: []const u8, want: []const u8) void {
    const got = h.runEdit(ctx, target, initial, chunks);
    defer ctx.gpa.free(got);
    ctx.check(name, std.mem.eql(u8, got, want));
}

pub fn run(ctx: *h.Ctx) !void {
    // --- surround ---
    case(ctx, "ysiw) wraps word", &.{ "ysiw)", ":wq", CR }, "foo bar\n", "(foo) bar\n");
    case(ctx, "cs\"' changes", &.{ "cs\"'", ":wq", CR }, "say \"hi\"\n", "say 'hi'\n");
    case(ctx, "ds( deletes pair", &.{ "ds(", ":wq", CR }, "(abc)\n", "abc\n");
    case(ctx, "visual S surrounds", &.{ "v$S]", ":wq", CR }, "foo\n", "[foo]\n");

    // --- blockwise visual ---
    case(ctx, "block I inserts left", &.{ CV, "jj", "I", "X", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "Xaaa\nXbbb\nXccc\n");
    case(ctx, "block A appends right", &.{ CV, "jj", "A", "!", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "a!aa\nb!bb\nc!cc\n");
    case(ctx, "block d deletes column", &.{ CV, "jjl", "d", ":wq", CR }, "aaa\nbbb\nccc\n", "a\nb\nc\n");
    case(ctx, "block c changes column", &.{ CV, "jj", "c", "Z", ESC, ":wq", CR }, "aaa\nbbb\nccc\n", "Zaa\nZbb\nZcc\n");
}
