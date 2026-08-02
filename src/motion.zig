//! Cursor motions, as pure functions over a buffer.
//!
//! Each motion takes a position and returns a new one; counts are applied by the
//! caller repeating the call. Keeping these free of editor state makes the
//! tricky word/WORD rules unit-testable. The editor knows each motion's operator
//! semantics (exclusive / inclusive / linewise) separately.

const std = @import("std");
const unicode = @import("unicode.zig");
const buffer = @import("buffer.zig");

pub const Pos = buffer.Pos;

/// vim character classes: whitespace (0), keyword (1), other/punctuation (2).
/// For WORD motions every non-blank collapses to a single class.
fn classOf(cp: u21, big: bool) u8 {
    if (cp == ' ' or cp == '\t') return 0;
    if (big) return 1;
    if (cp == '_' or isAlnum(cp) or cp >= 0x80) return 1;
    return 2;
}

fn isAlnum(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
}

fn classAt(line: []const u8, col: usize, big: bool) u8 {
    return classOf(unicode.decode(line[col..]).cp, big);
}

/// `w` / `W`: start of the next word.
pub fn wordForward(buf: *const buffer.Buffer, pos: Pos, big: bool) Pos {
    var row = pos.row;
    var col = pos.col;
    const n = buf.lineCount();

    const line0 = buf.line(row);
    if (col < line0.len) {
        const c0 = classAt(line0, col, big);
        if (c0 != 0) {
            while (col < line0.len and classAt(line0, col, big) == c0)
                col = unicode.nextBoundary(line0, col);
        }
    }
    while (true) {
        const line = buf.line(row);
        while (col < line.len and classAt(line, col, big) == 0)
            col = unicode.nextBoundary(line, col);
        if (col < line.len) break;
        if (row + 1 >= n) {
            col = line.len;
            break;
        }
        row += 1;
        col = 0;
        if (buf.line(row).len == 0) break; // empty line is its own word
    }
    return .{ .row = row, .col = col };
}

/// `e` / `E`: end of the next word (inclusive motion).
pub fn wordEnd(buf: *const buffer.Buffer, pos: Pos, big: bool) Pos {
    var row = pos.row;
    var col = pos.col;
    const n = buf.lineCount();

    // Always advance at least one position.
    const s = stepForward(buf, row, col);
    row = s.row;
    col = s.col;

    // Skip whitespace and line breaks to the next non-blank.
    while (true) {
        const line = buf.line(row);
        while (col < line.len and classAt(line, col, big) == 0)
            col = unicode.nextBoundary(line, col);
        if (col < line.len) break;
        if (row + 1 >= n) return .{ .row = row, .col = if (line.len == 0) 0 else unicode.prevBoundary(line, line.len) };
        row += 1;
        col = 0;
    }

    // Walk to the last char of this class run.
    const line = buf.line(row);
    const c = classAt(line, col, big);
    while (true) {
        const next = unicode.nextBoundary(line, col);
        if (next >= line.len or classAt(line, next, big) != c) break;
        col = next;
    }
    return .{ .row = row, .col = col };
}

/// `b` / `B`: start of the previous word.
pub fn wordBackward(buf: *const buffer.Buffer, pos: Pos, big: bool) Pos {
    var p = stepBackward(buf, pos.row, pos.col);

    // Skip whitespace / line breaks backwards to a non-blank.
    while (true) {
        const line = buf.line(p.row);
        if (p.col < line.len and classAt(line, p.col, big) != 0) break;
        if (p.col >= line.len and line.len != 0) {
            p.col = unicode.prevBoundary(line, line.len);
            if (classAt(line, p.col, big) != 0) break;
        }
        if (p.row == 0 and p.col == 0) return .{ .row = 0, .col = 0 };
        p = stepBackward(buf, p.row, p.col);
    }

    // Walk to the start of this class run.
    const line = buf.line(p.row);
    const c = classAt(line, p.col, big);
    while (p.col > 0) {
        const prev = unicode.prevBoundary(line, p.col);
        if (classAt(line, prev, big) != c) break;
        p.col = prev;
    }
    return p;
}

