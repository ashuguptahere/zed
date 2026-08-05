//! The multibuffer: which parts of which files one editable buffer shows.
//!
//! zedit already *finds* things across a project — the grep picker, LSP
//! references, the diagnostics list — and the quickfix list already keeps
//! those hits after the picker is gone. A multibuffer is the editable
//! rendering of that list: the lines around every hit, stitched into one
//! buffer under a header per excerpt, edited there and written back to the
//! files they came from. Zed's idea, and the reason it fits here is that the
//! list it needs already exists.
//!
//! This module is the part that must not be wrong: turning hits into the runs
//! of lines to show. Two hits three lines apart share context, and a source
//! line shown twice would be *edited* twice — the second write undoing the
//! first — so overlapping and touching runs merge into one. Pure, so the
//! rules are unit-testable away from any buffer.

const std = @import("std");

/// Where something was found: a file and a 0-based line in it.
pub const Hit = struct { path: []const u8, line: usize };

/// A run of source lines to show, 0-based and inclusive at both ends. `end`
/// is not clamped to the file's length here — the caller is the one holding
/// the buffer, and clamps as it reads.
pub const Span = struct { path: []const u8, start: usize, end: usize };

fn hitBefore(_: void, a: Hit, b: Hit) bool {
    const c = std.mem.order(u8, a.path, b.path);
    if (c != .eq) return c == .lt;
    return a.line < b.line;
}

/// The excerpts `hits` calls for: each padded by `context` lines each side,
/// grouped by file, in file-then-line order, with overlapping or *touching*
/// runs merged. At most `cap` spans come back; the caller reports the rest as
/// dropped rather than pretending they were shown.
///
/// The returned slice owns nothing: every `path` borrows from the hit it came
/// from, which outlives it in the quickfix list.
pub fn spans(gpa: std.mem.Allocator, hits: []const Hit, context: usize, cap: usize) ![]Span {
    const sorted = try gpa.dupe(Hit, hits);
    defer gpa.free(sorted);
    std.mem.sort(Hit, sorted, {}, hitBefore);

    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);
    for (sorted) |h| {
        const start = h.line -| context;
        const end = h.line + context;
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            // `<= end + 1` merges runs that only touch, so two hits on
            // consecutive lines make one excerpt rather than two that share
            // every line between them.
            if (std.mem.eql(u8, last.path, h.path) and start <= last.end + 1) {
                last.end = @max(last.end, end);
                continue;
            }
        }
        if (out.items.len >= cap) break;
        try out.append(gpa, .{ .path = h.path, .start = start, .end = end });
    }
    return out.toOwnedSlice(gpa);
}

test "one hit becomes one context-padded span" {
    const gpa = std.testing.allocator;
    const got = try spans(gpa, &.{.{ .path = "a.zig", .line = 10 }}, 2, 100);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(usize, 8), got[0].start);
    try std.testing.expectEqual(@as(usize, 12), got[0].end);
}

test "a hit near the top clamps at line 0" {
    const gpa = std.testing.allocator;
    const got = try spans(gpa, &.{.{ .path = "a.zig", .line = 1 }}, 3, 100);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 0), got[0].start);
    try std.testing.expectEqual(@as(usize, 4), got[0].end);
}

test "overlapping hits in one file merge" {
    const gpa = std.testing.allocator;
    const got = try spans(gpa, &.{
        .{ .path = "a.zig", .line = 10 },
        .{ .path = "a.zig", .line = 12 },
    }, 2, 100);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(usize, 8), got[0].start);
    try std.testing.expectEqual(@as(usize, 14), got[0].end);
}

test "touching runs merge too, so no line is shown twice" {
    const gpa = std.testing.allocator;
    // With context 1: 4..6 and 7..9 do not overlap, but they are adjacent —
    // two excerpts there would put line 7 right under line 6 with a header
    // between them, and each would be written back over the other.
    const got = try spans(gpa, &.{
        .{ .path = "a.zig", .line = 5 },
        .{ .path = "a.zig", .line = 8 },
    }, 1, 100);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(usize, 4), got[0].start);
    try std.testing.expectEqual(@as(usize, 9), got[0].end);
}

test "distant hits in one file stay separate" {
    const gpa = std.testing.allocator;
    const got = try spans(gpa, &.{
        .{ .path = "a.zig", .line = 5 },
        .{ .path = "a.zig", .line = 50 },
    }, 2, 100);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(@as(usize, 3), got[0].start);
    try std.testing.expectEqual(@as(usize, 48), got[1].start);
}

test "hits are grouped by file whatever order they arrive in" {
    const gpa = std.testing.allocator;
    const got = try spans(gpa, &.{
        .{ .path = "b.zig", .line = 5 },
        .{ .path = "a.zig", .line = 9 },
        .{ .path = "b.zig", .line = 1 },
    }, 0, 100);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("a.zig", got[0].path);
    try std.testing.expectEqualStrings("b.zig", got[1].path);
    try std.testing.expectEqual(@as(usize, 1), got[1].start);
    try std.testing.expectEqual(@as(usize, 5), got[2].start);
}

test "the cap bounds what one list can build" {
    const gpa = std.testing.allocator;
    const got = try spans(gpa, &.{
        .{ .path = "a.zig", .line = 0 },
        .{ .path = "a.zig", .line = 20 },
        .{ .path = "a.zig", .line = 40 },
    }, 0, 2);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
}

test "no hits, no spans" {
    const gpa = std.testing.allocator;
    const got = try spans(gpa, &.{}, 2, 100);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
