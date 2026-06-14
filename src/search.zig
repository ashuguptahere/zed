//! Literal text search across the buffer.
//!
//! vim uses regex; we do plain (case-sensitive) substring search, which covers
//! the common `/word`, `n`/`N` and `*`/`#` workflow without pulling in a regex
//! engine. Searches wrap around the end/start of the file.

const std = @import("std");
const buffer = @import("buffer.zig");

pub const Pos = buffer.Pos;

/// First match at or after the position *following* `from`, wrapping to the top.
pub fn next(buf: *const buffer.Buffer, from: Pos, needle: []const u8) ?Pos {
    if (needle.len == 0) return null;
    const lines = buf.lineCount();

    // Remainder of the current line, starting just past the cursor.
    if (std.mem.indexOfPos(u8, buf.line(from.row), from.col + 1, needle)) |c|
        return .{ .row = from.row, .col = c };

    var i: usize = 1;
    while (i <= lines) : (i += 1) {
        const row = (from.row + i) % lines;
        if (std.mem.indexOf(u8, buf.line(row), needle)) |c|
            return .{ .row = row, .col = c };
    }
    return null;
}

/// Last match strictly before `from`, wrapping to the bottom.
pub fn prev(buf: *const buffer.Buffer, from: Pos, needle: []const u8) ?Pos {
    if (needle.len == 0) return null;
    const lines = buf.lineCount();

    const head = buf.line(from.row);
    const limit = @min(from.col, head.len);
    if (lastIndexBefore(head[0..limit], needle)) |c|
        return .{ .row = from.row, .col = c };

    var i: usize = 1;
    while (i <= lines) : (i += 1) {
        const row = (from.row + lines - i) % lines;
        if (std.mem.lastIndexOf(u8, buf.line(row), needle)) |c|
            return .{ .row = row, .col = c };
    }
    return null;
}

fn lastIndexBefore(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.lastIndexOf(u8, haystack, needle);
}

/// The keyword under `pos` (alnum/underscore run), for `*` and `#`. Empty slice
/// if the cursor is not on a keyword character.
pub fn wordUnder(buf: *const buffer.Buffer, pos: Pos) []const u8 {
    const line = buf.line(pos.row);
    if (pos.col >= line.len or !isKeyword(line[pos.col])) {
        // Scan forward to the next keyword char on this line.
        var c = pos.col;
        while (c < line.len and !isKeyword(line[c])) c += 1;
        if (c >= line.len) return line[0..0];
        return keywordSpan(line, c);
    }
    return keywordSpan(line, pos.col);
}

fn keywordSpan(line: []const u8, at: usize) []const u8 {
    var start = at;
    while (start > 0 and isKeyword(line[start - 1])) start -= 1;
    var end = at;
    while (end < line.len and isKeyword(line[end])) end += 1;
    return line[start..end];
}

fn isKeyword(c: u8) bool {
    return c == '_' or (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

const testing = std.testing;

test "next finds forward and wraps" {
    var b = try buffer.Buffer.fromBytes(testing.allocator, "foo bar\nbar baz\n");
    defer b.deinit();
    try testing.expectEqual(@as(?Pos, Pos{ .row = 0, .col = 4 }), next(&b, .{ .row = 0, .col = 0 }, "bar"));
    // From the first 'bar', next match is on line 1.
    try testing.expectEqual(@as(?Pos, Pos{ .row = 1, .col = 0 }), next(&b, .{ .row = 0, .col = 4 }, "bar"));
    // From line 1, wrap back to line 0.
    try testing.expectEqual(@as(?Pos, Pos{ .row = 0, .col = 4 }), next(&b, .{ .row = 1, .col = 0 }, "bar"));
}

test "prev finds backward and wraps" {
    var b = try buffer.Buffer.fromBytes(testing.allocator, "foo bar\nbar baz\n");
    defer b.deinit();
    try testing.expectEqual(@as(?Pos, Pos{ .row = 0, .col = 4 }), prev(&b, .{ .row = 1, .col = 0 }, "bar"));
}

test "wordUnder" {
    var b = try buffer.Buffer.fromBytes(testing.allocator, "foo_bar baz\n");
    defer b.deinit();
    try testing.expectEqualStrings("foo_bar", wordUnder(&b, .{ .row = 0, .col = 2 }));
    try testing.expectEqualStrings("baz", wordUnder(&b, .{ .row = 0, .col = 8 }));
}