/// `f`/`t` forward, `F`/`T` backward search within the current line for `target`.
/// `till` stops one cell short (t/T). Returns null if not found.
pub fn findChar(line: []const u8, col: usize, target: u21, forward: bool, till: bool) ?usize {
    if (forward) {
        var i = unicode.nextBoundary(line, col);
        // For 't', if we're already just before the target, skip it so repeats advance.
        while (i < line.len) {
            const d = unicode.decode(line[i..]);
            if (d.cp == target) return if (till) unicode.prevBoundary(line, i) else i;
            i += d.len;
        }
        return null;
    } else {
        if (col == 0) return null;
        var i = unicode.prevBoundary(line, col);
        while (true) {
            const d = unicode.decode(line[i..]);
            if (d.cp == target) return if (till) unicode.nextBoundary(line, i) else i;
            if (i == 0) return null;
            i = unicode.prevBoundary(line, i);
        }
    }
}

/// `%`: jump to the bracket matching the nearest bracket at/after the cursor.
pub fn matchPair(buf: *const buffer.Buffer, pos: Pos) ?Pos {
    const opens = "([{";
    const closes = ")]}";
    const line = buf.line(pos.row);

    // Find the first bracket at or after the cursor on this line.
    var col = pos.col;
    while (col < line.len) : (col = unicode.nextBoundary(line, col)) {
        if (std.mem.indexOfScalar(u8, opens, line[col])) |k|
            return scan(buf, .{ .row = pos.row, .col = col }, opens[k], closes[k], true);
        if (std.mem.indexOfScalar(u8, closes, line[col])) |k|
            return scan(buf, .{ .row = pos.row, .col = col }, closes[k], opens[k], false);
    }
    return null;
}

fn scan(buf: *const buffer.Buffer, from: Pos, this: u8, other: u8, forward: bool) ?Pos {
    var depth: i32 = 0;
    var p = from;
    while (true) {
        const line = buf.line(p.row);
        if (p.col < line.len) {
            const c = line[p.col];
            if (c == this) depth += 1;
            if (c == other) {
                depth -= 1;
                if (depth == 0) return p;
            }
        }
        const next = if (forward) stepForward(buf, p.row, p.col) else stepBackward(buf, p.row, p.col);
        if (next.row == p.row and next.col == p.col) return null; // hit an end
        p = next;
    }
}

/// The character class a double-click groups by (vim's `get_mouse_class`,
/// nvim-probed): blanks are 0, a fixed set of C-operator characters share
/// class 1 — so `->` and `*=` select as one — keyword characters are 2, and
/// every other ASCII character is its own class, which is why `.,;` selects
/// one character at a time while `..` selects both. This is *not* the word
/// class above: `viw` on `.,;` takes all three.
fn mouseClass(cp: u21) u32 {
    if (cp == ' ' or cp == '\t') return 0;
    if (cp >= 0x80) return utfClass(cp);
    if (cp == '_' or isAlnum(cp)) return 2;
    if (std.mem.indexOfScalar(u8, "-+*/%<>&|^!=", @intCast(cp)) != null) return 1;
    return cp;
}

/// vim's `utf_class` ranges, trimmed to the ones that change an outcome: the
/// punctuation blocks are class 1, each CJK/kana/Hangul block is its own class
/// (so `你好world` selects `你好`, nvim-probed), and everything else — Latin-1
/// letters, Greek, Cyrillic — is a keyword character, as `iskeyword`'s
/// `192-255` default makes it (`naïve` selects whole, nvim-probed).
fn utfClass(cp: u21) u32 {
    return switch (cp) {
        0x80...0xbf, 0x2000...0x206f, 0x3000...0x303f => 1,
        0x3040...0x309f => 0x3040, // Hiragana
        0x30a0...0x30ff => 0x30a0, // Katakana
        0x3400...0x4dbf, 0x4e00...0x9fff, 0xf900...0xfaff, 0x20000...0x2a6df => 0x4e00, // CJK
        0xac00...0xd7a3 => 0xac00, // Hangul
        else => 2,
    };
}

