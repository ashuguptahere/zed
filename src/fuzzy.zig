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

/// A cheap 64-bit "character bag" for prefiltering (the trick Zed's fuzzy
/// matcher uses): one bit per letter/digit class, case-insensitive. A
/// candidate can only match a query if the query's bag is a subset of the
/// candidate's — checked with two ANDs before running the real scorer.
pub fn charMask(s: []const u8) u64 {
    var m: u64 = 0;
    for (s) |raw| {
        const c = lower(raw);
        if (c >= 'a' and c <= 'z') {
            m |= @as(u64, 1) << @intCast(c - 'a');
        } else if (c >= '0' and c <= '9') {
            m |= @as(u64, 1) << @intCast(26 + (c - '0'));
        } else {
            m |= @as(u64, 1) << 36; // any other byte
        }
    }
    return m;
}

/// True when `query_mask` chars all appear in the candidate's mask.
pub fn maskMatches(candidate_mask: u64, query_mask: u64) bool {
    return (query_mask & ~candidate_mask) == 0;
}

test "charMask prefilters" {
    const path = charMask("src/main.zig");
    try std.testing.expect(maskMatches(path, charMask("main")));
    try std.testing.expect(maskMatches(path, charMask("SMZ"))); // case-insensitive
    try std.testing.expect(!maskMatches(path, charMask("query"))); // q,e,y absent
    try std.testing.expect(maskMatches(charMask("a1/b2.txt"), charMask("12")));
}
