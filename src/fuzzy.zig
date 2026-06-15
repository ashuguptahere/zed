//! Tiny fuzzy matcher for the pickers.
//!
//! `score` returns null when `query` is not a subsequence of `candidate`
//! (case-insensitive), otherwise a higher-is-better score that rewards
//! consecutive matches and matches at word boundaries — enough to float the
//! obvious result to the top without a full fzf-style algorithm.

const std = @import("std");

pub fn score(candidate: []const u8, query: []const u8) ?i32 {
    if (query.len == 0) return 0;

    var s: i32 = 0;
    var qi: usize = 0;
    var prev_matched = false;
    for (candidate, 0..) |c, i| {
        if (qi >= query.len) break;
        if (lower(c) == lower(query[qi])) {
            s += 1;
            if (prev_matched) s += 6; // consecutive run
            if (i == 0 or isBoundary(candidate[i - 1])) s += 10; // word start
            qi += 1;
            prev_matched = true;
        } else {
            prev_matched = false;
        }
    }
    if (qi < query.len) return null;
    // Prefer shorter candidates on ties.
    return s - @as(i32, @intCast(candidate.len / 4));
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c - 'A' + 'a' else c;
}

fn isBoundary(c: u8) bool {
    return c == '/' or c == '_' or c == '-' or c == '.' or c == ' ';
}

test "matches subsequence" {
    try std.testing.expect(score("src/main.zig", "main") != null);
    try std.testing.expect(score("src/main.zig", "smz") != null);
    try std.testing.expect(score("src/main.zig", "xyz") == null);
}

test "boundary and consecutive beat scattered" {
    const a = score("src/editor.zig", "editor").?; // consecutive, word start
    const b = score("seedlibtor.zig", "editor").?; // scattered
    try std.testing.expect(a > b);
}

test "empty query matches" {
    try std.testing.expectEqual(@as(?i32, 0), score("anything", ""));
}