/// The span a double-click selects at `pos`, both ends inclusive and on a
/// character boundary (vim's rule, nvim-probed). A click past the end of the
/// line clamps to its last character. On punctuation vim first tries `%`: when
/// it finds an item at or after the cursor *on that line* the selection runs
/// from the click to the match, which may be backwards or on another line;
/// blanks and keyword characters never use it. Otherwise the run of
/// same-class characters around the click is taken.
pub fn mouseWord(buf: *const buffer.Buffer, pos: Pos) Span {
    const line = buf.line(pos.row);
    if (line.len == 0) return .{ .start = pos, .end = pos };
    const col = if (pos.col < line.len) pos.col else unicode.prevBoundary(line, line.len);
    const here: Pos = .{ .row = pos.row, .col = col };
    const cp = unicode.decode(line[col..]).cp;
    const cls = mouseClass(cp);
    if (cp < 0x80 and cls != 0 and cls != 2) {
        if (matchPair(buf, here)) |m| {
            const back = m.row < here.row or (m.row == here.row and m.col < here.col);
            return if (back) .{ .start = m, .end = here } else .{ .start = here, .end = m };
        }
    }
    var s = col;
    while (s > 0) {
        const prev = unicode.prevBoundary(line, s);
        if (mouseClass(unicode.decode(line[prev..]).cp) != cls) break;
        s = prev;
    }
    var e = col;
    while (true) {
        const next = unicode.nextBoundary(line, e);
        if (next >= line.len or mouseClass(unicode.decode(line[next..]).cp) != cls) break;
        e = next;
    }
    return .{ .start = .{ .row = pos.row, .col = s }, .end = .{ .row = pos.row, .col = e } };
}

/// First non-blank column of a line (`^`).
pub fn firstNonBlank(line: []const u8) usize {
    var col: usize = 0;
    while (col < line.len) {
        const d = unicode.decode(line[col..]);
        if (d.cp != ' ' and d.cp != '\t') break;
        col += d.len;
    }
    return col;
}

/// Move one codepoint forward, crossing to the next line's start at end-of-line.
/// Returns the same position when already at the very end of the buffer.
fn stepForward(buf: *const buffer.Buffer, row: usize, col: usize) Pos {
    const line = buf.line(row);
    if (col < line.len) {
        const next = unicode.nextBoundary(line, col);
        if (next < line.len) return .{ .row = row, .col = next };
        // Landed on end-of-line; represent it as col == line.len.
        if (col != line.len) return .{ .row = row, .col = line.len };
    }
    if (row + 1 < buf.lineCount()) return .{ .row = row + 1, .col = 0 };
    return .{ .row = row, .col = col };
}

/// Move one codepoint backward, crossing to the previous line's end at column 0.
fn stepBackward(buf: *const buffer.Buffer, row: usize, col: usize) Pos {
    if (col > 0) {
        const line = buf.line(row);
        return .{ .row = row, .col = unicode.prevBoundary(line, col) };
    }
    if (row > 0) {
        const prev = buf.line(row - 1);
        return .{ .row = row - 1, .col = prev.len };
    }
    return .{ .row = row, .col = col };
}

/// An inclusive character range for text objects.
pub const Span = struct { start: Pos, end: Pos, empty: bool = false };

/// `iw`/`aw` (and WORD variants): the word run under the cursor. `around`
/// extends to trailing whitespace (or leading, if there is none trailing).
pub fn objWord(buf: *const buffer.Buffer, pos: Pos, big: bool, around: bool) ?Span {
    const line = buf.line(pos.row);
    if (line.len == 0) return null;
    const col = if (pos.col >= line.len) unicode.prevBoundary(line, line.len) else pos.col;
    const c0 = classAt(line, col, big);

    var start = col;
    while (start > 0) {
        const p = unicode.prevBoundary(line, start);
        if (classAt(line, p, big) != c0) break;
        start = p;
    }
    var end = col;
    while (true) {
        const nb = unicode.nextBoundary(line, end);
        if (nb >= line.len or classAt(line, nb, big) != c0) break;
        end = nb;
    }

    if (around) {
        var extended = false;
        var e = end;
        while (true) {
            const nb = unicode.nextBoundary(line, e);
            if (nb >= line.len or classAt(line, nb, big) != 0) break;
            e = nb;
            extended = true;
        }
        if (extended) {
            end = e;
        } else {
            while (start > 0) {
                const p = unicode.prevBoundary(line, start);
                if (classAt(line, p, big) != 0) break;
                start = p;
            }
        }
    }
    return .{ .start = .{ .row = pos.row, .col = start }, .end = .{ .row = pos.row, .col = end } };
}

