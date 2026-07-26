//! Buffer search (`/ ? n N * #`), regex-powered.
//!
//! Patterns are modern regexes (regex.zig — Pike VM, linear time). Purely
//! literal patterns take a fast path: while the buffer is unedited, one SIMD
//! substring scan over the whole source instead of a per-line loop. Searches
//! wrap around the end/start of the file.

const std = @import("std");
const buffer = @import("buffer.zig");
const regex = @import("regex.zig");

pub const Pos = buffer.Pos;

/// First regex match after `from`, wrapping to the top.
pub fn next(buf: *const buffer.Buffer, from: Pos, re: *const regex.Regex) ?Pos {
    if (re.lit) |lit| return nextLiteral(buf, from, lit);
    const lines = buf.lineCount();
    // Remainder of the current line, starting just past the cursor.
    if (re.find(buf.line(from.row), from.col + 1)) |m|
        return .{ .row = from.row, .col = m.span.start };
    var i: usize = 1;
    while (i <= lines) : (i += 1) {
        const row = (from.row + i) % lines;
        if (re.find(buf.line(row), 0)) |m|
            return .{ .row = row, .col = m.span.start };
    }
    return null;
}

/// Last regex match strictly before `from`, wrapping to the bottom.
pub fn prev(buf: *const buffer.Buffer, from: Pos, re: *const regex.Regex) ?Pos {
    if (re.lit) |lit| return prevLiteral(buf, from, lit);
    const lines = buf.lineCount();
    if (lastMatchBefore(buf.line(from.row), re, from.col)) |c|
        return .{ .row = from.row, .col = c };
    var i: usize = 1;
    while (i <= lines) : (i += 1) {
        const row = (from.row + lines - i) % lines;
        const line = buf.line(row);
        if (lastMatchBefore(line, re, line.len + 1)) |c|
            return .{ .row = row, .col = c };
    }
    return null;
}

/// The start of the last match beginning strictly before `limit` (regexes
/// only search forward, so walk the matches).
fn lastMatchBefore(line: []const u8, re: *const regex.Regex, limit: usize) ?usize {
    var best: ?usize = null;
    var at: usize = 0;
    while (at <= line.len) {
        const m = re.find(line, at) orelse break;
        if (m.span.start >= limit) break;
        best = m.span.start;
        at = if (m.span.end > m.span.start) m.span.end else m.span.start + 1;
    }
    return best;
}

