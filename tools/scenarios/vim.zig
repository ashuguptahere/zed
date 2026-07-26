//! Vim keybindings end-to-end: each case drives the editor and compares the
//! saved file. Port of tools/vim_test.py.

const std = @import("std");
const h = @import("../harness.zig");

const ESC = "\x1b";
const CR = "\r";
const CTRL_R = "\x12";
const target = "/tmp/zedit_it_vim.txt";

pub fn run(ctx: *h.Ctx) !void {
    // operators + motions
    h.case(ctx, target, "dw deletes word", &.{ "dw", ":wq", CR }, "foo bar baz\n", "bar baz\n");
    h.case(ctx, target, "dd deletes line", &.{ "dd", ":wq", CR }, "a\nb\nc\n", "b\nc\n");
    h.case(ctx, target, "2dd deletes two lines", &.{ "2dd", ":wq", CR }, "a\nb\nc\nd\n", "c\nd\n");
    h.case(ctx, target, "cw changes word", &.{ "cw", "X", ESC, ":wq", CR }, "foo bar\n", "X bar\n");
    h.case(ctx, target, "3x deletes 3 chars", &.{ "3x", ":wq", CR }, "abcdef\n", "def\n");
    h.case(ctx, target, "de deletes to word end", &.{ "de", ":wq", CR }, "foo bar\n", " bar\n");
    h.case(ctx, target, "d$ to end of line", &.{ "ld$", ":wq", CR }, "abcdef\n", "a\n");

    // registers + paste
    h.case(ctx, target, "yy then p duplicates", &.{ "yyp", ":wq", CR }, "hello\nworld\n", "hello\nhello\nworld\n");
    h.case(ctx, target, "dd then p moves line", &.{ "ddp", ":wq", CR }, "a\nb\nc\n", "b\na\nc\n");

    // visual
    h.case(ctx, target, "v selects then d", &.{ "vlld", ":wq", CR }, "abcdef\n", "def\n");
    h.case(ctx, target, "V deletes line", &.{ "Vd", ":wq", CR }, "a\nb\nc\n", "b\nc\n");
    h.case(ctx, target, "v y then p", &.{ "vly", "$p", ":wq", CR }, "abcd\n", "abcdab\n");

    // undo / redo
    h.case(ctx, target, "u undoes", &.{ "x", "u", ":wq", CR }, "abc\n", "abc\n");
    h.case(ctx, target, "ctrl-r redoes", &.{ "x", "u", CTRL_R, ":wq", CR }, "abc\n", "bc\n");

    // insert variants
    h.case(ctx, target, "A appends at end", &.{ "A", "Z", ESC, ":wq", CR }, "abc\n", "abcZ\n");
    h.case(ctx, target, "I inserts at first nb", &.{ "I", "X", ESC, ":wq", CR }, "  abc\n", "  Xabc\n");
    h.case(ctx, target, "o opens below", &.{ "o", "b", ESC, ":wq", CR }, "a\n", "a\nb\n");
    h.case(ctx, target, "O opens above", &.{ "O", "b", ESC, ":wq", CR }, "a\n", "b\na\n");

    // single-key edits
    h.case(ctx, target, "J joins lines", &.{ "J", ":wq", CR }, "a\nb\n", "a b\n");
    h.case(ctx, target, "r replaces char", &.{ "rX", ":wq", CR }, "abc\n", "Xbc\n");
    h.case(ctx, target, "~ toggles case", &.{ "~", ":wq", CR }, "abc\n", "Abc\n");

    // find motions with operators
    h.case(ctx, target, "dfc deletes incl char", &.{ "dfc", ":wq", CR }, "abcde\n", "de\n");
    h.case(ctx, target, "dt) deletes till char", &.{ "dt)", ":wq", CR }, "foo)bar\n", ")bar\n");

    // text objects
    h.case(ctx, target, "diw deletes inner word", &.{ "diw", ":wq", CR }, "foo bar\n", " bar\n");
    h.case(ctx, target, "ci\" changes in quotes", &.{ "ci\"", "X", ESC, ":wq", CR }, "say \"hi\" x\n", "say \"X\" x\n");
    h.case(ctx, target, "da( deletes a parens", &.{ "lll", "da(", ":wq", CR }, "x(abc)y\n", "xy\n");

    // search
    h.case(ctx, target, "/ search then x", &.{ "/foo", CR, "x", ":wq", CR }, "foo\nbar\nfoo\n", "foo\nbar\noo\n");
    h.case(ctx, target, "* searches word", &.{ "*x", ":wq", CR }, "foo bar foo\n", "foo bar oo\n");

    // marks
    h.case(ctx, target, "ma `a returns", &.{ "ma", "G", "`a", "x", ":wq", CR }, "a\nb\nc\n", "\nb\nc\n");

    // macro
    h.case(ctx, target, "record qaq then @a", &.{ "qa", "xj", "q", "@a", ":wq", CR }, "a\nb\nc\n", "\n\nc\n");

    // dot repeat
    h.case(ctx, target, "dot repeats dw", &.{ "dw", ".", ":wq", CR }, "aaa bbb ccc\n", "ccc\n");
}