/// `i(`/`a(` and friends: the range enclosed by a bracket pair. `around`
/// includes the brackets themselves.
pub fn objPair(buf: *const buffer.Buffer, pos: Pos, open: u8, close: u8, around: bool) ?Span {
    // Like vim: prefer the enclosing pair; when the cursor is outside one,
    // seek forward on the current line for the next opener.
    const o = findOpen(buf, pos, open, close) orelse fwd: {
        const line = buf.line(pos.row);
        var col = pos.col;
        while (col < line.len) : (col += 1) {
            if (line[col] == open) break :fwd Pos{ .row = pos.row, .col = col };
        }
        return null;
    };
    const c = findClose(buf, o, open, close) orelse return null;
    if (around) return .{ .start = o, .end = c };

    const inner_start = stepForward(buf, o.row, o.col);
    // Inner is empty when the close sits immediately after the open.
    if (inner_start.row == c.row and inner_start.col == c.col)
        return .{ .start = inner_start, .end = inner_start, .empty = true };
    const inner_end = stepBackward(buf, c.row, c.col);
    return .{ .start = inner_start, .end = inner_end };
}

/// `i"`/`a"` etc.: the range between a pair of quote characters on the line.
pub fn objQuote(buf: *const buffer.Buffer, pos: Pos, q: u8, around: bool) ?Span {
    const line = buf.line(pos.row);
    var open: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != q) continue;
        if (open) |o| {
            // Pair [o, i]. Use it if it contains or is after the cursor.
            if (pos.col <= i) {
                if (around) return .{ .start = .{ .row = pos.row, .col = o }, .end = .{ .row = pos.row, .col = i } };
                if (i == o + 1) return .{ .start = .{ .row = pos.row, .col = o + 1 }, .end = .{ .row = pos.row, .col = o + 1 }, .empty = true };
                return .{ .start = .{ .row = pos.row, .col = o + 1 }, .end = .{ .row = pos.row, .col = i - 1 } };
            }
            open = null;
        } else {
            open = i;
        }
    }
    return null;
}

fn findOpen(buf: *const buffer.Buffer, pos: Pos, open: u8, close: u8) ?Pos {
    var depth: i32 = 0;
    var p = pos;
    while (true) {
        const line = buf.line(p.row);
        if (p.col < line.len) {
            const ch = line[p.col];
            const at_cursor = p.row == pos.row and p.col == pos.col;
            if (ch == close and !at_cursor) depth += 1;
            if (ch == open) {
                if (depth == 0) return p;
                depth -= 1;
            }
        }
        const nxt = stepBackward(buf, p.row, p.col);
        if (nxt.row == p.row and nxt.col == p.col) return null;
        p = nxt;
    }
}

fn findClose(buf: *const buffer.Buffer, from: Pos, open: u8, close: u8) ?Pos {
    var depth: i32 = 0;
    var p = from;
    while (true) {
        const line = buf.line(p.row);
        if (p.col < line.len) {
            const ch = line[p.col];
            if (ch == open) depth += 1;
            if (ch == close) {
                depth -= 1;
                if (depth == 0) return p;
            }
        }
        const nxt = stepForward(buf, p.row, p.col);
        if (nxt.row == p.row and nxt.col == p.col) return null;
        p = nxt;
    }
}

const testing = std.testing;

fn testBuf(data: []const u8) buffer.Buffer {
    return buffer.Buffer.fromBytes(testing.allocator, data) catch unreachable;
}

test "wordForward over words and punctuation" {
    var b = testBuf("foo bar.baz\n");
    defer b.deinit();
    try testing.expectEqual(Pos{ .row = 0, .col = 4 }, wordForward(&b, .{ .row = 0, .col = 0 }, false)); // foo -> bar
    try testing.expectEqual(Pos{ .row = 0, .col = 7 }, wordForward(&b, .{ .row = 0, .col = 4 }, false)); // bar -> .
    try testing.expectEqual(Pos{ .row = 0, .col = 8 }, wordForward(&b, .{ .row = 0, .col = 7 }, false)); // . -> baz
}

test "wordForward WORD ignores punctuation" {
    var b = testBuf("foo bar.baz qux\n");
    defer b.deinit();
    try testing.expectEqual(Pos{ .row = 0, .col = 4 }, wordForward(&b, .{ .row = 0, .col = 0 }, true));
    try testing.expectEqual(Pos{ .row = 0, .col = 12 }, wordForward(&b, .{ .row = 0, .col = 4 }, true)); // bar.baz -> qux
}

test "wordForward crosses lines" {
    var b = testBuf("ab\ncd\n");
    defer b.deinit();
    try testing.expectEqual(Pos{ .row = 1, .col = 0 }, wordForward(&b, .{ .row = 0, .col = 0 }, false));
}