/// First literal match at or after the position *following* `from`, wrapping.
pub fn nextLiteral(buf: *const buffer.Buffer, from: Pos, needle: []const u8) ?Pos {
    if (needle.len == 0) return null;
    // When the whole-source scan applies it is authoritative: a miss means
    // there is no match, so returning here avoids re-walking every line.
    // (Conflating "no match" with "no fast path" cost a full rescan per miss.)
    if (eligible(buf, needle)) |src| return fastNext(buf, src, from, needle);
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

/// Last literal match strictly before `from`, wrapping to the bottom.
pub fn prevLiteral(buf: *const buffer.Buffer, from: Pos, needle: []const u8) ?Pos {
    if (needle.len == 0) return null;
    if (eligible(buf, needle)) |src| return fastPrev(buf, src, from, needle);
    const lines = buf.lineCount();

    const head = buf.line(from.row);
    const limit = @min(from.col, head.len);
    if (std.mem.lastIndexOf(u8, head[0..limit], needle)) |c|
        return .{ .row = from.row, .col = c };

    var i: usize = 1;
    while (i <= lines) : (i += 1) {
        const row = (from.row + lines - i) % lines;
        if (std.mem.lastIndexOf(u8, buf.line(row), needle)) |c|
            return .{ .row = row, .col = c };
    }
    return null;
}

// --- whole-source fast path --------------------------------------------
// While a buffer is untouched after a load, every line is a borrowed slice of
// `source` in file order — so instead of calling indexOf once per line (10M
// calls on a 10M-line file), scan the whole source in one SIMD pass and map
// the hit back to a row with a binary search. Falls back to the line-by-line
// path on the first edit, or when the needle could cross line endings.

/// Literal search over a whole buffer, vectorised: compare 32 candidate
/// positions at once against the needle's first *and* last byte, and only run
/// the full compare where both agree. `std.mem.indexOf` scans ~2.9 GB/s on
/// this machine; this measures ~15x that on cache-resident data, which is the
/// difference between a 10 MB file feeling instant and not.
fn simdIndexOfPos(hay: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or hay.len < needle.len or from > hay.len - needle.len) return null;
    const vlen = 32;
    const V = @Vector(vlen, u8);
    const first: V = @splat(needle[0]);
    const last: V = @splat(needle[needle.len - 1]);
    const limit = hay.len - needle.len; // last position a match can start at
    var i = from;
    while (i + vlen <= limit + 1) : (i += vlen) {
        const a: V = hay[i..][0..vlen].*;
        const b: V = hay[i + needle.len - 1 ..][0..vlen].*;
        var mask: u32 = @as(u32, @bitCast(a == first)) & @as(u32, @bitCast(b == last));
        while (mask != 0) {
            const at = i + @ctz(mask);
            if (std.mem.eql(u8, hay[at..][0..needle.len], needle)) return at;
            mask &= mask - 1; // next candidate in this chunk
        }
    }
    while (i <= limit) : (i += 1) {
        if (std.mem.eql(u8, hay[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// The last match starting before `limit` — the backwards counterpart.
fn simdLastIndexOf(hay: []const u8, limit: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or limit == 0 or needle.len > limit) return null;
    var best: ?usize = null;
    var at: usize = 0;
    while (simdIndexOfPos(hay[0..limit], at, needle)) |hit| {
        best = hit;
        at = hit + 1;
        if (at + needle.len > limit) break;
    }
    return best;
}

fn eligible(buf: *const buffer.Buffer, needle: []const u8) ?[]const u8 {
    if (!buf.pure_borrowed or buf.has_cr) return null;
    if (std.mem.indexOfAny(u8, needle, "\r\n") != null) return null;
    return buf.source;
}

fn lineStart(buf: *const buffer.Buffer, src: []const u8, row: usize) usize {
    return @intFromPtr(buf.line(row).ptr) - @intFromPtr(src.ptr);
}

/// The row whose line contains source offset `off` (binary search over the
/// monotonically increasing borrowed line starts).
fn rowOfOffset(buf: *const buffer.Buffer, src: []const u8, off: usize) usize {
    var lo: usize = 0;
    var hi: usize = buf.lineCount(); // exclusive
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (lineStart(buf, src, mid) <= off) lo = mid else hi = mid;
    }
    return lo;
}

fn posOfOffset(buf: *const buffer.Buffer, src: []const u8, off: usize) Pos {
    const row = rowOfOffset(buf, src, off);
    return .{ .row = row, .col = off - lineStart(buf, src, row) };
}

fn fastNext(buf: *const buffer.Buffer, src: []const u8, from: Pos, needle: []const u8) ?Pos {
    const from_off = lineStart(buf, src, from.row) + from.col;
    if (simdIndexOfPos(src, from_off + 1, needle)) |off| {
        const p = posOfOffset(buf, src, off);
        if (p.col + needle.len <= buf.line(p.row).len) return p; // not into \r\n
    }
    // Wrap to the top.
    if (simdIndexOfPos(src, 0, needle)) |off| {
        const p = posOfOffset(buf, src, off);
        if (p.col + needle.len <= buf.line(p.row).len) return p;
    }
    return null;
}

fn fastPrev(buf: *const buffer.Buffer, src: []const u8, from: Pos, needle: []const u8) ?Pos {
    const from_off = lineStart(buf, src, from.row) + from.col;
    if (simdLastIndexOf(src, from_off, needle)) |off| {
        const p = posOfOffset(buf, src, off);
        if (p.col + needle.len <= buf.line(p.row).len) return p;
    }
    // Wrap to the bottom.
    if (simdLastIndexOf(src, src.len, needle)) |off| {
        const p = posOfOffset(buf, src, off);
        if (p.col + needle.len <= buf.line(p.row).len) return p;
    }
    return null;
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
    try testing.expectEqual(@as(?Pos, Pos{ .row = 0, .col = 4 }), nextLiteral(&b, .{ .row = 0, .col = 0 }, "bar"));
    // From the first 'bar', next match is on line 1.
    try testing.expectEqual(@as(?Pos, Pos{ .row = 1, .col = 0 }), nextLiteral(&b, .{ .row = 0, .col = 4 }, "bar"));
    // From line 1, wrap back to line 0.
    try testing.expectEqual(@as(?Pos, Pos{ .row = 0, .col = 4 }), nextLiteral(&b, .{ .row = 1, .col = 0 }, "bar"));
}

test "prev finds backward and wraps" {
    var b = try buffer.Buffer.fromBytes(testing.allocator, "foo bar\nbar baz\n");
    defer b.deinit();
    try testing.expectEqual(@as(?Pos, Pos{ .row = 0, .col = 4 }), prevLiteral(&b, .{ .row = 1, .col = 0 }, "bar"));
}

test "wordUnder" {
    var b = try buffer.Buffer.fromBytes(testing.allocator, "foo_bar baz\n");
    defer b.deinit();
    try testing.expectEqualStrings("foo_bar", wordUnder(&b, .{ .row = 0, .col = 2 }));
    try testing.expectEqualStrings("baz", wordUnder(&b, .{ .row = 0, .col = 8 }));
}

test "fast path and line-by-line agree after an edit" {
    var b = try buffer.Buffer.fromBytes(testing.allocator, "foo bar\nbar baz\nqux bar\n");
    defer b.deinit();
    const before = nextLiteral(&b, .{ .row = 0, .col = 4 }, "bar"); // via the fast path
    _ = try b.insertCodepoint(0, 0, 'x'); // buffer no longer pure-borrowed
    const after = nextLiteral(&b, .{ .row = 0, .col = 5 }, "bar"); // via the slow path
    try testing.expectEqual(@as(?Pos, Pos{ .row = 1, .col = 0 }), before);
    try testing.expectEqual(@as(?Pos, Pos{ .row = 1, .col = 0 }), after);
}

test "regex next and prev with a pattern" {
    var b = try buffer.Buffer.fromBytes(testing.allocator, "foo bar\nbig bed\nbard\n");
    defer b.deinit();
    var re = try regex.Regex.compile(testing.allocator, "b.d", false);
    defer re.deinit(testing.allocator);
    try testing.expectEqual(@as(?Pos, Pos{ .row = 1, .col = 4 }), next(&b, .{ .row = 0, .col = 0 }, &re));
    // "bard" contains no b.d (b-a-r-d: "b.d"? b<any>d needs 3 chars: bar->no, ard->no)... "bard" has no match.
    try testing.expectEqual(@as(?Pos, Pos{ .row = 1, .col = 4 }), next(&b, .{ .row = 1, .col = 4 }, &re)); // wraps to itself
    try testing.expectEqual(@as(?Pos, Pos{ .row = 1, .col = 4 }), prev(&b, .{ .row = 2, .col = 0 }, &re));
}

test "regex word-boundary search like *" {
    var b = try buffer.Buffer.fromBytes(testing.allocator, "food foo\nfoo bar\n");
    defer b.deinit();
    var re = try regex.Regex.compile(testing.allocator, "\\<foo\\>", false);
    defer re.deinit(testing.allocator);
    try testing.expectEqual(@as(?Pos, Pos{ .row = 0, .col = 5 }), next(&b, .{ .row = 0, .col = 0 }, &re));
    try testing.expectEqual(@as(?Pos, Pos{ .row = 1, .col = 0 }), next(&b, .{ .row = 0, .col = 5 }, &re));
}

test "simd literal scan matches std.mem across edge cases" {
    // Cases that break naive vector scans: matches at the very start and end,
    // needles spanning a 32-byte chunk boundary, repeated first bytes, a
    // needle longer than the haystack, and single-byte needles.
    const hays = [_][]const u8{
        "",
        "a",
        "abcabcabd",
        "x" ** 31 ++ "needle" ++ "y" ** 40,
        "y" ** 32 ++ "needle",
        "needle" ++ "z" ** 100,
        "aaaaaaab" ** 9,
    };
    const needles = [_][]const u8{ "needle", "a", "ab", "aaab", "zz", "q", "x" ** 31 };
    for (hays) |hay| {
        for (needles) |needle| {
            var from: usize = 0;
            while (from <= hay.len) : (from += 1) {
                const want = if (needle.len == 0 or from > hay.len) null else std.mem.indexOfPos(u8, hay, from, needle);
                const got = simdIndexOfPos(hay, from, needle);
                std.testing.expectEqual(want, got) catch |err| {
                    std.debug.print("hay={s} needle={s} from={d}: want {?d} got {?d}\n", .{ hay, needle, from, want, got });
                    return err;
                };
            }
            // Backwards, against the same reference.
            const want_last = if (hay.len == 0) null else std.mem.lastIndexOf(u8, hay, needle);
            try std.testing.expectEqual(want_last, simdLastIndexOf(hay, hay.len, needle));
        }
    }
}
