//! Vim keybindings end-to-end: each case drives the editor and compares the
//! saved file. Port of tools/vim_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const CTRL_R = "\x12";
const target = "/tmp/zed_it_vim.txt";

fn case(ctx: *h.Ctx, name: []const u8, chunks: []const []const u8, initial: []const u8, want: []const u8) void {
    const got = h.runEdit(ctx, target, initial, chunks);
    defer ctx.gpa.free(got);
    ctx.check(name, std.mem.eql(u8, got, want));
}

pub fn run(ctx: *h.Ctx) !void {
    // operators + motions
    case(ctx, "dw deletes word", &.{ "dw", ":wq", CR }, "foo bar baz\n", "bar baz\n");
    case(ctx, "dd deletes line", &.{ "dd", ":wq", CR }, "a\nb\nc\n", "b\nc\n");
    case(ctx, "2dd deletes two lines", &.{ "2dd", ":wq", CR }, "a\nb\nc\nd\n", "c\nd\n");
    case(ctx, "cw changes word", &.{ "cw", "X", ESC, ":wq", CR }, "foo bar\n", "X bar\n");
    case(ctx, "3x deletes 3 chars", &.{ "3x", ":wq", CR }, "abcdef\n", "def\n");
    case(ctx, "de deletes to word end", &.{ "de", ":wq", CR }, "foo bar\n", " bar\n");
    case(ctx, "d$ to end of line", &.{ "ld$", ":wq", CR }, "abcdef\n", "a\n");

    // registers + paste
    case(ctx, "yy then p duplicates", &.{ "yyp", ":wq", CR }, "hello\nworld\n", "hello\nhello\nworld\n");
    case(ctx, "dd then p moves line", &.{ "ddp", ":wq", CR }, "a\nb\nc\n", "b\na\nc\n");

    // visual
    case(ctx, "v selects then d", &.{ "vlld", ":wq", CR }, "abcdef\n", "def\n");
    case(ctx, "V deletes line", &.{ "Vd", ":wq", CR }, "a\nb\nc\n", "b\nc\n");
    case(ctx, "v y then p", &.{ "vly", "$p", ":wq", CR }, "abcd\n", "abcdab\n");

    // undo / redo
    case(ctx, "u undoes", &.{ "x", "u", ":wq", CR }, "abc\n", "abc\n");
    case(ctx, "ctrl-r redoes", &.{ "x", "u", CTRL_R, ":wq", CR }, "abc\n", "bc\n");

    // insert variants
    case(ctx, "A appends at end", &.{ "A", "Z", ESC, ":wq", CR }, "abc\n", "abcZ\n");
    case(ctx, "I inserts at first nb", &.{ "I", "X", ESC, ":wq", CR }, "  abc\n", "  Xabc\n");
    case(ctx, "o opens below", &.{ "o", "b", ESC, ":wq", CR }, "a\n", "a\nb\n");
    case(ctx, "O opens above", &.{ "O", "b", ESC, ":wq", CR }, "a\n", "b\na\n");

    // single-key edits
    case(ctx, "J joins lines", &.{ "J", ":wq", CR }, "a\nb\n", "a b\n");
    case(ctx, "r replaces char", &.{ "rX", ":wq", CR }, "abc\n", "Xbc\n");
    case(ctx, "~ toggles case", &.{ "~", ":wq", CR }, "abc\n", "Abc\n");

    // find motions with operators
    case(ctx, "dfc deletes incl char", &.{ "dfc", ":wq", CR }, "abcde\n", "de\n");
    case(ctx, "dt) deletes till char", &.{ "dt)", ":wq", CR }, "foo)bar\n", ")bar\n");

    // text objects
    case(ctx, "diw deletes inner word", &.{ "diw", ":wq", CR }, "foo bar\n", " bar\n");
    case(ctx, "ci\" changes in quotes", &.{ "ci\"", "X", ESC, ":wq", CR }, "say \"hi\" x\n", "say \"X\" x\n");
    case(ctx, "da( deletes a parens", &.{ "lll", "da(", ":wq", CR }, "x(abc)y\n", "xy\n");

    // search
    case(ctx, "/ search then x", &.{ "/foo", CR, "x", ":wq", CR }, "foo\nbar\nfoo\n", "foo\nbar\noo\n");
    case(ctx, "* searches word", &.{ "*x", ":wq", CR }, "foo bar foo\n", "foo bar oo\n");

    // marks
    case(ctx, "ma `a returns", &.{ "ma", "G", "`a", "x", ":wq", CR }, "a\nb\nc\n", "\nb\nc\n");

    // macro
    case(ctx, "record qaq then @a", &.{ "qa", "xj", "q", "@a", ":wq", CR }, "a\nb\nc\n", "\n\nc\n");

    // dot repeat
    case(ctx, "dot repeats dw", &.{ "dw", ".", ":wq", CR }, "aaa bbb ccc\n", "ccc\n");
}