test "wordBackward" {
    var b = testBuf("foo bar baz\n");
    defer b.deinit();
    try testing.expectEqual(Pos{ .row = 0, .col = 4 }, wordBackward(&b, .{ .row = 0, .col = 8 }, false));
    try testing.expectEqual(Pos{ .row = 0, .col = 0 }, wordBackward(&b, .{ .row = 0, .col = 4 }, false));
}

test "wordEnd" {
    var b = testBuf("foo bar\n");
    defer b.deinit();
    try testing.expectEqual(Pos{ .row = 0, .col = 2 }, wordEnd(&b, .{ .row = 0, .col = 0 }, false)); // -> 'o' of foo
    try testing.expectEqual(Pos{ .row = 0, .col = 6 }, wordEnd(&b, .{ .row = 0, .col = 2 }, false)); // -> 'r' of bar
}

test "findChar forward and till" {
    const line = "abcabc";
    try testing.expectEqual(@as(?usize, 3), findChar(line, 0, 'a', true, false));
    try testing.expectEqual(@as(?usize, 1), findChar(line, 0, 'b', true, false));
    try testing.expectEqual(@as(?usize, 0), findChar(line, 3, 'a', false, false)); // backward to the first 'a'
    try testing.expectEqual(@as(?usize, null), findChar(line, 0, 'z', true, false));
}

test "matchPair" {
    var b = testBuf("a(bc)d\n");
    defer b.deinit();
    try testing.expectEqual(@as(?Pos, Pos{ .row = 0, .col = 4 }), matchPair(&b, .{ .row = 0, .col = 1 }));
    try testing.expectEqual(@as(?Pos, Pos{ .row = 0, .col = 1 }), matchPair(&b, .{ .row = 0, .col = 4 }));
}

/// Whether `row` is a paragraph boundary: a truly empty line (vim's rule —
/// whitespace-only lines are NOT boundaries; nvim-verified).
fn blankRow(buf: *const buffer.Buffer, row: usize) bool {
    return buf.line(row).len == 0;
}

/// One `}` step: the next empty line after the paragraph under/after `row`
/// (a blank run the cursor sits in is skipped first). Null at buffer end.
pub fn paraForward(buf: *const buffer.Buffer, row: usize) ?usize {
    const last = buf.lineCount() - 1;
    if (row >= last) return null;
    var r = row + 1;
    if (blankRow(buf, row)) {
        while (r <= last and blankRow(buf, r)) r += 1;
    }
    while (r <= last and !blankRow(buf, r)) r += 1;
    if (r > last) return null;
    return r;
}

/// One `{` step: the previous empty line before the paragraph under/before
/// `row`. Null at the buffer start (the caller falls back to row 0).
pub fn paraBackward(buf: *const buffer.Buffer, row: usize) ?usize {
    if (row == 0) return null;
    var r = row - 1;
    if (blankRow(buf, row)) {
        while (r > 0 and blankRow(buf, r)) r -= 1;
    }
    while (r > 0 and !blankRow(buf, r)) r -= 1;
    if (!blankRow(buf, r)) return null;
    return r;
}

pub const LineRange = struct { top: usize, bot: usize };

/// The `ip`/`ap` line range around `row` (nvim-verified): the run of blank or
/// non-blank lines the cursor is on; `around` adds the complementary run that
/// follows (trailing blanks for a paragraph — or the leading ones when
/// nothing trails). `count` takes that many runs (ip) / pairs of runs (ap).
pub fn paraObject(buf: *const buffer.Buffer, row: usize, around: bool, count: usize) LineRange {
    const last = buf.lineCount() - 1;
    var top = row;
    while (top > 0 and blankRow(buf, top - 1) == blankRow(buf, row)) top -= 1;
    var bot = row;
    var segs = if (around) count * 2 else count;
    while (segs > 0) : (segs -= 1) {
        const kind = blankRow(buf, bot);
        while (bot < last and blankRow(buf, bot + 1) == kind) bot += 1;
        if (segs > 1) {
            if (bot == last) break;
            bot += 1;
        }
    }
    // ap on a paragraph with no trailing blanks takes the leading ones.
    if (around and !blankRow(buf, row) and !blankRow(buf, bot)) {
        while (top > 0 and blankRow(buf, top - 1)) top -= 1;
    }
    return .{ .top = top, .bot = bot };
}

