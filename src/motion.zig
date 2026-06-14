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
    var open_idx: ?usize = null;
    var close_idx: ?usize = null;
    while (col < line.len) {
        const c = line[col];
        if (std.mem.indexOfScalar(u8, opens, c)) |k| {
            open_idx = k;
            break;
        }
        if (std.mem.indexOfScalar(u8, closes, c)) |k| {
            close_idx = k;
            break;
        }
        col = unicode.nextBoundary(line, col);
    }

    if (open_idx) |k| return scan(buf, .{ .row = pos.row, .col = col }, opens[k], closes[k], true);
    if (close_idx) |k| return scan(buf, .{ .row = pos.row, .col = col }, closes[k], opens[k], false);
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
    const o = findOpen(buf, pos, open, close) orelse return null;
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