test "paraForward and paraBackward step between boundaries" {
    var b = testBuf("aaa\nbbb\n\nccc\n\n\nddd\n");
    defer b.deinit();
    try testing.expectEqual(@as(?usize, 2), paraForward(&b, 0));
    try testing.expectEqual(@as(?usize, 4), paraForward(&b, 2)); // skips own run, crosses ccc
    try testing.expectEqual(@as(?usize, null), paraForward(&b, 6));
    try testing.expectEqual(@as(?usize, 2), paraBackward(&b, 3));
    try testing.expectEqual(@as(?usize, null), paraBackward(&b, 0));
    try testing.expectEqual(@as(?usize, null), paraBackward(&b, 1)); // only text above
}

test "paraForward ignores whitespace-only lines" {
    var b = testBuf("aaa\n  \nbbb\n\nccc\n");
    defer b.deinit();
    try testing.expectEqual(@as(?usize, 3), paraForward(&b, 0));
}

test "paraObject inner, around, counts" {
    var b = testBuf("aaa\nbbb\n\nccc\n\nddd\n");
    defer b.deinit();
    const ip = paraObject(&b, 0, false, 1);
    try testing.expectEqual(@as(usize, 0), ip.top);
    try testing.expectEqual(@as(usize, 1), ip.bot);
    const ap = paraObject(&b, 0, true, 1);
    try testing.expectEqual(@as(usize, 2), ap.bot); // + trailing blank
    const blank = paraObject(&b, 2, false, 1);
    try testing.expectEqual(@as(usize, 2), blank.top);
    try testing.expectEqual(@as(usize, 2), blank.bot);
    const ap2 = paraObject(&b, 0, true, 2);
    try testing.expectEqual(@as(usize, 4), ap2.bot); // two paragraphs + blanks
    const ap_last = paraObject(&b, 5, true, 1);
    try testing.expectEqual(@as(usize, 4), ap_last.top); // leading blank instead
}

test "objWord inner and around" {
    var b = testBuf("foo bar baz\n");
    defer b.deinit();
    const iw = objWord(&b, .{ .row = 0, .col = 5 }, false, false).?; // on 'a' of bar
    try testing.expectEqual(@as(usize, 4), iw.start.col);
    try testing.expectEqual(@as(usize, 6), iw.end.col);
    const aw = objWord(&b, .{ .row = 0, .col = 5 }, false, true).?;
    try testing.expectEqual(@as(usize, 4), aw.start.col);
    try testing.expectEqual(@as(usize, 7), aw.end.col); // includes trailing space
}

test "objPair inner and around" {
    var b = testBuf("x(abc)y\n");
    defer b.deinit();
    const inner = objPair(&b, .{ .row = 0, .col = 3 }, '(', ')', false).?;
    try testing.expectEqual(@as(usize, 2), inner.start.col);
    try testing.expectEqual(@as(usize, 4), inner.end.col);
    const around = objPair(&b, .{ .row = 0, .col = 3 }, '(', ')', true).?;
    try testing.expectEqual(@as(usize, 1), around.start.col);
    try testing.expectEqual(@as(usize, 5), around.end.col);
}

test "objQuote" {
    var b = testBuf("say \"hello\" now\n");
    defer b.deinit();
    const inner = objQuote(&b, .{ .row = 0, .col = 6 }, '"', false).?;
    try testing.expectEqual(@as(usize, 5), inner.start.col);
    try testing.expectEqual(@as(usize, 9), inner.end.col);
}

// The double-click cases below were generated by driving real nvim (v0.12.4,
// `-u NONE -i NONE -n --noplugin`, `:set mouse=a` typed) through a pty and
// deleting the resulting selection; the pty-level versions live in
// `vim_compat`.
fn dblCols(b: *const buffer.Buffer, row: usize, col: usize) [2]usize {
    const sp = mouseWord(b, .{ .row = row, .col = col });
    return .{ sp.start.col, sp.end.col };
}

test "mouseWord takes the keyword, blank or multibyte run" {
    var b = testBuf("hello, world foo\n  indented text here\n\u{4f60}\u{597d}world ab\n");
    defer b.deinit();
    try testing.expectEqual([2]usize{ 7, 11 }, dblCols(&b, 0, 8)); // world
    try testing.expectEqual([2]usize{ 0, 4 }, dblCols(&b, 0, 0)); // hello, at its first byte
    try testing.expectEqual([2]usize{ 13, 15 }, dblCols(&b, 0, 39)); // past EOL clamps to the last word
    try testing.expectEqual([2]usize{ 5, 5 }, dblCols(&b, 0, 5)); // a lone comma
    try testing.expectEqual([2]usize{ 6, 6 }, dblCols(&b, 0, 6)); // a lone space
    try testing.expectEqual([2]usize{ 0, 1 }, dblCols(&b, 1, 0)); // the whole indent run
    try testing.expectEqual([2]usize{ 0, 3 }, dblCols(&b, 2, 0)); // CJK stops before ASCII
    try testing.expectEqual([2]usize{ 0, 3 }, dblCols(&b, 2, 3)); // …from either character
}

test "mouseWord groups punctuation the way vim does" {
    var b = testBuf("a.,;b\na*=b\na.=b\nabc..def\n");
    defer b.deinit();
    try testing.expectEqual([2]usize{ 1, 1 }, dblCols(&b, 0, 1)); // '.' alone: not vim's iw
    try testing.expectEqual([2]usize{ 1, 2 }, dblCols(&b, 1, 1)); // *= is one class
    try testing.expectEqual([2]usize{ 1, 1 }, dblCols(&b, 2, 1)); // .= is not
    try testing.expectEqual([2]usize{ 3, 4 }, dblCols(&b, 3, 3)); // identical characters group
}

test "mouseWord runs % from the click, forwards only" {
    var b = testBuf("abc..def(g)\na(b)cd.ef\na->b(c)\nabc<def>ghi\na(b\n");
    defer b.deinit();
    try testing.expectEqual([2]usize{ 3, 10 }, dblCols(&b, 0, 3)); // click .. -> the ')' that '(' matches
    try testing.expectEqual([2]usize{ 6, 6 }, dblCols(&b, 1, 6)); // the pair is behind the click
    try testing.expectEqual([2]usize{ 1, 6 }, dblCols(&b, 2, 1)); // '->' reaches the ')' too
    try testing.expectEqual([2]usize{ 3, 3 }, dblCols(&b, 3, 3)); // '<>' is not a matchpair
    try testing.expectEqual([2]usize{ 1, 1 }, dblCols(&b, 4, 1)); // an unmatched '(' falls back
}

test "mouseWord % spans lines, and a blank line selects one cell" {
    var b = testBuf("abc(def\nabc)def\n\n");
    defer b.deinit();
    const sp = mouseWord(&b, .{ .row = 0, .col = 3 });
    try testing.expectEqual(Pos{ .row = 0, .col = 3 }, sp.start);
    try testing.expectEqual(Pos{ .row = 1, .col = 3 }, sp.end);
    const empty = mouseWord(&b, .{ .row = 2, .col = 0 });
    try testing.expectEqual(Pos{ .row = 2, .col = 0 }, empty.start);
    try testing.expectEqual(Pos{ .row = 2, .col = 0 }, empty.end);
}

// === sentences =============================================================
//
// Vim's rule: a sentence ends at `.`, `!` or `?`, followed by any number of
// `)`, `]`, `"` or `'`, and then a space, a tab or the end of the line. The
// next sentence starts after the whitespace that follows. Paragraph and
// section boundaries also end one, which here means an empty line.

fn isSentenceEnd(line: []const u8, i: usize) ?usize {
    if (i >= line.len) return null;
    if (line[i] != '.' and line[i] != '!' and line[i] != '?') return null;
    var j = i + 1;
    while (j < line.len and (line[j] == ')' or line[j] == ']' or line[j] == '"' or line[j] == '\'')) j += 1;
    // End of line counts as the terminator, as does a space or a tab.
    if (j >= line.len) return j;
    if (line[j] == ' ' or line[j] == '\t') return j;
    return null;
}

/// Byte offset just past the end of the sentence containing (or starting at)
/// `col` on `line`, not counting the whitespace after it. `line.len` when the
/// line has no terminator left.
fn sentenceEndFrom(line: []const u8, col: usize) usize {
    var i = col;
    while (i < line.len) : (i += 1) {
        if (isSentenceEnd(line, i)) |past| return past;
    }
    return line.len;
}

/// The start of the sentence that `col` belongs to, on `line` alone.
fn sentenceStartOn(line: []const u8, col: usize) usize {
    var start: usize = 0;
    var i: usize = 0;
    while (i < line.len and i <= col) {
        if (isSentenceEnd(line, i)) |past| {
            var w = past;
            while (w < line.len and (line[w] == ' ' or line[w] == '\t')) w += 1;
            if (w > col) break; // `col` is inside this sentence's tail
            start = w;
            i = w;
            continue;
        }
        i += 1;
    }
    return start;
}

/// `)` — the start of the next sentence. Crosses lines, and an empty line is
/// a sentence of its own (vim treats a paragraph boundary as one).
pub fn sentenceForward(buf: *const buffer.Buffer, pos: Pos) Pos {
    const last = buf.lineCount() - 1;
    const line = buf.line(pos.row);
    const past = sentenceEndFrom(line, pos.col);
    if (past < line.len) {
        var w = past;
        while (w < line.len and (line[w] == ' ' or line[w] == '\t')) w += 1;
        if (w < line.len) return .{ .row = pos.row, .col = w };
    }
    // Nothing left on this line: the next line's first sentence.
    if (pos.row >= last) return .{ .row = pos.row, .col = if (line.len == 0) 0 else unicode.prevBoundary(line, line.len) };
    var r = pos.row + 1;
    while (r < last and buf.line(r).len == 0 and buf.line(r + 1).len == 0) r += 1;
    return .{ .row = r, .col = 0 };
}

/// `(` — the start of the sentence the cursor is in, or the previous one when
/// it is already there.
pub fn sentenceBackward(buf: *const buffer.Buffer, pos: Pos) Pos {
    const line = buf.line(pos.row);
    const start = sentenceStartOn(line, pos.col);
    if (start < pos.col) return .{ .row = pos.row, .col = start };
    if (start > 0) {
        // At the start of a sentence that is not the line's first: step back
        // into the previous one and take its start.
        return .{ .row = pos.row, .col = sentenceStartOn(line, start - 1) };
    }
    if (pos.row == 0) return .{ .row = 0, .col = 0 };
    const prev = buf.line(pos.row - 1);
    return .{ .row = pos.row - 1, .col = sentenceStartOn(prev, prev.len -| 1) };
}

/// `is` / `as`. `as` takes the whitespace after the sentence; when there is
/// none on the line — the sentence ends the line — it takes the whitespace
/// before it instead, which is the same rule `ap` follows.
pub fn objSentence(buf: *const buffer.Buffer, pos: Pos, around: bool) ?Span {
    const line = buf.line(pos.row);
    if (line.len == 0) return null;
    const col = @min(pos.col, line.len -| 1);
    const start = sentenceStartOn(line, col);
    const end = sentenceEndFrom(line, start); // one past the terminator
    if (end <= start) return null;
    if (!around) return .{ .start = .{ .row = pos.row, .col = start }, .end = .{ .row = pos.row, .col = end } };
    var e = end;
    while (e < line.len and (line[e] == ' ' or line[e] == '\t')) e += 1;
    if (e > end) return .{ .start = .{ .row = pos.row, .col = start }, .end = .{ .row = pos.row, .col = e } };
    // No trailing whitespace: take the leading whitespace instead.
    var s = start;
    while (s > 0 and (line[s - 1] == ' ' or line[s - 1] == '\t')) s -= 1;
    return .{ .start = .{ .row = pos.row, .col = s }, .end = .{ .row = pos.row, .col = end } };
}

test "a sentence ends at .!? plus closers then whitespace" {
    try std.testing.expect(isSentenceEnd("One. Two.", 3) != null);
    try std.testing.expect(isSentenceEnd("Hi! Bye?", 2) != null);
    try std.testing.expect(isSentenceEnd("end.\")  x", 3) != null); // closers count
    try std.testing.expect(isSentenceEnd("3.14 is pi", 1) == null); // no space after
    try std.testing.expect(isSentenceEnd("last.", 4) != null); // end of line
}

test "the start of the sentence a column belongs to" {
    const l = "One. Two. Three.";
    try std.testing.expectEqual(@as(usize, 0), sentenceStartOn(l, 0));
    try std.testing.expectEqual(@as(usize, 0), sentenceStartOn(l, 3));
    try std.testing.expectEqual(@as(usize, 5), sentenceStartOn(l, 5));
    try std.testing.expectEqual(@as(usize, 5), sentenceStartOn(l, 8));
    try std.testing.expectEqual(@as(usize, 10), sentenceStartOn(l, 12));
}

test "the end of a sentence is one past its terminator" {
    try std.testing.expectEqual(@as(usize, 4), sentenceEndFrom("One. Two.", 0));
    try std.testing.expectEqual(@as(usize, 9), sentenceEndFrom("One. Two.", 5));
    try std.testing.expectEqual(@as(usize, 7), sentenceEndFrom("no stop", 0)); // no terminator
}
